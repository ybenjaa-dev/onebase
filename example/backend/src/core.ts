import { MongoClient, ObjectId } from 'mongodb';
import type { ClientSession, Db } from 'mongodb';
import { jwtVerify, createRemoteJWKSet, SignJWT } from 'jose';
import { presign, type S3Config } from './s3.js';

type FieldType = 'text' | 'int' | 'double' | 'bool' | 'datetime' | 'json';

/** Who, inside a group, may write a group-scoped collection. */
type GroupWrite = 'owner' | 'member' | 'admin' | 'none';

interface ScopeSpec {
  /** Name of the membership that decides the caller's groups. */
  membership: string;
  /** Field holding the group id, or `id` when the document *is* the group. */
  field: string;
  write: GroupWrite;
}

interface SyncSpec {
  mode: 'full' | 'window' | 'none';
  /** Datetime field the window is measured against. */
  field?: string;
  windowMs?: number;
}

interface CollectionSpec {
  ownerField?: string;
  /** Absent means the whole collection syncs. */
  sync?: SyncSpec;
  /** Present when the collection belongs to a group rather than one user. */
  scope?: ScopeSpec;
  /** Fields declared with a trailing `!` in onebase.yaml. */
  required?: string[];
  fields: Record<string, FieldType>;
}

interface MembershipSpec {
  collection: string;
  userField: string;
  groupField: string;
  roleField?: string;
  adminRole: string;
}

const MEMBERSHIPS: Record<string, MembershipSpec> = {};

const COLLECTIONS: Record<string, CollectionSpec> = {
  "todos": {
    "ownerField": "owner_id",
    "required": [
      "done",
      "title"
    ],
    "fields": {
      "title": "text",
      "done": "bool",
      "created_at": "datetime",
      "priority": "int",
      "meta": "json",
      "owner_id": "text"
    }
  },
  "categories": {
    "required": [
      "name"
    ],
    "fields": {
      "name": "text",
      "color": "text"
    }
  }
};

interface BucketSpec {
  access: 'private' | 'shared';
  maxSize?: number;
  contentTypes?: string[];
}

const STORAGE: Record<string, BucketSpec> = {
  "avatars": {
    "access": "private",
    "maxSize": 2097152,
    "contentTypes": [
      "image/png",
      "image/jpeg",
      "image/webp"
    ]
  },
  "brochures": {
    "access": "shared"
  }
};

/** Metadata for uploaded files. Keyed by the object key, so it is unique. */
const FILES = '_onebase_files';

/** How long a presigned URL stays valid. Long enough for a slow upload on a
 *  bad connection, short enough that a leaked URL expires quickly. */
const UPLOAD_URL_TTL_SECONDS = 15 * 60;
const DOWNLOAD_URL_TTL_SECONDS = 60 * 60;

interface UploadOp {
  op: 'put' | 'patch' | 'delete';
  collection: string;
  id: string;
  data?: Record<string, unknown>;
}

interface PushPayload {
  transactions: unknown[];
}

/** Server-stamped modification time. Doubles as the sync watermark. */
const UPDATED_AT = '_updated_at';

/**
 * Deletes are recorded here rather than as a flag on your documents, so your
 * collections stay clean for anything else that reads them. A TTL index drops
 * each tombstone after 30 days — a client offline for longer re-syncs from
 * scratch instead of missing a delete.
 */
const TOMBSTONES = '_onebase_tombstones';
const TOMBSTONE_TTL_SECONDS = 60 * 60 * 24 * 30;

/** Never accepted from a client, never echoed back as a data field. */
const RESERVED_FIELDS = new Set([UPDATED_AT, '_id', 'id', '_deleted']);

/** Documents per pull page. */
const PULL_LIMIT = 500;

/** Ceiling on how many groups one caller can be in, so the lookup is bounded. */
const MAX_GROUPS_PER_USER = 1000;

/** Default and maximum page size for `/query` (online mode). */
const QUERY_DEFAULT_LIMIT = 100;
const QUERY_MAX_LIMIT = 500;

/**
 * Operators `/query` accepts, mapped to MongoDB.
 *
 * A closed set on purpose: the client sends a filter that becomes a database
 * query, so anything not listed here is rejected rather than forwarded. There
 * is no path by which `$where`, `$function` or an arbitrary operator can
 * reach MongoDB.
 */
const QUERY_OPERATORS: Record<string, string> = {
  eq: '$eq',
  ne: '$ne',
  gt: '$gt',
  gte: '$gte',
  lt: '$lt',
  lte: '$lte',
  in: '$in',
};

/**
 * Request limits.
 *
 * A backend on the public internet with your database behind it needs a
 * ceiling on what one caller can ask of it. Without these, an authenticated
 * client can post an unbounded body or loop on a query and take the service
 * down for everyone.
 */
const MAX_BODY_BYTES = 5 * 1024 * 1024;
const MAX_OPS_PER_PUSH = 1000;

/** Requests per user per window, per route class. */
const RATE_LIMIT_WINDOW_MS = 60_000;
const RATE_LIMITS: Record<string, number> = {
  read: 600,
  write: 300,
  storage: 120,
};

/**
 * A fixed-window counter, held in memory.
 *
 * Deliberately per-instance: it needs no Redis, and on a single container it
 * is the whole story. Behind several instances each holds its own window, so
 * treat the effective limit as the number below times the instance count —
 * still a ceiling, just a looser one.
 */
const rateState = new Map<string, { count: number; resetAt: number }>();

function rateLimit(userId: string, bucket: string): boolean {
  const limit = RATE_LIMITS[bucket];
  if (!limit) return true;

  const key = `${bucket}:${userId}`;
  const now = Date.now();
  const entry = rateState.get(key);

  if (!entry || now >= entry.resetAt) {
    rateState.set(key, { count: 1, resetAt: now + RATE_LIMIT_WINDOW_MS });
    // Opportunistic sweep so the map cannot grow without bound.
    if (rateState.size > 10_000) {
      for (const [existing, value] of rateState) {
        if (now >= value.resetAt) rateState.delete(existing);
      }
    }
    return true;
  }

  entry.count++;
  return entry.count <= limit;
}

/** How long a realtime connection is held before the client reconnects. */
const STREAM_MAX_LIFETIME_MS = 1000 * 60 * 55;

/** Keepalive cadence, to stop proxies closing an idle stream. */
const STREAM_HEARTBEAT_MS = 25000;

/**
 * How far behind "now" a pull stops reading.
 *
 * `_updated_at` is stamped when a transaction starts, but the document only
 * becomes visible when it commits. Two concurrent transactions can therefore
 * commit out of timestamp order, and a pull that read the later one would
 * advance its watermark past the earlier one before it ever appeared.
 *
 * Ignoring the most recent second closes that window: by the time a document
 * is eligible to be read, every transaction stamped before it has long since
 * committed or aborted. The cursor can then advance exactly, with no
 * re-delivery on every sync — the cost is that a change takes up to a second
 * longer to reach other devices, which is invisible next to the poll
 * interval.
 */
const PULL_SAFETY_MS = 1000;

/**
 * How incoming JWTs are verified.
 *
 * - `jwks`   — asymmetric keys fetched from `JWKS_URL`. The production mode
 *              for Supabase / Firebase / Auth0 and friends.
 * - `hs256`  — shared HS256 secret in `JWT_SECRET`, no dev endpoints. Use
 *              this when your own auth service signs tokens with a secret.
 * - `dev`    — same verification as `hs256` **plus** the `/token` endpoint,
 *              which mints a JWT for any email address. Quickstart only.
 */
export type AuthMode = 'dev' | 'hs256' | 'jwks';

const AUTH_MODES: readonly AuthMode[] = ['dev', 'hs256', 'jwks'];

/** HS256 only — never let a caller pick the algorithm. */
const SYMMETRIC_ALGORITHMS = ['HS256'];

/** Asymmetric algorithms accepted in `jwks` mode. */
const ASYMMETRIC_ALGORITHMS = [
  'RS256', 'RS384', 'RS512',
  'PS256', 'PS384', 'PS512',
  'ES256', 'ES384', 'ES512',
  'EdDSA',
];

/** Shortest HS256 secret we accept; below this the secret is brute-forcable. */
const MIN_SECRET_LENGTH = 32;

export interface Env {
  MONGO_URI: string;
  MONGO_DB: string;
  AUTH_MODE: AuthMode;
  JWT_SECRET?: string;
  JWKS_URL?: string;
  JWT_AUDIENCE?: string;
  JWT_ISSUER?: string;
  /** Storage is optional; the routes report 501 until these are set. */
  S3_ENDPOINT?: string;
  S3_REGION?: string;
  S3_BUCKET?: string;
  S3_ACCESS_KEY_ID?: string;
  S3_SECRET_ACCESS_KEY?: string;
  S3_FORCE_PATH_STYLE?: string;
}

/**
 * Reads and validates configuration. Throws on anything that would make the
 * deployment insecure or silently wrong — a boot failure is far better than
 * an endpoint that accepts tokens it should not.
 *
 * `AUTH_MODE` is deliberately required: defaulting it would mean a forgotten
 * env var silently exposes the dev token endpoint in production.
 */
export function readEnv(get: (key: string) => string | undefined): Env {
  const need = (key: string): string => {
    const value = get(key);
    if (!value) throw new Error(`Missing required env var: ${key}`);
    return value;
  };

  const rawAuthMode = get('AUTH_MODE');
  if (!rawAuthMode) {
    throw new Error(
      'Missing required env var: AUTH_MODE. Set it to "jwks" (production, ' +
        'verifies tokens against JWKS_URL), "hs256" (production, shared ' +
        'JWT_SECRET), or "dev" (quickstart — also exposes /token, which ' +
        'signs a JWT for ANY email; never use it for real users).',
    );
  }
  const authMode = rawAuthMode.trim().toLowerCase() as AuthMode;
  if (!AUTH_MODES.includes(authMode)) {
    throw new Error(
      `Invalid AUTH_MODE "${rawAuthMode}" — expected one of ${AUTH_MODES.join(', ')}.`,
    );
  }

  const env: Env = {
    MONGO_URI: need('MONGO_URI'),
    MONGO_DB: need('MONGO_DB'),
    AUTH_MODE: authMode,
    JWT_SECRET: get('JWT_SECRET'),
    JWKS_URL: get('JWKS_URL'),
    JWT_AUDIENCE: get('JWT_AUDIENCE'),
    JWT_ISSUER: get('JWT_ISSUER'),
    S3_ENDPOINT: get('S3_ENDPOINT'),
    S3_REGION: get('S3_REGION'),
    S3_BUCKET: get('S3_BUCKET'),
    S3_ACCESS_KEY_ID: get('S3_ACCESS_KEY_ID'),
    S3_SECRET_ACCESS_KEY: get('S3_SECRET_ACCESS_KEY'),
    S3_FORCE_PATH_STYLE: get('S3_FORCE_PATH_STYLE'),
  };

  if (authMode === 'jwks') {
    if (!env.JWKS_URL) {
      throw new Error('AUTH_MODE=jwks requires JWKS_URL.');
    }
    if (!env.JWKS_URL.startsWith('https://')) {
      throw new Error('JWKS_URL must be https — keys fetched over http can be tampered with.');
    }
    // Without an audience check, any token your provider issued for any other
    // application would be accepted here.
    if (!env.JWT_AUDIENCE) {
      throw new Error(
        'AUTH_MODE=jwks requires JWT_AUDIENCE so tokens your provider ' +
          'issued for other applications are rejected.',
      );
    }
  } else {
    if (!env.JWT_SECRET) {
      throw new Error(`AUTH_MODE=${authMode} requires JWT_SECRET.`);
    }
    if (env.JWT_SECRET.length < MIN_SECRET_LENGTH) {
      throw new Error(
        `JWT_SECRET must be at least ${MIN_SECRET_LENGTH} characters ` +
          `(got ${env.JWT_SECRET.length}).`,
      );
    }
  }

  if (authMode === 'dev') {
    console.warn(
      'onebase: AUTH_MODE=dev — the /token endpoint will sign a JWT for ' +
        'any email address. Switch to AUTH_MODE=jwks (or hs256) before ' +
        'letting real users near this deployment.',
    );
  }

  return env;
}

export async function verifyToken(token: string, env: Env): Promise<string> {
  const options: Record<string, unknown> = {};
  if (env.JWT_AUDIENCE) options.audience = env.JWT_AUDIENCE;
  if (env.JWT_ISSUER) options.issuer = env.JWT_ISSUER;

  let payload;
  if (env.AUTH_MODE === 'jwks') {
    if (!env.JWKS_URL) throw new Error('JWKS_URL is not configured');
    const jwks = getJwks(env.JWKS_URL);
    payload = (
      await jwtVerify(token, jwks, {
        ...options,
        algorithms: ASYMMETRIC_ALGORITHMS,
      })
    ).payload;
  } else {
    if (!env.JWT_SECRET) throw new Error('JWT_SECRET is not configured');
    const secret = new TextEncoder().encode(env.JWT_SECRET);
    payload = (
      await jwtVerify(token, secret, {
        ...options,
        algorithms: SYMMETRIC_ALGORITHMS,
      })
    ).payload;
  }
  if (typeof payload.sub !== 'string' || payload.sub.length === 0) {
    throw new Error('token has no sub claim');
  }
  return payload.sub;
}

// createRemoteJWKSet caches keys internally; reuse it across requests so warm
// invocations do not refetch (and do not hammer the auth provider).
let jwksCache: { url: string; keys: ReturnType<typeof createRemoteJWKSet> } | null = null;

function getJwks(url: string): ReturnType<typeof createRemoteJWKSet> {
  if (!jwksCache || jwksCache.url !== url) {
    jwksCache = { url, keys: createRemoteJWKSet(new URL(url)) };
  }
  return jwksCache.keys;
}

function convertValue(value: unknown, type: FieldType): unknown {
  if (value === null || value === undefined) return null;
  switch (type) {
    case 'bool':
      return value === 1 || value === true;
    case 'datetime':
      return typeof value === 'string' ? new Date(value) : value;
    case 'json':
      if (typeof value === 'string') {
        try {
          return JSON.parse(value);
        } catch {
          return value;
        }
      }
      return value;
    default:
      return value;
  }
}

interface ConvertedDocument {
  doc: Record<string, unknown>;
  /** Client-supplied keys the schema does not declare; dropped, not written. */
  dropped: string[];
}

/**
 * Projects client data onto the declared schema.
 *
 * Only fields present in `spec.fields` survive. Anything else — including
 * `_id`, `id`, and any server-managed field a client might try to smuggle in
 * (`role`, `is_admin`, `credits`, ...) — is dropped, so an attacker cannot
 * write columns the schema never exposed.
 */
function convertDocument(
  data: Record<string, unknown>,
  spec: CollectionSpec,
): ConvertedDocument {
  const doc: Record<string, unknown> = {};
  const dropped: string[] = [];
  for (const [key, value] of Object.entries(data)) {
    const type = spec.fields[key];
    if (type === undefined) {
      // Reserved names are managed by the server; anything else is a field
      // the schema never declared and is reported so it can be added.
      if (!RESERVED_FIELDS.has(key)) dropped.push(key);
      continue;
    }
    doc[key] = convertValue(value, type);
  }
  return { doc, dropped };
}

// onebase generates UUID string ids; documents created server-side may
// use ObjectId. Match either representation. Always an `$in` so the filter
// never contributes a derived `_id` to an upsert (which would conflict with
// `$setOnInsert`).
function idFilter(id: string): Record<string, unknown> {
  return /^[0-9a-f]{24}$/.test(id)
    ? { _id: { $in: [id, new ObjectId(id)] } }
    : { _id: { $in: [id] } };
}

function idValue(id: string): string | ObjectId {
  return /^[0-9a-f]{24}$/.test(id) ? new ObjectId(id) : id;
}

interface SkippedOp {
  id: string;
  collection: string;
  reason: string;
}

interface DroppedFields {
  id: string;
  collection: string;
  fields: string[];
}

interface ApplyResult {
  applied: number;
  skipped: SkippedOp[];
  dropped: DroppedFields[];
}

function isDuplicateKeyError(error: unknown): boolean {
  return (
    typeof error === 'object' &&
    error !== null &&
    'code' in error &&
    (error as { code?: number }).code === 11000
  );
}

/** True when the MongoDB deployment cannot run multi-document transactions. */
function isTransactionUnsupportedError(error: unknown): boolean {
  if (typeof error !== 'object' || error === null) return false;
  const code = (error as { code?: number }).code;
  const message = String((error as { message?: string }).message ?? '');
  return (
    code === 20 ||
    code === 263 ||
    /transaction numbers are only allowed/i.test(message) ||
    /transactions are not supported/i.test(message) ||
    /replica set/i.test(message)
  );
}

/** Rejects malformed ops before they reach MongoDB. */
function parseOp(raw: unknown): UploadOp | null {
  if (typeof raw !== 'object' || raw === null) return null;
  const { op, collection, id, data } = raw as Record<string, unknown>;
  if (op !== 'put' && op !== 'patch' && op !== 'delete') return null;
  if (typeof collection !== 'string' || collection.length === 0) return null;
  if (typeof id !== 'string' || id.length === 0) return null;
  if (data !== undefined && (typeof data !== 'object' || data === null || Array.isArray(data))) {
    return null;
  }
  return { op, collection, id, data: data as Record<string, unknown> | undefined };
}

/**
 * The groups a caller belongs to, resolved once per request.
 *
 * Every read filter and write check needs this, so looking it up per operation
 * would mean a database round trip per document in a batch. The cache is
 * per-request on purpose: membership changes take effect on the next request
 * rather than being held across them.
 */
class GroupResolver {
  private readonly cache = new Map<string, Promise<GroupMembership>>();

  constructor(
    private readonly db: Db,
    private readonly userId: string,
  ) {}

  /** Group ids the caller belongs to, and the subset where they are admin. */
  memberships(membership: string): Promise<GroupMembership> {
    const cached = this.cache.get(membership);
    if (cached) return cached;

    const spec = MEMBERSHIPS[membership];
    const resolved = (async (): Promise<GroupMembership> => {
      if (!spec) return { groups: [], adminGroups: [] };

      const projection: Record<string, 1> = { [spec.groupField]: 1 };
      if (spec.roleField) projection[spec.roleField] = 1;

      const rows = await this.db
        .collection(spec.collection)
        .find({ [spec.userField]: this.userId }, { projection })
        .limit(MAX_GROUPS_PER_USER)
        .toArray();

      const groups: string[] = [];
      const adminGroups: string[] = [];
      for (const row of rows) {
        const group = row[spec.groupField];
        if (typeof group !== 'string' && typeof group !== 'number') continue;
        const id = String(group);
        groups.push(id);
        if (spec.roleField && row[spec.roleField] === spec.adminRole) {
          adminGroups.push(id);
        }
      }
      return { groups, adminGroups };
    })();

    this.cache.set(membership, resolved);
    return resolved;
  }
}

interface GroupMembership {
  groups: string[];
  adminGroups: string[];
}

/** The field a group-scoped collection stores its group id in. */
function scopeField(scope: ScopeSpec): string {
  return scope.field === 'id' ? '_id' : scope.field;
}

/**
 * Narrows a read to the documents a caller may see.
 *
 * Returns null when they may see nothing, which callers turn into an empty
 * result rather than an unfiltered query — the distinction that stops "no
 * groups" from meaning "every document".
 */
async function readScope(
  spec: CollectionSpec,
  userId: string,
  resolver: GroupResolver,
): Promise<Record<string, unknown> | null> {
  if (spec.scope) {
    const { groups } = await resolver.memberships(spec.scope.membership);
    if (groups.length === 0) return null;
    return { [scopeField(spec.scope)]: { $in: groups } };
  }
  return spec.ownerField ? { [spec.ownerField]: userId } : {};
}

/** Why a write was refused, or null when it is allowed. */
async function groupWriteRefusal(
  spec: CollectionSpec,
  op: UploadOp,
  userId: string,
  resolver: GroupResolver,
  existing: Record<string, unknown> | null,
): Promise<string | null> {
  const scope = spec.scope;
  if (!scope) return null;
  if (scope.write === 'none') {
    return 'this collection is read-only for clients';
  }

  const { groups, adminGroups } = await resolver.memberships(scope.membership);
  const field = scopeField(scope);

  // For an update or delete the group comes from the stored document; for an
  // insert it comes from the payload, because there is nothing stored yet.
  const target =
    existing !== null
      ? String(existing[field] ?? '')
      : String(
          (field === '_id' ? op.id : (op.data ?? {})[scope.field]) ?? '',
        );

  if (!target) return `missing ${scope.field}, which names the group`;
  if (!groups.includes(target)) return 'you are not a member of that group';
  if (scope.write === 'admin' && !adminGroups.includes(target)) {
    return 'only a group admin may write here';
  }
  if (scope.write === 'owner') {
    const owner = spec.ownerField;
    if (!owner) return 'write: owner needs an owner_field';
    // The group grants read; only the document's own user may change it.
    const currentOwner = existing !== null ? existing[owner] : userId;
    if (currentOwner !== userId) return 'this document belongs to another member';
  }
  return null;
}

function tombstoneId(collection: string, id: string): string {
  return `${collection}:${id}`;
}

async function applyOps(
  db: Db,
  userId: string,
  rawOps: unknown[],
  session: ClientSession | undefined,
  resolver: GroupResolver,
): Promise<ApplyResult> {
  const skipped: SkippedOp[] = [];
  const dropped: DroppedFields[] = [];
  const now = new Date();
  let applied = 0;

  for (const raw of rawOps) {
    const op = parseOp(raw);
    if (!op) {
      skipped.push({
        id: '',
        collection: '',
        reason: 'malformed op — expected {op, collection, id, data?}',
      });
      continue;
    }

    const spec = COLLECTIONS[op.collection];
    if (!spec) {
      skipped.push({
        id: op.id,
        collection: op.collection,
        reason: 'unknown collection — re-run `dart run onebase:setup` and redeploy',
      });
      continue;
    }

    const collection = db.collection(op.collection);
    const owner = spec.ownerField;

    // A group-scoped document is guarded by membership rather than by the
    // owner field, so the filter has to be resolved against the stored row.
    if (spec.scope) {
      const stored = await collection.findOne(idFilter(op.id), { session });
      const refusal = await groupWriteRefusal(spec, op, userId, resolver, stored);
      if (refusal) {
        skipped.push({ id: op.id, collection: op.collection, reason: refusal });
        continue;
      }
    }

    const scopedFilter = spec.scope
      ? idFilter(op.id)
      : owner
        ? { ...idFilter(op.id), [owner]: userId }
        : idFilter(op.id);

    try {
      if (op.op === 'put') {
        const { doc, dropped: unknownFields } = convertDocument(op.data ?? {}, spec);
        if (unknownFields.length > 0) {
          dropped.push({ id: op.id, collection: op.collection, fields: unknownFields });
        }
        if (owner) doc[owner] = userId; // ownership is server-assigned

        // A whole-document write must carry every required field; a partial
        // update (patch) is exempt, since it only touches what it names.
        const missing = (spec.required ?? []).filter(
          (field) => doc[field] === undefined || doc[field] === null,
        );
        if (missing.length > 0) {
          skipped.push({
            id: op.id,
            collection: op.collection,
            reason: `missing required field(s): ${missing.join(', ')}`,
          });
          continue;
        }

        if (owner) {
          // Pre-check so a foreign-owned id is reported rather than raising a
          // duplicate-key error, which would abort the surrounding transaction.
          const existing = await collection.findOne(idFilter(op.id), {
            projection: { [owner]: 1 },
            session,
          });
          if (existing && existing[owner] !== userId) {
            skipped.push({
              id: op.id,
              collection: op.collection,
              reason: 'id already exists and is owned by another user',
            });
            continue;
          }
        }

        // $set (not replaceOne): fields the schema does not declare are
        // server-managed and must survive a client write.
        doc[UPDATED_AT] = now;
        const update: Record<string, unknown> = {
          $set: doc,
          $setOnInsert: { _id: idValue(op.id) },
        };
        await collection.updateOne(scopedFilter, update, {
          upsert: true,
          session,
        });
        // A re-created document must not stay hidden behind its tombstone.
        await db.collection(TOMBSTONES).deleteOne(
          { _id: tombstoneId(op.collection, op.id) } as never,
          { session },
        );
        applied++;
      } else if (op.op === 'patch') {
        const { doc: changes, dropped: unknownFields } = convertDocument(op.data ?? {}, spec);
        if (unknownFields.length > 0) {
          dropped.push({ id: op.id, collection: op.collection, fields: unknownFields });
        }
        if (owner) delete changes[owner]; // ownership is immutable
        // Moving a document between groups would hand it to people who were
        // never allowed to see it.
        if (spec.scope && spec.scope.field !== 'id') {
          delete changes[spec.scope.field];
        }
        if (Object.keys(changes).length === 0) {
          applied++;
          continue;
        }
        changes[UPDATED_AT] = now;
        const updated = await collection.updateOne(
          scopedFilter,
          { $set: changes },
          { session },
        );
        if (updated.matchedCount === 0) {
          skipped.push({
            id: op.id,
            collection: op.collection,
            reason: 'not found or not owned by this user',
          });
        } else {
          applied++;
        }
      } else {
        // Read before deleting: the tombstone has to carry the group, and
        // after the delete there is nothing left to read it from.
        const existingForTombstone = spec.scope
          ? await collection.findOne(idFilter(op.id), { session })
          : null;
        const deleted = await collection.deleteOne(scopedFilter, { session });
        if (deleted.deletedCount === 0) {
          skipped.push({
            id: op.id,
            collection: op.collection,
            reason: 'not found or not owned by this user',
          });
        } else {
          // Record the delete so other devices learn about it on their next
          // pull. Without this a deleted row would linger on them forever.
          await db.collection(TOMBSTONES).replaceOne(
            { _id: tombstoneId(op.collection, op.id) } as never,
            {
              collection: op.collection,
              doc_id: op.id,
              owner: owner ? userId : null,
              // Recorded so the delete reaches everyone who could see the
              // document, not just its author.
              group: spec.scope && existingForTombstone
                ? String(existingForTombstone[scopeField(spec.scope)] ?? '')
                : null,
              deleted_at: now,
            },
            { upsert: true, session },
          );
          applied++;
        }
      }
    } catch (error) {
      if (isDuplicateKeyError(error) && !session) {
        skipped.push({
          id: op.id,
          collection: op.collection,
          reason: 'id already exists with a different owner',
        });
      } else {
        throw error; // infrastructure problem → 5xx → client retries
      }
    }
  }

  return { applied, skipped, dropped };
}

// Multi-document transactions need a replica set (every Atlas tier, including
// free M0). Standalone mongod does not support them; we detect that once and
// fall back. The fallback is safe because every op is idempotent — a client
// retry of the same transaction converges to the same state.
let transactionsSupported = true;

async function applyUpload(
  client: MongoClient,
  dbName: string,
  userId: string,
  rawOps: unknown[],
  resolver: GroupResolver,
): Promise<ApplyResult> {
  if (transactionsSupported) {
    const session = client.startSession();
    try {
      let result: ApplyResult | null = null;
      await session.withTransaction(async () => {
        result = await applyOps(
          client.db(dbName),
          userId,
          rawOps,
          session,
          resolver,
        );
      });
      if (result) return result;
    } catch (error) {
      if (!isTransactionUnsupportedError(error)) throw error;
      transactionsSupported = false;
      console.warn(
        'onebase: this MongoDB deployment does not support transactions ' +
          '(needs a replica set). Falling back to per-operation writes.',
      );
    } finally {
      await session.endSession();
    }
  }
  return applyOps(client.db(dbName), userId, rawOps, undefined, resolver);
}

let mongoClient: Promise<MongoClient> | null = null;

async function getMongo(env: Env): Promise<MongoClient> {
  if (!mongoClient) {
    // Cache the promise, not the client, so concurrent invocations share one
    // connect(); clear it on failure so the next request retries.
    mongoClient = new MongoClient(env.MONGO_URI)
      .connect()
      .catch((error: unknown) => {
        mongoClient = null;
        throw error;
      });
  }
  return mongoClient;
}

export function json(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'content-type': 'application/json' },
  });
}

/** Shared auth guard: returns the verified user id, or a 401 Response. */
async function authenticate(
  request: Request,
  env: Env,
  method: string = 'POST',
  bucket?: string,
): Promise<{ userId: string } | { response: Response }> {
  if (request.method !== method) {
    return { response: json(405, { error: 'method not allowed' }) };
  }
  const authorization = request.headers.get('authorization') ?? '';
  if (!authorization.startsWith('Bearer ')) {
    return { response: json(401, { error: 'missing bearer token' }) };
  }
  let userId: string;
  try {
    userId = await verifyToken(authorization.slice(7), env);
  } catch (error) {
    // Do not echo the verification error: it can leak configuration details.
    console.warn('onebase: token rejected', error);
    return { response: json(401, { error: 'invalid token' }) };
  }

  if (bucket && !rateLimit(userId, bucket)) {
    return {
      response: new Response(
        JSON.stringify({ error: 'rate limit exceeded, slow down' }),
        {
          status: 429,
          headers: {
            'content-type': 'application/json',
            'retry-after': String(Math.ceil(RATE_LIMIT_WINDOW_MS / 1000)),
          },
        },
      ),
    };
  }

  return { userId };
}

async function readJson(request: Request): Promise<Record<string, unknown> | null> {
  // Read as text first so an oversized body is rejected before it is parsed.
  // Parsing it would mean holding both the raw bytes and the object graph.
  const declared = Number(request.headers.get('content-length') ?? '0');
  if (Number.isFinite(declared) && declared > MAX_BODY_BYTES) return null;

  try {
    const text = await request.text();
    if (text.length > MAX_BODY_BYTES) return null;
    const body = JSON.parse(text);
    if (typeof body !== 'object' || body === null || Array.isArray(body)) {
      return null;
    }
    return body as Record<string, unknown>;
  } catch {
    return null;
  }
}

/**
 * Applies a batch of client writes.
 *
 * Body: `{ transactions: [{ id, ops: [{op, collection, id, data}] }] }`.
 * Ops from every transaction are applied together so a multi-document change
 * made offline lands atomically.
 */
export async function handlePush(
  request: Request,
  env: Env,
): Promise<Response> {
  const auth = await authenticate(request, env, 'POST', 'write');
  if ('response' in auth) return auth.response;

  const payload = (await readJson(request)) as PushPayload | null;
  if (!payload || !Array.isArray(payload.transactions)) {
    return json(400, { error: 'body must contain a transactions array' });
  }

  const ops: unknown[] = [];
  for (const entry of payload.transactions) {
    if (typeof entry !== 'object' || entry === null) continue;
    const list = (entry as { ops?: unknown }).ops;
    if (Array.isArray(list)) ops.push(...list);
  }
  if (ops.length > MAX_OPS_PER_PUSH) {
    // The client splits large queues itself; a batch past this is a bug or an
    // attempt to make one request do unbounded work.
    return json(413, {
      error: `too many operations in one push (${ops.length} > ${MAX_OPS_PER_PUSH})`,
    });
  }

  try {
    const client = await getMongo(env);
    await ensureIndexes(client, env);
    const db = client.db(env.MONGO_DB);
    const result = await applyUpload(
      client,
      env.MONGO_DB,
      auth.userId,
      ops,
      new GroupResolver(db, auth.userId),
    );
    if (result.skipped.length > 0) {
      console.warn('onebase push: skipped ops', JSON.stringify(result.skipped));
    }
    if (result.dropped.length > 0) {
      console.warn(
        'onebase push: dropped undeclared fields (add them to ' +
          'onebase.yaml and redeploy if they are meant to sync)',
        JSON.stringify(result.dropped),
      );
    }
    // Always 2xx once ops were processed — validation problems are reported,
    // not turned into errors, so the client queue never gets stuck.
    return json(200, result);
  } catch (error) {
    console.error('onebase push: transient failure', error);
    return json(503, { error: 'transient failure, client will retry' });
  }
}

/**
 * Returns everything in one collection that changed since the client's
 * watermark — updated documents and deletes, scoped to the caller.
 *
 * Body: `{ collection, since? }`. Response: `{ documents, cursor, has_more }`.
 */
export async function handlePull(
  request: Request,
  env: Env,
): Promise<Response> {
  const auth = await authenticate(request, env, 'POST', 'read');
  if ('response' in auth) return auth.response;

  const body = await readJson(request);
  const name = body?.collection;
  if (typeof name !== 'string' || !COLLECTIONS[name]) {
    return json(400, { error: 'unknown or missing collection' });
  }
  const rawSince = body?.since;
  if (rawSince !== undefined && typeof rawSince !== 'string') {
    return json(400, { error: 'since must be an ISO-8601 string' });
  }
  const since = rawSince ? new Date(rawSince) : null;
  if (since && Number.isNaN(since.getTime())) {
    return json(400, { error: 'since is not a valid date' });
  }

  const spec = COLLECTIONS[name];
  const owner = spec.ownerField;

  try {
    const client = await getMongo(env);
    await ensureIndexes(client, env);
    const db = client.db(env.MONGO_DB);

    // `sync: none` is never downloaded; the client reads it over /query.
    if (spec.sync?.mode === 'none') {
      return json(200, { documents: [], cursor: rawSince ?? null, has_more: false });
    }

    const readUpTo = new Date(Date.now() - PULL_SAFETY_MS);
    const window = (field: string): Record<string, unknown> => ({
      [field]: since ? { $gt: since, $lte: readUpTo } : { $lte: readUpTo },
    });

    const resolver = new GroupResolver(db, auth.userId);
    const scope = await readScope(spec, auth.userId, resolver);
    if (scope === null) {
      // Belongs to no group, so there is nothing to sync — not everything.
      return json(200, { documents: [], cursor: rawSince ?? null, has_more: false });
    }

    // A windowed collection only ever sends its recent slice, so a device
    // holds a bounded amount however far the collection grows.
    const syncWindow: Record<string, unknown> = {};
    if (spec.sync?.mode === 'window' && spec.sync.field && spec.sync.windowMs) {
      syncWindow[spec.sync.field] = {
        $gte: new Date(Date.now() - spec.sync.windowMs),
      };
    }

    const documents = await db
      .collection(name)
      .find({ ...scope, ...syncWindow, ...window(UPDATED_AT) })
      .sort({ [UPDATED_AT]: 1, _id: 1 })
      .limit(PULL_LIMIT)
      .toArray();

    const tombstoneFilter: Record<string, unknown> = { collection: name };
    if (spec.scope) {
      const { groups } = await resolver.memberships(spec.scope.membership);
      tombstoneFilter.group = { $in: groups };
    } else if (owner) {
      tombstoneFilter.owner = auth.userId;
    }

    const tombstones = await db
      .collection(TOMBSTONES)
      .find({ ...tombstoneFilter, ...window('deleted_at') })
      .sort({ deleted_at: 1, _id: 1 })
      .limit(PULL_LIMIT)
      .toArray();

    const payload = [
      ...documents.map((document) => projectDocument(document, spec)),
      ...tombstones.map((tombstone) => ({
        id: String(tombstone.doc_id),
        _deleted: true,
      })),
    ];

    // When a page is full there is more behind it, so the cursor must stop at
    // that page's edge rather than at the newest row overall. Rewinding one
    // millisecond keeps documents that share the edge timestamp from being
    // cut in half by the page boundary.
    const docsFull = documents.length === PULL_LIMIT;
    const tombsFull = tombstones.length === PULL_LIMIT;
    const lastDocAt = timestampOf(documents[documents.length - 1]?.[UPDATED_AT]);
    const lastTombAt = timestampOf(tombstones[tombstones.length - 1]?.deleted_at);

    let next: number | null;
    if (docsFull || tombsFull) {
      const edges = [
        docsFull ? lastDocAt : null,
        tombsFull ? lastTombAt : null,
      ].filter((value): value is number => value !== null);
      next = Math.min(...edges) - 1;
    } else {
      const seen = [lastDocAt, lastTombAt].filter(
        (value): value is number => value !== null,
      );
      // Nothing new: hold the watermark at the read edge so the next pull
      // starts from where this one stopped instead of re-scanning history.
      next = seen.length > 0 ? Math.max(...seen) : readUpTo.getTime();
    }

    const cursor = new Date(Math.max(0, next)).toISOString();

    return json(200, {
      documents: payload,
      cursor,
      has_more: docsFull || tombsFull,
    });
  } catch (error) {
    console.error('onebase pull: transient failure', error);
    return json(503, { error: 'transient failure, client will retry' });
  }
}

function timestampOf(value: unknown): number | null {
  if (value instanceof Date) return value.getTime();
  if (typeof value === 'string') {
    const parsed = Date.parse(value);
    return Number.isNaN(parsed) ? null : parsed;
  }
  return null;
}

/**
 * Shapes a stored document for the client: only declared fields, plus the id.
 * Anything your backend keeps alongside the schema stays server-side.
 */
function projectDocument(
  document: Record<string, unknown>,
  spec: CollectionSpec,
): Record<string, unknown> {
  const out: Record<string, unknown> = { id: String(document._id) };
  for (const key of Object.keys(spec.fields)) {
    const value = document[key];
    if (value === undefined) continue;
    out[key] =
      value instanceof Date
        ? value.toISOString()
        : spec.fields[key] === 'json' && typeof value === 'object' && value !== null
          ? JSON.stringify(value)
          : value;
  }
  const updatedAt = document[UPDATED_AT];
  if (updatedAt instanceof Date) out[UPDATED_AT] = updatedAt.toISOString();
  return out;
}

/**
 * Resolves a client field reference against the schema.
 *
 * Returns the MongoDB path, or null when the field is not declared. Dot-paths
 * are only allowed into a declared `json` field, which is what stops a client
 * reaching into documents through a path the schema never exposed.
 */
function resolveQueryField(field: string, spec: CollectionSpec): string | null {
  if (typeof field !== 'string' || field.length === 0) return null;
  if (field.includes('$') || field.startsWith('_')) return null;

  const segments = field.split('.');
  if (segments.some((segment) => !/^[A-Za-z_][A-Za-z0-9_]*$/.test(segment))) {
    return null;
  }
  const root = segments[0];
  const type = spec.fields[root];
  if (type === undefined) return null;
  if (segments.length > 1 && type !== 'json') return null;
  return field;
}

function queryValue(field: string, value: unknown, spec: CollectionSpec): unknown {
  const type = spec.fields[field];
  // Dot-paths address inside a json document; the stored representation wins.
  return type === undefined ? value : convertValue(value, type);
}

/**
 * Runs a query on behalf of the client — online mode's read path.
 *
 * Body: `{ collection, filters?, order?, limit?, offset?, count?, id? }`.
 * Always scoped to the caller's own documents.
 */
export async function handleQuery(
  request: Request,
  env: Env,
): Promise<Response> {
  const auth = await authenticate(request, env, 'POST', 'read');
  if ('response' in auth) return auth.response;

  const body = await readJson(request);
  const name = body?.collection;
  if (typeof name !== 'string' || !COLLECTIONS[name]) {
    return json(400, { error: 'unknown or missing collection' });
  }
  const spec = COLLECTIONS[name];
  const owner = spec.ownerField;

  const queryDb = (await getMongo(env)).db(env.MONGO_DB);
  const queryResolver = new GroupResolver(queryDb, auth.userId);
  const readable = await readScope(spec, auth.userId, queryResolver);
  if (readable === null) {
    return json(200, body?.count === true ? { count: 0 } : { documents: [] });
  }
  const filter: Record<string, unknown> = { ...readable };

  // Single-document fetch by id.
  if (body?.id !== undefined) {
    if (typeof body.id !== 'string' || body.id.length === 0) {
      return json(400, { error: 'id must be a non-empty string' });
    }
    Object.assign(filter, idFilter(body.id));
  }

  const rawFilters = body?.filters ?? [];
  if (!Array.isArray(rawFilters)) {
    return json(400, { error: 'filters must be an array' });
  }
  for (const raw of rawFilters) {
    if (typeof raw !== 'object' || raw === null) {
      return json(400, { error: 'each filter must be an object' });
    }
    const { field, op, value } = raw as Record<string, unknown>;
    const path = resolveQueryField(field as string, spec);
    if (!path) {
      return json(400, { error: `unknown or invalid field: ${String(field)}` });
    }
    if (path === owner) {
      // Ownership is not the client's to narrow or widen.
      continue;
    }

    const existing = (filter[path] ?? {}) as Record<string, unknown>;
    if (op === 'isNull') {
      filter[path] = { ...existing, $eq: null };
    } else if (op === 'isNotNull') {
      filter[path] = { ...existing, $ne: null };
    } else if (op === 'in') {
      if (!Array.isArray(value) || value.length === 0) {
        return json(400, { error: `"in" on ${path} needs a non-empty array` });
      }
      filter[path] = {
        ...existing,
        $in: value.map((entry) => queryValue(path, entry, spec)),
      };
    } else if (typeof op === 'string' && QUERY_OPERATORS[op]) {
      filter[path] = {
        ...existing,
        [QUERY_OPERATORS[op]]: queryValue(path, value, spec),
      };
    } else {
      return json(400, { error: `unsupported operator: ${String(op)}` });
    }
  }

  const sort: Record<string, 1 | -1> = {};
  const orderFields: { path: string; descending: boolean }[] = [];
  const rawOrder = body?.order ?? [];
  if (!Array.isArray(rawOrder)) {
    return json(400, { error: 'order must be an array' });
  }
  for (const raw of rawOrder) {
    if (typeof raw !== 'object' || raw === null) {
      return json(400, { error: 'each order entry must be an object' });
    }
    const { field, descending } = raw as Record<string, unknown>;
    const path = resolveQueryField(field as string, spec);
    if (!path) {
      return json(400, { error: `cannot sort by ${String(field)}` });
    }
    sort[path] = descending === true ? -1 : 1;
    orderFields.push({ path, descending: descending === true });
  }

  // `_id` breaks ties so the order is total. Without it two documents sharing
  // a sort value come back in an arbitrary order, and a page boundary between
  // them can repeat or drop a row.
  if (sort._id === undefined) {
    sort._id = orderFields.length > 0 && orderFields[orderFields.length - 1].descending ? -1 : 1;
  }

  // Keyset pagination: seek straight to the position rather than counting past
  // everything before it, so deep pages cost what shallow ones do.
  const rawCursor = body?.startAfter;
  if (rawCursor !== undefined) {
    if (typeof rawCursor !== 'object' || rawCursor === null) {
      return json(400, { error: 'startAfter must be a cursor object' });
    }
    const { values, id } = rawCursor as { values?: unknown; id?: unknown };
    if (!Array.isArray(values) || typeof id !== 'string') {
      return json(400, { error: 'startAfter must carry values and an id' });
    }
    if (values.length !== orderFields.length) {
      return json(400, {
        error: 'startAfter does not match this query\'s orderBy',
      });
    }

    const keys = [
      ...orderFields.map((field, index) => ({
        path: field.path,
        descending: field.descending,
        value: queryValue(field.path, values[index], spec),
      })),
      {
        path: '_id',
        descending: sort._id === -1,
        value: idValue(id),
      },
    ];

    // Lexicographic expansion: a > v, or a = v and b > w, and so on.
    const branches: Record<string, unknown>[] = [];
    for (let i = 0; i < keys.length; i++) {
      const branch: Record<string, unknown> = {};
      for (let j = 0; j < i; j++) branch[keys[j].path] = keys[j].value;
      branch[keys[i].path] = {
        [keys[i].descending ? '$lt' : '$gt']: keys[i].value,
      };
      branches.push(branch);
    }
    if (branches.length > 0) {
      filter.$and = [...((filter.$and as unknown[]) ?? []), { $or: branches }];
    }
  }

  const rawLimit = body?.limit;
  if (rawLimit !== undefined && (typeof rawLimit !== 'number' || rawLimit <= 0)) {
    return json(400, { error: 'limit must be a positive number' });
  }
  const rawOffset = body?.offset;
  if (rawOffset !== undefined && (typeof rawOffset !== 'number' || rawOffset < 0)) {
    return json(400, { error: 'offset must be zero or more' });
  }
  // Capped regardless of what was asked for: an unbounded query is a way to
  // turn one request into an outage.
  const limit = Math.min(
    typeof rawLimit === 'number' ? rawLimit : QUERY_DEFAULT_LIMIT,
    QUERY_MAX_LIMIT,
  );

  try {
    const client = await getMongo(env);
    const collection = client.db(env.MONGO_DB).collection(name);

    if (body?.count === true) {
      return json(200, { count: await collection.countDocuments(filter) });
    }

    let cursor = collection.find(filter);
    if (Object.keys(sort).length > 0) cursor = cursor.sort(sort);
    if (typeof rawOffset === 'number') cursor = cursor.skip(rawOffset);
    const documents = await cursor.limit(limit).toArray();

    return json(200, {
      documents: documents.map((document) => projectDocument(document, spec)),
    });
  } catch (error) {
    console.error('onebase query: failure', error);
    return json(503, { error: 'transient failure, retry' });
  }
}

/**
 * Realtime changes over Server-Sent Events, driven by a MongoDB change
 * stream. This is what makes realtime realtime — the server pushes a change
 * the moment it commits instead of waiting to be asked.
 *
 * Requires a host that allows long-lived responses. Short-lived serverless
 * functions will cut the stream; the client reconnects and its periodic sync
 * covers the gap, so nothing is lost either way.
 */
export async function handleStream(
  request: Request,
  env: Env,
): Promise<Response> {
  const auth = await authenticate(request, env, 'GET', 'read');
  if ('response' in auth) return auth.response;

  const requested = new URL(request.url).searchParams.get('collections');
  const names = requested
    ? requested.split(',').map((value) => value.trim()).filter(Boolean)
    : Object.keys(COLLECTIONS);

  const unknown = names.filter((name) => !COLLECTIONS[name]);
  if (unknown.length > 0) {
    return json(400, { error: `unknown collections: ${unknown.join(', ')}` });
  }

  const client = await getMongo(env);
  const db = client.db(env.MONGO_DB);
  const watched = [...names, TOMBSTONES];

  // Resolved once, when the stream opens. A membership granted later reaches
  // the device on its next reconnect or periodic sync rather than mid-stream,
  // which keeps the per-event check a set lookup instead of a query.
  const streamResolver = new GroupResolver(db, auth.userId);
  const streamGroups = new Set<string>();
  for (const name of names) {
    const scope = COLLECTIONS[name]?.scope;
    if (!scope) continue;
    const { groups } = await streamResolver.memberships(scope.membership);
    for (const group of groups) streamGroups.add(group);
  }

  const changes = db.watch(
    [
      {
        $match: {
          'ns.coll': { $in: watched },
          operationType: { $in: ['insert', 'update', 'replace'] },
        },
      },
    ],
    { fullDocument: 'updateLookup' },
  );

  const encoder = new TextEncoder();
  const stream = new ReadableStream<Uint8Array>({
    start(controller) {
      let open = true;
      const send = (payload: unknown) => {
        if (!open) return;
        controller.enqueue(encoder.encode(`data: ${JSON.stringify(payload)}\n\n`));
      };
      const comment = (text: string) => {
        if (!open) return;
        controller.enqueue(encoder.encode(`: ${text}\n\n`));
      };

      const shutdown = async () => {
        if (!open) return;
        open = false;
        clearInterval(heartbeat);
        clearTimeout(lifetime);
        try {
          await changes.close();
        } catch {
          // Already closed.
        }
        try {
          controller.close();
        } catch {
          // Already closed.
        }
      };

      const heartbeat = setInterval(() => comment('keepalive'), STREAM_HEARTBEAT_MS);
      // Hosts and proxies drop very long requests anyway; ending on our own
      // terms means the client reconnects cleanly instead of erroring.
      const lifetime = setTimeout(() => void shutdown(), STREAM_MAX_LIFETIME_MS);

      request.signal?.addEventListener('abort', () => void shutdown());

      comment('connected');

      changes.on('change', (change: Record<string, unknown>) => {
        const namespace = (change.ns as { coll?: string } | undefined)?.coll;
        const full = change.fullDocument as Record<string, unknown> | undefined;
        if (!namespace || !full) return;

        if (namespace === TOMBSTONES) {
          const collection = String(full.collection ?? '');
          if (!names.includes(collection)) return;
          const spec = COLLECTIONS[collection];
          if (spec.scope) {
            if (!streamGroups.has(String(full.group ?? ''))) return;
          } else if (spec.ownerField && full.owner !== auth.userId) {
            // Shared collections have no owner on the tombstone.
            return;
          }
          send({
            collection,
            document: { id: String(full.doc_id), _deleted: true },
          });
          return;
        }

        const spec = COLLECTIONS[namespace];
        if (!spec) return;
        // Re-checked here, not just in the pipeline: this is the last line
        // before another user's document would leave the process.
        if (spec.scope) {
          const group = String(full[scopeField(spec.scope)] ?? '');
          if (!streamGroups.has(group)) return;
        } else if (spec.ownerField && full[spec.ownerField] !== auth.userId) {
          return;
        }
        send({ collection: namespace, document: projectDocument(full, spec) });
      });

      changes.on('error', (error: unknown) => {
        console.warn('onebase stream: change stream error', error);
        void shutdown();
      });
      changes.on('close', () => void shutdown());
    },
    cancel() {
      void changes.close().catch(() => {});
    },
  });

  return new Response(stream, {
    status: 200,
    headers: {
      'content-type': 'text/event-stream; charset=utf-8',
      'cache-control': 'no-cache, no-transform',
      connection: 'keep-alive',
      // Proxies that buffer would defeat the point of a stream.
      'x-accel-buffering': 'no',
    },
  });
}

/**
 * Storage: presigned URLs, so file bytes never pass through this server.
 *
 * The device uploads straight to your object store with a short-lived URL
 * that only this backend can mint. That keeps the server tiny and means a
 * large upload costs it nothing.
 */
function s3Config(env: Env): S3Config | null {
  if (!env.S3_BUCKET || !env.S3_ACCESS_KEY_ID || !env.S3_SECRET_ACCESS_KEY) {
    return null;
  }
  return {
    endpoint: env.S3_ENDPOINT,
    region: env.S3_REGION ?? 'auto',
    bucket: env.S3_BUCKET,
    accessKeyId: env.S3_ACCESS_KEY_ID,
    secretAccessKey: env.S3_SECRET_ACCESS_KEY,
    // Everything except plain AWS wants path style; default accordingly.
    forcePathStyle: env.S3_FORCE_PATH_STYLE
      ? env.S3_FORCE_PATH_STYLE !== 'false'
      : Boolean(env.S3_ENDPOINT),
  };
}

/**
 * Rejects anything that could escape the caller's prefix. Never "cleans up" a
 * bad path — a path that needed fixing is a path we should not be signing.
 */
function validatePath(path: unknown): string | null {
  if (typeof path !== 'string' || path.length === 0 || path.length > 1024) {
    return null;
  }
  if (path.startsWith('/') || path.includes('\\')) return null;
  // eslint-disable-next-line no-control-regex
  if (/[\x00-\x1f\x7f]/.test(path)) return null;
  for (const segment of path.split('/')) {
    if (segment === '' || segment === '.' || segment === '..') return null;
  }
  return path;
}

/**
 * The object key for a file.
 *
 * Private buckets are namespaced by user id, so one user cannot name — let
 * alone read — another user's file, whatever path they ask for.
 */
function objectKey(bucket: string, spec: BucketSpec, userId: string, path: string): string {
  return spec.access === 'private'
    ? `${bucket}/${userId}/${path}`
    : `${bucket}/${path}`;
}

function contentTypeAllowed(spec: BucketSpec, contentType: string): boolean {
  const allowed = spec.contentTypes;
  if (!allowed || allowed.length === 0) return true;
  const value = contentType.toLowerCase();
  return allowed.some((pattern) => {
    const rule = pattern.toLowerCase();
    return rule.endsWith('/*')
      ? value.startsWith(rule.slice(0, -1))
      : value === rule;
  });
}

interface StorageRequest {
  bucket: string;
  spec: BucketSpec;
  path: string;
  key: string;
  config: S3Config;
  /** The parsed body, so a handler never has to read the request twice. */
  body: Record<string, unknown>;
}

/** Shared parsing for every storage route. */
async function storageRequest(
  request: Request,
  env: Env,
  userId: string,
): Promise<StorageRequest | Response> {
  const config = s3Config(env);
  if (!config) {
    return json(501, {
      error:
        'storage is not configured — set S3_BUCKET, S3_ACCESS_KEY_ID and ' +
        'S3_SECRET_ACCESS_KEY (plus S3_ENDPOINT for R2/MinIO)',
    });
  }

  const body = await readJson(request);
  const bucket = body?.bucket;
  if (typeof bucket !== 'string' || !STORAGE[bucket]) {
    return json(400, {
      error: `unknown storage bucket: ${String(bucket)}`,
    });
  }
  const path = validatePath(body?.path);
  if (path === null) {
    return json(400, { error: 'invalid file path' });
  }

  const spec = STORAGE[bucket];
  return {
    bucket,
    spec,
    path,
    key: objectKey(bucket, spec, userId, path),
    config,
    body: body ?? {},
  };
}

export async function handleStorageUploadUrl(
  request: Request,
  env: Env,
): Promise<Response> {
  const auth = await authenticate(request, env, 'POST', 'storage');
  if ('response' in auth) return auth.response;

  const parsed = await storageRequest(request, env, auth.userId);
  if (parsed instanceof Response) return parsed;

  const { body } = parsed;
  const contentType =
    typeof body.contentType === 'string' ? body.contentType : 'application/octet-stream';
  const size = body.size;

  if (!contentTypeAllowed(parsed.spec, contentType)) {
    return json(400, {
      error: `bucket "${parsed.bucket}" does not accept ${contentType}`,
      allowed: parsed.spec.contentTypes,
    });
  }
  if (typeof size !== 'number' || !Number.isFinite(size) || size < 0) {
    return json(400, { error: 'size must be the byte length of the upload' });
  }
  if (parsed.spec.maxSize !== undefined && size > parsed.spec.maxSize) {
    return json(400, {
      error: `file is ${size} bytes; bucket "${parsed.bucket}" allows ${parsed.spec.maxSize}`,
    });
  }

  // Signing the length and type means S3 itself rejects an upload that does
  // not match what we approved — the limit is enforced, not merely advertised.
  const headers = {
    'content-type': contentType,
    'content-length': String(size),
  };

  return json(200, {
    url: presign({
      config: parsed.config,
      method: 'PUT',
      key: parsed.key,
      expiresIn: UPLOAD_URL_TTL_SECONDS,
      headers,
    }),
    method: 'PUT',
    headers,
    key: parsed.key,
    expires_in: UPLOAD_URL_TTL_SECONDS,
  });
}

/** Recorded after the bytes land, so a listing only ever shows real files. */
export async function handleStorageComplete(
  request: Request,
  env: Env,
): Promise<Response> {
  const auth = await authenticate(request, env, 'POST', 'storage');
  if ('response' in auth) return auth.response;

  const parsed = await storageRequest(request, env, auth.userId);
  if (parsed instanceof Response) return parsed;

  const { body } = parsed;
  const now = new Date();

  try {
    const client = await getMongo(env);
    await client
      .db(env.MONGO_DB)
      .collection(FILES)
      .replaceOne(
        { _id: parsed.key } as never,
        {
          bucket: parsed.bucket,
          path: parsed.path,
          owner: auth.userId,
          content_type:
            typeof body.contentType === 'string' ? body.contentType : null,
          size: typeof body.size === 'number' ? body.size : null,
          updated_at: now,
        },
        { upsert: true },
      );
    return json(200, { key: parsed.key, path: parsed.path });
  } catch (error) {
    console.error('onebase storage: complete failed', error);
    return json(503, { error: 'transient failure, retry' });
  }
}

export async function handleStorageDownloadUrl(
  request: Request,
  env: Env,
): Promise<Response> {
  const auth = await authenticate(request, env, 'POST', 'storage');
  if ('response' in auth) return auth.response;

  const parsed = await storageRequest(request, env, auth.userId);
  if (parsed instanceof Response) return parsed;

  return json(200, {
    url: presign({
      config: parsed.config,
      method: 'GET',
      key: parsed.key,
      expiresIn: DOWNLOAD_URL_TTL_SECONDS,
    }),
    key: parsed.key,
    expires_in: DOWNLOAD_URL_TTL_SECONDS,
  });
}

export async function handleStorageDelete(
  request: Request,
  env: Env,
): Promise<Response> {
  const auth = await authenticate(request, env, 'POST', 'storage');
  if ('response' in auth) return auth.response;

  const parsed = await storageRequest(request, env, auth.userId);
  if (parsed instanceof Response) return parsed;

  try {
    const client = await getMongo(env);
    const files = client.db(env.MONGO_DB).collection(FILES);

    // In a shared bucket anyone can read, but only the uploader may remove.
    if (parsed.spec.access === 'shared') {
      const existing = await files.findOne({ _id: parsed.key } as never);
      if (existing && existing.owner !== auth.userId) {
        return json(403, { error: 'this file belongs to another user' });
      }
    }

    const response = await fetch(
      presign({
        config: parsed.config,
        method: 'DELETE',
        key: parsed.key,
        expiresIn: 60,
      }),
      { method: 'DELETE' },
    );
    // S3 answers 204 for a delete, and also for a key that was never there.
    if (!response.ok && response.status !== 404) {
      console.error('onebase storage: delete failed', response.status);
      return json(503, { error: 'could not delete the file, retry' });
    }

    await files.deleteOne({ _id: parsed.key } as never);
    return json(200, { key: parsed.key });
  } catch (error) {
    console.error('onebase storage: delete failed', error);
    return json(503, { error: 'transient failure, retry' });
  }
}

/** Lists what the caller can see in a bucket, newest first. */
export async function handleStorageList(
  request: Request,
  env: Env,
): Promise<Response> {
  const auth = await authenticate(request, env, 'POST', 'storage');
  if ('response' in auth) return auth.response;

  const body = await readJson(request);
  const bucket = body?.bucket;
  if (typeof bucket !== 'string' || !STORAGE[bucket]) {
    return json(400, { error: `unknown storage bucket: ${String(bucket)}` });
  }
  const spec = STORAGE[bucket];

  const prefix = body?.prefix;
  if (prefix !== undefined && typeof prefix !== 'string') {
    return json(400, { error: 'prefix must be a string' });
  }

  const filter: Record<string, unknown> = { bucket };
  if (spec.access === 'private') filter.owner = auth.userId;
  if (prefix) {
    // Escaped: a prefix is a literal, never a pattern the caller supplies.
    filter.path = { $regex: `^${prefix.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}` };
  }

  try {
    const client = await getMongo(env);
    const files = await client
      .db(env.MONGO_DB)
      .collection(FILES)
      .find(filter)
      .sort({ updated_at: -1 })
      .limit(500)
      .toArray();

    return json(200, {
      files: files.map((file) => ({
        path: String(file.path),
        size: file.size ?? null,
        content_type: file.content_type ?? null,
        updated_at:
          file.updated_at instanceof Date ? file.updated_at.toISOString() : null,
        owner: file.owner ?? null,
      })),
    });
  } catch (error) {
    console.error('onebase storage: list failed', error);
    return json(503, { error: 'transient failure, retry' });
  }
}

export function handleHealth(): Response {
  return json(200, { status: 'ok' });
}

// Pull sorts on the watermark and filters by owner; without these indexes it
// degrades into a collection scan on every sync. Created once per cold start.
let indexesReady: Promise<void> | null = null;

function ensureIndexes(client: MongoClient, env: Env): Promise<void> {
  indexesReady ??= (async () => {
    const db = client.db(env.MONGO_DB);
    for (const [name, spec] of Object.entries(COLLECTIONS)) {
      const key: Record<string, 1> = {};
      if (spec.ownerField) key[spec.ownerField] = 1;
      key[UPDATED_AT] = 1;
      await db.collection(name).createIndex(key, { name: 'onebase_sync' });
    }
    await db
      .collection(TOMBSTONES)
      .createIndex(
        { collection: 1, owner: 1, deleted_at: 1 },
        { name: 'onebase_tombstones' },
      );
    await db
      .collection(TOMBSTONES)
      .createIndex(
        { deleted_at: 1 },
        { name: 'onebase_ttl', expireAfterSeconds: TOMBSTONE_TTL_SECONDS },
      );
  })().catch((error: unknown) => {
    // Never block writes on index creation — retry on the next request.
    indexesReady = null;
    console.warn('onebase: index setup failed, continuing', error);
  });
  return indexesReady;
}

// Dev-only login: exchanges an email for a signed HS256 JWT so the quickstart
// needs no third-party auth provider. Only reachable when AUTH_MODE=dev.
// NOT for production — anyone who knows an email can get that user's token.
export async function handleToken(
  request: Request,
  env: Env,
): Promise<Response> {
  if (env.AUTH_MODE !== 'dev') {
    return json(404, { error: 'dev token endpoint is disabled (AUTH_MODE != dev)' });
  }
  if (request.method !== 'POST') {
    return json(405, { error: 'method not allowed' });
  }
  if (!env.JWT_SECRET) {
    return json(500, { error: 'JWT_SECRET is not configured' });
  }

  let email: unknown;
  try {
    email = ((await request.json()) as { email?: unknown }).email;
  } catch {
    email = undefined;
  }
  if (typeof email !== 'string' || !email.includes('@')) {
    return json(400, { error: 'body must be {"email": "you@example.com"}' });
  }

  const sub = await stableUserId(email.trim().toLowerCase());
  const token = await new SignJWT({ email })
    .setProtectedHeader({ alg: 'HS256', kid: 'onebase-dev' })
    .setSubject(sub)
    .setAudience(env.JWT_AUDIENCE ?? 'onebase-dev')
    .setIssuedAt()
    .setExpirationTime('12h')
    .sign(new TextEncoder().encode(env.JWT_SECRET));

  return json(200, { token, user_id: sub, expires_in: 43200 });
}

async function stableUserId(input: string): Promise<string> {
  const digest = await crypto.subtle.digest(
    'SHA-256',
    new TextEncoder().encode(input),
  );
  return Array.from(new Uint8Array(digest))
    .slice(0, 12)
    .map((byte) => byte.toString(16).padStart(2, '0'))
    .join('');
}

import 'dart:convert';

import '../../schema/schema.dart';

/// Builds the `COLLECTIONS` TypeScript constant from the schema: the upload
/// endpoint needs the owner field (per-user enforcement) and the field types
/// (to convert client values into proper BSON).
String buildCollectionsTs(MongoEasySchema schema) {
  final spec = {
    for (final collection in schema.collections.values)
      collection.name: {
        if (collection.ownerField != null) 'ownerField': collection.ownerField,
        'fields': {
          for (final MapEntry(:key, :value) in collection.fields.entries)
            key: value.yamlName,
        },
      },
  };
  return const JsonEncoder.withIndent('  ').convert(spec);
}

/// Platform-neutral core of the generated backend (Web-standard
/// Request/Response). Placeholders: `__IMPORTS__`, `__COLLECTIONS__`.
///
/// Response-code contract (required by PowerSync):
/// - 2xx even for validation problems (reported in `skipped`) — a permanent
///   non-2xx would block the client's upload queue forever;
/// - 5xx only for transient/infrastructure failures, which clients retry;
/// - 401 for auth failures, making the client refresh its token.
const backendCoreTs = r'''
__IMPORTS__

type FieldType = 'text' | 'int' | 'double' | 'bool' | 'datetime' | 'json';

interface CollectionSpec {
  ownerField?: string;
  fields: Record<string, FieldType>;
}

const COLLECTIONS: Record<string, CollectionSpec> = __COLLECTIONS__;

interface UploadOp {
  op: 'put' | 'patch' | 'delete';
  collection: string;
  id: string;
  data?: Record<string, unknown>;
}

interface UploadPayload {
  transaction_id?: number | null;
  ops: UploadOp[];
}

export interface Env {
  MONGO_URI: string;
  MONGO_DB: string;
  /** 'dev' = HS256 shared secret; 'jwks' = asymmetric keys from JWKS_URL. */
  AUTH_MODE: string;
  JWT_SECRET?: string;
  JWKS_URL?: string;
  JWT_AUDIENCE?: string;
}

export function readEnv(get: (key: string) => string | undefined): Env {
  const need = (key: string): string => {
    const value = get(key);
    if (!value) throw new Error(`Missing required env var: ${key}`);
    return value;
  };
  return {
    MONGO_URI: need('MONGO_URI'),
    MONGO_DB: need('MONGO_DB'),
    AUTH_MODE: get('AUTH_MODE') ?? 'dev',
    JWT_SECRET: get('JWT_SECRET'),
    JWKS_URL: get('JWKS_URL'),
    JWT_AUDIENCE: get('JWT_AUDIENCE'),
  };
}

async function verifyToken(token: string, env: Env): Promise<string> {
  const options = env.JWT_AUDIENCE ? { audience: env.JWT_AUDIENCE } : {};
  let payload;
  if (env.AUTH_MODE === 'jwks') {
    if (!env.JWKS_URL) throw new Error('JWKS_URL is not configured');
    const jwks = createRemoteJWKSet(new URL(env.JWKS_URL));
    payload = (await jwtVerify(token, jwks, options)).payload;
  } else {
    if (!env.JWT_SECRET) throw new Error('JWT_SECRET is not configured');
    const secret = new TextEncoder().encode(env.JWT_SECRET);
    payload = (await jwtVerify(token, secret, options)).payload;
  }
  if (!payload.sub) throw new Error('token has no sub claim');
  return payload.sub;
}

function convertValue(value: unknown, type: FieldType | undefined): unknown {
  if (value === null || value === undefined || type === undefined) {
    return value ?? null;
  }
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

function convertDocument(
  data: Record<string, unknown>,
  spec: CollectionSpec,
): Record<string, unknown> {
  const doc: Record<string, unknown> = {};
  for (const [key, value] of Object.entries(data)) {
    if (key === '_id' || key === 'id') continue;
    doc[key] = convertValue(value, spec.fields[key]);
  }
  return doc;
}

// mongo_easy generates UUID string ids; documents created server-side may
// use ObjectId. Match either representation.
function idFilter(id: string): Record<string, unknown> {
  if (/^[0-9a-f]{24}$/.test(id)) {
    return { _id: { $in: [id, new ObjectId(id)] } };
  }
  return { _id: id };
}

function idValue(id: string): string | ObjectId {
  return /^[0-9a-f]{24}$/.test(id) ? new ObjectId(id) : id;
}

interface SkippedOp {
  id: string;
  collection: string;
  reason: string;
}

function isDuplicateKeyError(error: unknown): boolean {
  return (
    typeof error === 'object' &&
    error !== null &&
    'code' in error &&
    (error as { code?: number }).code === 11000
  );
}

async function applyOps(
  client: MongoClient,
  dbName: string,
  userId: string,
  ops: UploadOp[],
): Promise<SkippedOp[]> {
  const db = client.db(dbName);
  const skipped: SkippedOp[] = [];

  for (const op of ops) {
    const spec = COLLECTIONS[op.collection];
    if (!spec) {
      skipped.push({
        id: op.id,
        collection: op.collection,
        reason: 'unknown collection — re-run `dart run mongo_easy:setup` and redeploy',
      });
      continue;
    }

    const collection = db.collection(op.collection);
    const owner = spec.ownerField;
    const scopedFilter = owner
      ? { ...idFilter(op.id), [owner]: userId }
      : idFilter(op.id);

    try {
      if (op.op === 'put') {
        const doc = convertDocument(op.data ?? {}, spec);
        if (owner) doc[owner] = userId; // ownership is server-assigned
        const replaced = await collection.replaceOne(scopedFilter, doc);
        if (replaced.matchedCount === 0) {
          await collection.insertOne({ _id: idValue(op.id), ...doc } as never);
        }
      } else if (op.op === 'patch') {
        const changes = convertDocument(op.data ?? {}, spec);
        if (owner) delete changes[owner]; // ownership is immutable
        if (Object.keys(changes).length === 0) continue;
        const updated = await collection.updateOne(scopedFilter, {
          $set: changes,
        });
        if (updated.matchedCount === 0) {
          skipped.push({
            id: op.id,
            collection: op.collection,
            reason: 'not found or not owned by this user',
          });
        }
      } else if (op.op === 'delete') {
        const deleted = await collection.deleteOne(scopedFilter);
        if (deleted.deletedCount === 0) {
          skipped.push({
            id: op.id,
            collection: op.collection,
            reason: 'not found or not owned by this user',
          });
        }
      }
    } catch (error) {
      if (isDuplicateKeyError(error)) {
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

  return skipped;
}

let mongoClient: MongoClient | null = null;

async function getMongo(env: Env): Promise<MongoClient> {
  if (!mongoClient) {
    mongoClient = new MongoClient(env.MONGO_URI);
    await mongoClient.connect();
  }
  return mongoClient;
}

function json(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'content-type': 'application/json' },
  });
}

export async function handleUpload(
  request: Request,
  env: Env,
): Promise<Response> {
  if (request.method !== 'POST') {
    return json(405, { error: 'method not allowed' });
  }

  const authorization = request.headers.get('authorization') ?? '';
  if (!authorization.startsWith('Bearer ')) {
    return json(401, { error: 'missing bearer token' });
  }

  let userId: string;
  try {
    userId = await verifyToken(authorization.slice(7), env);
  } catch (error) {
    return json(401, { error: `invalid token: ${String(error)}` });
  }

  let payload: UploadPayload;
  try {
    payload = (await request.json()) as UploadPayload;
  } catch {
    return json(400, { error: 'body must be JSON' });
  }
  if (!Array.isArray(payload.ops)) {
    return json(400, { error: 'body must contain an ops array' });
  }

  try {
    const client = await getMongo(env);
    const skipped = await applyOps(client, env.MONGO_DB, userId, payload.ops);
    if (skipped.length > 0) {
      console.warn('mongo_easy upload: skipped ops', JSON.stringify(skipped));
    }
    // Always 2xx once ops were processed — validation problems are reported,
    // not turned into errors, so the client queue never gets stuck.
    return json(200, {
      applied: payload.ops.length - skipped.length,
      skipped,
    });
  } catch (error) {
    console.error('mongo_easy upload: transient failure', error);
    return json(503, { error: 'transient failure, client will retry' });
  }
}

// Dev-only login: exchanges an email for a signed HS256 JWT so the quickstart
// needs no third-party auth provider. Disabled unless AUTH_MODE=dev.
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
    .setProtectedHeader({ alg: 'HS256', kid: 'mongo-easy-dev' })
    .setSubject(sub)
    .setAudience(env.JWT_AUDIENCE ?? 'mongo-easy-dev')
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
''';

/// Fills the core template for a concrete platform.
String renderBackendCore(MongoEasySchema schema, {required String imports}) {
  return backendCoreTs
      .replaceFirst('__IMPORTS__', imports)
      .replaceFirst('__COLLECTIONS__', buildCollectionsTs(schema));
}

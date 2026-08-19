# Changelog

## 0.3.0

**Renamed from `mongo_easy` to `mongobase`.** The package now covers the whole
backend — database, realtime and (next) file storage — so the name says
platform rather than convenience wrapper. Update your dependency, change
`package:mongo_easy/mongo_easy.dart` to `package:mongobase/mongobase.dart`,
rename `mongo_easy.yaml` to `mongobase.yaml`, and re-run
`dart run mongobase:setup --force`. The classes follow the same rule:
`MongoEasy` → `Mongobase`, `MongoEasyConfig` → `MongobaseConfig`.

**PowerSync is gone.** mongobase now owns the whole path: one package, one
tiny backend, no third-party sync service or account. Offline is a choice,
realtime is real, and your models are generated.

### Modes

- `MongobaseConfig.mode` picks `MongobaseMode.offline` (default — local SQLite
  replica, works with no network) or `MongobaseMode.online` (thin client, every
  read and write hits the backend). The collection API is identical in both, so
  switching is one line.
- Online writes throw on failure instead of queueing, so your UI can show the
  error rather than pretending it worked.

### Realtime

- `realtime: true` (default) opens a Server-Sent Events channel backed by
  MongoDB change streams, so a change reaches other devices in milliseconds
  instead of on the next poll.
- Ownership is re-checked on every event before it leaves the server; deletes
  arrive as tombstones.
- `realtimeCollections` narrows the subscription to part of the schema.
- The connection is expected to drop — reconnection is automatic with backoff,
  and the periodic sync remains the safety net, so realtime degrades to polling
  rather than losing data. `isRealtimeConnected` and `realtimeState` expose the
  state for a "live" badge.

### Generated models

- `dart run mongobase:setup` now generates a typed model per collection plus
  `MongobaseDb.todos` accessors — no hand-written model classes, no
  `withConverter` wiring.
- A trailing `!` in the YAML (`title: text!`) makes a field required:
  non-nullable in Dart and enforced by the backend on whole-document writes.
- `model:` overrides the generated class name when the default singularization
  reads wrong.

### File storage

- Buckets are declared under `storage:` in `mongobase.yaml`, with the same
  private/shared model as collections:
  `Mongobase.storage.ref('avatars/me.png').putData(bytes)`.
- Bytes go straight from the device to your object store through a presigned
  URL, so they never pass through the backend. Works with anything
  S3-compatible — AWS S3, Cloudflare R2, MinIO, Backblaze B2, Spaces.
- Private buckets namespace object keys by user id, so one user cannot name or
  read another user's file. Path traversal is rejected rather than sanitized.
- The presigned URL pins the content type and length, so the object store
  itself rejects an upload larger than the bucket allows.
- Storage is opt-in: with no `S3_*` variables set, the routes answer 501.
- The SigV4 presigner is implemented on `node:crypto` rather than the AWS SDK,
  which would be larger than the rest of the backend, and is verified against
  AWS's published worked example.

### Doctor

- `dart run mongobase:setup --doctor [--api-url ...]` diagnoses schema drift
  between the app and the deployed backend, `.env` problems, an unsafe
  `AUTH_MODE`, missing storage credentials, and reachability — each with the
  command that fixes it.

### Breaking

- `MongobaseConfig` takes a single `apiUrl` instead of `powersyncUrl` +
  `uploadUrl`, and must not end with a slash.
- `powersync` and `sqlite3_flutter_libs` (eol) are replaced by `sqlite_async`.
- `SyncStatus` is mongobase's own type now, reporting `connected`,
  `downloading`, `uploading`, `pendingWrites`, `lastSyncedAt`, `offlineReason`
  and `error`.
- The CLI generates one backend at `backend/`. `--auto`, `--self-host`,
  `--target` and `powersync/sync-streams.yaml` are removed.
- The write route moved from `/api/upload` to `/push`, with payload
  `{transactions: [{id, ops}]}`.
- Field names starting with `_` are rejected by the schema parser; they are
  reserved for mongobase.

### The sync engine

- Local replica is plain SQLite through `sqlite_async`; `watch()` stays
  push-based via table-change detection.
- Writes land in the local table and an outbox in **one transaction**, so a
  crash can never leave a row that will not be uploaded.
- Sync pushes before it pulls, and pending writes are replayed on top of every
  incoming snapshot, keeping optimistic UI visible until the server confirms.
- Failures never throw into app code — they land in `status` and retry with
  exponential backoff, capped at 5 minutes.

### The backend

- Five routes — `POST /push`, `POST /pull`, `POST /query`, `GET /stream`,
  `POST /token` — plus `GET /health`, behind one router so each host adapter is
  a few lines.
- Runs anywhere: `node dist/server.js`, the included `Dockerfile`, or Vercel.
- `/query` accepts only a closed set of operators and fields declared in your
  schema, so a client filter can never become an arbitrary database query.
- Pull is incremental against an `_updated_at` watermark, owner-scoped, paged,
  and ignores the most recent second so transactions committing out of
  timestamp order cannot slip behind the cursor.
- Deletes are recorded in `_mongobase_tombstones` (30-day TTL), leaving your
  collections clean.
- Sync indexes are created automatically on first request.
- Keeps every guarantee from 0.2.1: required `AUTH_MODE`, pinned JWT
  algorithms, audience and issuer checks, server-assigned ownership,
  declared-fields-only writes, `$set` merge, and transactional batches.

### Testing

- `tool/e2e` runs the generated backend against a real in-memory MongoDB
  replica set: 30 checks covering cross-user isolation, field allowlisting,
  merge semantics, transactional batches, tombstones, the pull watermark,
  query injection attempts, and realtime delivery.
- `tool/e2e/storage_e2e.ts` runs the storage routes against a real MongoDB and
  a stub object store: 16 checks covering cross-user isolation, path traversal,
  content-type and size enforcement, shared-bucket delete rules, and the 501
  path when storage is unconfigured.
- `tool/e2e/signer_e2e.ts` pins the SigV4 output to AWS's worked example.
- New Dart suites for the local store (real SQLite), the sync engine, online
  mode, the realtime client, the wire format, model codegen, storage, and the
  doctor.

## 0.2.1

Backend hardening — regenerate and redeploy with
`dart run mongobase:setup --force` to pick these up.

**Breaking**

- `AUTH_MODE` is now required and validated (`dev` | `hs256` | `jwks`). It no
  longer defaults to `dev`, so a forgotten env var can't leave the `/token`
  endpoint — which signs a JWT for any email — exposed in production. Add
  `AUTH_MODE` to your deployment's env vars before redeploying.
- New `hs256` mode: shared-secret verification with the dev `/token`
  endpoint disabled, for production setups where your own service signs
  tokens.
- `AUTH_MODE=jwks` now requires `JWT_AUDIENCE` (so tokens your provider
  issued for other applications are rejected) and an `https` `JWKS_URL`.
  Shared-secret modes require a `JWT_SECRET` of at least 32 characters.

**Security**

- The upload endpoint now writes only fields declared in `mongobase.yaml`.
  Undeclared keys in a client payload are dropped and logged, closing a mass
  assignment hole where a patched client could set server-managed fields.
- `put` applies a `$set` upsert instead of replacing the document, so fields
  your backend maintains outside the schema survive a client write.
- JWT algorithms are pinned (HS256 for shared secrets, asymmetric for JWKS),
  the optional `JWT_ISSUER` claim is verified when set, and token
  verification errors are no longer echoed to the client.
- The Cloudflare Workers target now runs its configuration through
  `readEnv`, so it gets the same validation as the other targets instead of
  silently accepting a half-configured environment.

**Fixed**

- Uploads run inside a MongoDB transaction when the deployment supports one,
  so a batch of ops lands all-or-nothing. Standalone mongod falls back to
  per-op writes with a one-time warning; every op is idempotent, so a client
  retry converges either way.
- Malformed ops are rejected before reaching MongoDB and reported in
  `skipped` rather than crashing the request.
- The MongoDB client promise is cached and cleared on connection failure, so
  a failed cold start no longer leaves an unusable client behind.

## 0.2.0

- One-command setup: `dart run mongobase:setup --auto --mongo-uri ...`
  provisions the PowerSync Cloud instance, deploys sync streams, configures
  dev auth on both sides, deploys the Vercel backend with env vars, and
  writes `lib/mongobase_endpoints.g.dart`.
- Self-hosted mode: `--self-host --mongo-uri ...` generates a docker-compose
  deployment (PowerSync service + upload backend) wired to your MongoDB —
  no third-party accounts.

## 0.1.0

Initial release.

- Firestore-style API over PowerSync + MongoDB Atlas: `Mongobase.init`,
  `collection()`, `find/findOne/findById/count`, `insert/update/delete`,
  reactive `watch()` streams.
- Chainable query builder compiled to parameterized SQLite: `where` with
  `isEqualTo / isNotEqualTo / isGreaterThan(OrEqualTo) / isLessThan(OrEqualTo)
  / whereIn / isNull`, `orderBy`, `limit`, `offset`, and dot-path queries on
  `json` fields.
- Typed collections via `withConverter<T>` (`fromJson`/`toJson`).
- Provider-agnostic auth: `TokenProvider` callback works with Supabase,
  Firebase, Auth0 or custom JWTs; automatic owner-field assignment from the
  token's `sub`.
- Offline-first writes with automatic background upload and
  PowerSync-compliant retry semantics.
- `dart run mongobase:setup` CLI: starter schema, PowerSync Sync Streams
  YAML, Dart schema codegen, and a deployable upload backend (+ dev-token
  endpoint) for Vercel, Supabase Edge Functions, or Cloudflare Workers.
- Example Todo app: login, per-user data, offline banner, realtime sync.

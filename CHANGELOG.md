# Changelog

## 0.2.0

- One-command setup: `dart run mongo_easy:setup --auto --mongo-uri ...`
  provisions the PowerSync Cloud instance, deploys sync streams, configures
  dev auth on both sides, deploys the Vercel backend with env vars, and
  writes `lib/mongo_easy_endpoints.g.dart`.
- Self-hosted mode: `--self-host --mongo-uri ...` generates a docker-compose
  deployment (PowerSync service + upload backend) wired to your MongoDB —
  no third-party accounts.

## 0.1.0

Initial release.

- Firestore-style API over PowerSync + MongoDB Atlas: `MongoEasy.init`,
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
- `dart run mongo_easy:setup` CLI: starter schema, PowerSync Sync Streams
  YAML, Dart schema codegen, and a deployable upload backend (+ dev-token
  endpoint) for Vercel, Supabase Edge Functions, or Cloudflare Workers.
- Example Todo app: login, per-user data, offline banner, realtime sync.

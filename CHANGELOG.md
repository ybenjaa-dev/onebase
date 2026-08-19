# Changelog

## 0.1.0

First release.

### Data

- Firestore-style API over a local SQLite replica: `collection()`,
  `find / findOne / findById / count`, `insert / update / delete`, and
  reactive `watch()` streams.
- Chainable queries with `where` (`isEqualTo`, `isNotEqualTo`,
  `isGreaterThan(OrEqualTo)`, `isLessThan(OrEqualTo)`, `whereIn`, `isNull`),
  `orderBy`, `limit`, `offset`, and dot-path access into `json` fields.
- Typed models generated from `onebase.yaml`, with `OnebaseDb.todos` accessors.
  A trailing `!` on a field makes it required: non-nullable in Dart and
  enforced by the backend.
- Offline and online modes share one API, so switching is a single config line.

### Sync

- Writes land in the local table and an upload queue in one transaction, so a
  crash cannot leave a row that will never reach the server.
- Sync pushes before it pulls, and replays pending writes on top of every
  incoming snapshot, so optimistic UI survives until the server confirms it.
- Failures never throw into app code — they surface on `status` and retry with
  exponential backoff, capped at five minutes.
- Realtime over Server-Sent Events, driven by MongoDB change streams. The
  periodic sync stays on as the safety net, so a dropped stream degrades to
  polling instead of losing data.

### Storage

- S3-compatible file storage: AWS S3, Cloudflare R2, MinIO, Backblaze B2,
  DigitalOcean Spaces.
- Bytes go straight from the device to your bucket through a presigned URL, so
  they never pass through the backend.
- Private buckets namespace object keys by user id; the signed URL pins content
  type and length, so the store itself rejects an upload larger than the bucket
  allows.

### Backend

- One generated TypeScript server. Runs on Node, the included Dockerfile
  (Fly, Railway, Render, Cloud Run, a VPS), or Vercel through the adapter.
- `AUTH_MODE` is required and validated — there is no default, so a forgotten
  environment variable cannot leave the dev token endpoint exposed.
- Ownership is assigned from the verified JWT and never trusted from the
  client. Only fields declared in the schema are written. Batches apply inside
  a MongoDB transaction. Deletes are recorded as tombstones with a 30-day TTL,
  leaving your collections clean.
- `dart run onebase:setup --doctor` diagnoses schema drift between the app and
  the deployed backend, environment problems, and reachability.

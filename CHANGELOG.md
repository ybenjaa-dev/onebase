# Changelog

## 0.3.6

- Added `exportLocalData()` / `importLocalData()`. Offline-first means the
  device is the source of truth between syncs, and until now a dormant
  install had no way out if its backend ever disappeared — no export, no
  backup. Export returns everything currently on the device as plain JSON;
  import restores it on a new device, after a reinstall, or against a new
  backend, queuing every row for upload unless told not to.

## 0.3.5

- The conflict story in the README now matches the engine: last-write-wins
  applies per field, because `update()` uploads only the fields it changed.
  Concurrent edits to different fields of one document merge instead of
  clobbering each other; same-field edits resolve by server commit order.
- `tool/record_demo.sh` works from a fresh clone: it scaffolds the iOS runner
  the repo does not ship, and refuses early with instructions when no
  simulator is booted instead of failing on a null device id.

## 0.3.4

- The generated backend loads its own `.env`, so the documented quickstart —
  `cp .env.example .env` then `npm run dev` — starts instead of exiting on a
  missing `AUTH_MODE`. Docker and Vercel were unaffected; only running it
  locally was broken.
- The backend is generated with a `.gitignore`, so the `.env` you just filled
  with a connection string and S3 keys does not follow the rest of the project
  into a commit.

## 0.3.3

- Generated Dart now goes through `dart format` as it is written, so
  re-running setup no longer produces a file your own formatter rejects, and
  `--doctor` compares the generated schema without tripping over layout.

## 0.3.2

- Every query carries a total order, so results are stable between identical
  calls and paging compares against the order the database actually produced.
- A realtime change replays only the pending edits for the document it touches
  rather than the whole queue, which kept a busy collection from doing work
  proportional to the queue on every event.

## 0.3.1

- Sync indexes now match the queries that actually run: a group-scoped
  collection is indexed by its group, a windowed one carries its date field,
  membership lookups are indexed, and group deletes and storage listings have
  indexes of their own.

## 0.3.0

### Teams and groups

- A collection can belong to a group instead of one user, with membership read
  from a table you already keep and a write rule of `member`, `admin`, `owner`
  or `none`. Reads, writes, sync and realtime are all narrowed to the caller's
  groups, enforced by the backend from the verified token.

### Controlling what syncs

- Each collection chooses how much lives on the device: everything (the
  default), a rolling `window` of recent documents, or `none`.
- `sync: none` keeps a collection off the device entirely while still serving
  reads from the backend, so an app can hold small collections locally and page
  through a large one without downloading it.

### Pagination

- Keyset cursors: `page()` returns items plus a cursor, and `startAfter()`
  resumes from it. Paging seeks to the position rather than counting past
  everything before it, so deep pages stay fast and stay stable while rows are
  being inserted.
- `pager()` drives an infinite-scrolling list — it accumulates pages, ignores
  overlapping `loadMore()` calls, and exposes `refresh()` and `error`.
- `id` is queryable and sortable like any other column.

### Atomic writes

- `Onebase.instance.batch()` groups writes into one MongoDB transaction. Offline
  the batch is queued as a single unit.

### Backend

- Request bodies are capped before parsing, a push is capped at 1000
  operations, and each user has a per-route rate budget per minute.

### Project

- CI runs the test suite, checks the generated backend for drift against the
  templates, and exercises the end-to-end suites against a real MongoDB.

## 0.1.3

Maintenance release.

- The native SQLite library now comes from `sqlite3` itself rather than the
  separate `sqlite3_flutter_libs` package, which its author has discontinued.
  This sets the floor at Dart 3.10 / Flutter 3.38; `pub` keeps older projects
  on earlier releases.
- Every dependency moved to its latest version, including the generated
  backend's: jose 6, the MongoDB driver 7, `@types/node` 26, `flutter_lints` 6.
- Internal improvements to the CLI and code generation.

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

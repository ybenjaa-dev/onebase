# Local E2E harness

Runs the entire mongo_easy pipeline on your machine — no cloud accounts:

- MongoDB 7 single-node replica set (Docker, host port **27018** to avoid a
  locally installed mongod)
- Self-hosted PowerSync service (Docker, port 8080) with the CLI-generated
  sync streams and an HS256 dev key
- The CLI-generated Vercel upload backend, run locally via a Node bridge
  (port 3300)

## Run

```bash
./run.sh          # brings up Docker, installs deps, starts the backend
```

The generated backend's own deps must be installed once:
`(cd ../../example/backend/vercel && npm install)`.

## Test

```bash
cd ../../example
flutter test integration_test/e2e_test.dart -d macos \
  --dart-define=POWERSYNC_URL=http://localhost:8080 \
  --dart-define=UPLOAD_URL=http://localhost:3300/upload \
  --dart-define=TOKEN_URL=http://localhost:3300/token
```

Covers: insert/update/delete round-trips through real MongoDB (BSON type
fidelity, id preservation, server-side owner assignment), query builder
against synced data, and per-user sync isolation.

Or run the example app interactively against the same stack:

```bash
flutter run -d macos \
  --dart-define=POWERSYNC_URL=http://localhost:8080 \
  --dart-define=UPLOAD_URL=http://localhost:3300/upload \
  --dart-define=TOKEN_URL=http://localhost:3300/token
```

## Teardown

```bash
docker compose down -v
```

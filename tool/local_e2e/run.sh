#!/usr/bin/env bash
# Local end-to-end harness: MongoDB replica set + self-hosted PowerSync +
# the CLI-generated upload backend. Then run the example integration test:
#
#   cd example && flutter test integration_test/e2e_test.dart -d macos \
#     --dart-define=POWERSYNC_URL=http://localhost:8080 \
#     --dart-define=UPLOAD_URL=http://localhost:3300/upload \
#     --dart-define=TOKEN_URL=http://localhost:3300/token
set -euo pipefail
cd "$(dirname "$0")"

export MONGO_URI='mongodb://localhost:27018/?directConnection=true'
export MONGO_DB='mongo_easy_demo'
export AUTH_MODE='dev'
export JWT_SECRET='mongo-easy-local-e2e-secret-0123456789abcdef'
export JWT_AUDIENCE='powersync-dev'
export PORT='3300'

echo "▸ starting MongoDB + PowerSync (docker compose)…"
docker compose up -d --wait

echo "▸ installing backend deps…"
(cd backend && npm install --silent)

echo "▸ starting local upload backend on :$PORT…"
(cd backend && exec npx tsx server.ts)

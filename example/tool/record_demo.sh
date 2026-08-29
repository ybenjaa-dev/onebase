#!/usr/bin/env bash
# Records the launch demo GIF: signs in, writes online, loses the backend,
# keeps writing, then reconnects and syncs. Drives the app with
# integration_test/demo_recording.dart and captures the simulator framebuffer
# only (never the desktop).
set -euo pipefail

DEVICE="${DEVICE:-$(xcrun simctl list devices booted -j | jq -r '[.devices[][]] | .[0].udid')}"
API_URL="${API_URL:-http://localhost:3000}"
MONGO_DB="${MONGO_DB:-onebase_demo}"
OUT_DIR="${OUT_DIR:-$(pwd)/demo}"
BACKEND_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../backend" && pwd)"
EXAMPLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

mkdir -p "$OUT_DIR"
MOV="$OUT_DIR/demo.mov"
GIF="$OUT_DIR/onebase-demo.gif"

backend_pid=""
record_pid=""
test_pid=""

start_backend() {
  (cd "$BACKEND_DIR" && npm run dev >/tmp/onebase-backend.log 2>&1) &
  backend_pid=$!
  for _ in $(seq 1 25); do
    if curl -fsS "$API_URL/health" >/dev/null 2>&1; then return 0; fi
    sleep 1
  done
  echo "backend did not come up" >&2
  return 1
}

stop_backend() {
  pkill -f "tsx .*src/server.ts" 2>/dev/null || true
  [ -n "$backend_pid" ] && kill "$backend_pid" 2>/dev/null || true
  backend_pid=""
}

cleanup() {
  [ -n "$record_pid" ] && kill -INT "$record_pid" 2>/dev/null || true
  [ -n "$test_pid" ] && kill "$test_pid" 2>/dev/null || true
  stop_backend
}
trap cleanup EXIT

echo "==> resetting demo database"
mongosh "mongodb://127.0.0.1:27017/?replicaSet=rs0" --quiet \
  --eval "db.getSiblingDB('$MONGO_DB').dropDatabase()" >/dev/null

echo "==> starting backend"
stop_backend
start_backend

echo "==> driving the app"
: >/tmp/onebase-demo-test.log
(cd "$EXAMPLE_DIR" && flutter test integration_test/demo_recording.dart \
  -d "$DEVICE" --dart-define=API_URL="$API_URL" \
  >>/tmp/onebase-demo-test.log 2>&1) &
test_pid=$!

# Record only once the app is actually on screen, so the GIF has no dead
# lead-in while Xcode builds.
echo "==> waiting for the app to launch"
for _ in $(seq 1 300); do
  grep -q "launch demo" /tmp/onebase-demo-test.log && break
  sleep 1
done

echo "==> starting recording"
xcrun simctl io "$DEVICE" recordVideo --codec h264 --force "$MOV" &
record_pid=$!

# The first synced todo tells us sign-in and the online write both landed.
echo "==> waiting for the first synced write"
for _ in $(seq 1 180); do
  count=$(mongosh "mongodb://127.0.0.1:27017/?replicaSet=rs0" --quiet \
    --eval "db.getSiblingDB('$MONGO_DB').todos.countDocuments({})" 2>/dev/null || echo 0)
  [ "${count:-0}" -ge 1 ] && break
  sleep 1
done

echo "==> cutting the backend"
sleep 2
stop_backend

echo "==> writing offline"
sleep 14

echo "==> bringing the backend back"
start_backend

echo "==> letting it sync on camera"
sleep 22

echo "==> stopping recording"
kill -INT "$record_pid" 2>/dev/null || true
wait "$record_pid" 2>/dev/null || true
record_pid=""
kill "$test_pid" 2>/dev/null || true
test_pid=""

echo "==> converting to gif"
ffmpeg -y -loglevel error -i "$MOV" \
  -vf "fps=12,scale=380:-1:flags=lanczos,split[s0][s1];[s0]palettegen=max_colors=128[p];[s1][p]paletteuse=dither=bayer:bayer_scale=3" \
  -loop 0 "$GIF"

ls -lh "$GIF"
echo "==> done: $GIF"

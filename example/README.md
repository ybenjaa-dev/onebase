# mongobase example — offline-first todos

A complete Riverpod + hooks app on mongobase: email login, per-user todos,
reactive lists, a live indicator, and writes that work with the network off.
The `Todo` model and `MongobaseDb.todos` are generated from
`mongobase.yaml` — there is no hand-written model in this app.

## Run it

1. **Generate models and backend**

   ```bash
   dart run ../bin/setup.dart
   ```

2. **Configure and start the backend**

   ```bash
   cd backend
   cp .env.example .env      # MONGO_URI, MONGO_DB, AUTH_MODE=dev, JWT_SECRET
   npm install && npm run dev
   ```

   Any MongoDB with a replica set works — a free Atlas M0 included.

3. **Run the app**

   ```bash
   flutter run --dart-define=API_URL=http://localhost:3000
   ```

   On an Android emulator use `http://10.0.2.2:3000`. Add
   `--dart-define=ONLINE=true` to run it as a thin online client with no local
   database.

## What to try

- Add a todo, then turn off Wi-Fi and add more: they appear instantly and the
  banner shows how many are waiting to upload.
- Open the app on a second device with the same email and edit something —
  it appears on the first device immediately. The banner reads **Live** while
  the realtime channel is connected.
- Sign in with a different email: the list is empty. Isolation is enforced by
  the backend from the JWT, not the client — a patched app cannot see another
  user's rows.
- Run with `--dart-define=ONLINE=true` and compare: same UI, same code, no
  local database, and nothing works offline.

## Checking the setup

```bash
dart run ../bin/setup.dart --doctor --api-url http://localhost:3000
```

## Backend end-to-end tests

`tool/e2e` runs the generated backend against a real in-memory MongoDB replica
set. See `tool/e2e/README.md`.

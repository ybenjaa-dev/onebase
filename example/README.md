# mongo_easy example — offline-first Todos on MongoDB Atlas

A complete Todo app: email login, per-user data, offline mode, and realtime
sync — with **zero backend code written by hand**.

## Run it

1. **Generate + deploy the backend** (from this directory):

   ```bash
   dart run mongo_easy:setup            # already generated into this folder
   cd backend/vercel && npm install && npx vercel deploy --prod
   ```

   Follow the printed checklist: create a free MongoDB Atlas cluster and a
   free PowerSync instance, paste `powersync/sync-streams.yaml`, configure
   the shared HS256 dev secret on both sides.

2. **Point the app at your deployment** — edit `lib/config.dart`:

   ```dart
   static const powersyncUrl = 'https://<instance>.powersync.journeyapps.com';
   static const uploadUrl    = 'https://<project>.vercel.app/api/upload';
   static const tokenUrl     = 'https://<project>.vercel.app/api/token';
   ```

3. **Add platforms and run:**

   ```bash
   flutter create . --platforms=ios,android,macos
   flutter run
   ```

   On macOS, add the outgoing-network entitlement to both
   `macos/Runner/DebugProfile.entitlements` and `Release.entitlements`:

   ```xml
   <key>com.apple.security.network.client</key>
   <true/>
   ```

## What to try

- Sign in with any email (dev-token auth — see the security notes in the
  main README before shipping).
- Add todos, toggle, swipe to delete — everything is instant (local SQLite).
- Turn on airplane mode, keep editing, reconnect: changes upload
  automatically (watch the sync banner).
- Run the app on two devices with the same email: edits appear on both in
  realtime.
- Sign in with a different email: you get an empty list — isolation is
  enforced by PowerSync Sync Streams on the server, not by the client.

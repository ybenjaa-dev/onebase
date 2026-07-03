# mongo_easy

**Firebase-like developer experience for MongoDB Atlas in Flutter.**
Offline-first, realtime, per-user data — without writing a backend.

MongoDB retired Realm, Atlas Device Sync and the Data API (EOL September 30,
2025), leaving Flutter developers without an official "no backend" path to
MongoDB. `mongo_easy` fills that gap: a Firestore-style API on top of the
[PowerSync](https://www.powersync.com) sync engine, which officially supports
MongoDB as a source database, plus a CLI that generates every piece of
configuration and server code you need.

```dart
await MongoEasy.init(MongoEasyConfig(
  powersyncUrl: 'https://<instance>.powersync.journeyapps.com',
  uploadUrl: 'https://<project>.vercel.app/api/upload',
  tokenProvider: TokenProvider(() async => myAuth.currentJwt),
  schema: mongoEasySchema, // generated
));

final todos = MongoEasy.collection('todos');

// Reactive UI — like Firestore snapshots:
Stream<List<Map<String, Object?>>> live = todos
    .where('done', isEqualTo: false)
    .orderBy('created_at', descending: true)
    .limit(50)
    .watch();

// Offline-first writes — instant locally, synced in the background:
final id = await todos.insert({'title': 'Ship it'});
await todos.update(id, {'done': true});
await todos.delete(id);
```

## How it works

```mermaid
flowchart LR
    subgraph Device
        A[Flutter app<br/>mongo_easy API] --> B[(Local SQLite<br/>offline-first)]
    end
    B <-->|"sync (reads)<br/>JWT-authenticated"| C[PowerSync Service<br/>Sync Streams filter<br/>per user]
    B -->|"writes (upload queue)<br/>same JWT"| D[Generated upload endpoint<br/>Vercel / Supabase / Cloudflare]
    C <-->|change streams| E[(MongoDB Atlas)]
    D -->|verified writes| E
```

- **Reads**: PowerSync replicates the MongoDB documents each user is allowed
  to see (via server-side Sync Streams) into a local SQLite database. Queries
  and `watch()` streams run against that replica — instant, and fully
  functional offline.
- **Writes**: go to SQLite first, queue locally, and upload in the background
  to a small serverless endpoint that `mongo_easy` **generates for you** —
  it verifies the user's JWT and applies the changes to MongoDB.
- **No credentials in the app**: the client only ever knows your PowerSync
  URL, your upload endpoint URL, and the signed-in user's JWT.

## Quickstart (~10 minutes)

**1. Install**

```yaml
dependencies:
  mongo_easy: ^0.1.0
  sqlite3_flutter_libs: ^0.6.0+eol
```

**2. Describe your data** — create `mongo_easy.yaml`:

```bash
dart run mongo_easy:setup --init
```

```yaml
collections:
  todos:
    owner_field: owner_id        # per-user isolation (enforced server-side)
    fields:
      title: text
      done: bool
      created_at: datetime
      owner_id: text
```

Field types: `text`, `int`, `double`, `bool`, `datetime`, `json`
(`json` fields hold nested documents/arrays and are queryable with
dot-paths: `where('address.city', isEqualTo: 'Rabat')`).

**3. Generate everything**

```bash
dart run mongo_easy:setup
```

This writes:

| File | What it is |
|---|---|
| `powersync/sync-streams.yaml` | Server-side sync rules — paste into PowerSync |
| `lib/mongo_easy_schema.g.dart` | The Dart schema for `MongoEasy.init` |
| `backend/<target>/…` | A ready-to-deploy upload endpoint (Vercel, Supabase Edge Functions, or Cloudflare Workers) |

…and prints a checklist: create a free [MongoDB Atlas](https://www.mongodb.com/cloud/atlas)
cluster (M0 works) and a free [PowerSync Cloud](https://accounts.journeyapps.com/portal/powersync-signup)
instance, connect them, paste the sync streams, deploy the backend with one
command (`npx vercel deploy --prod`).

### Or skip the checklist: one-command setup

**Managed (`--auto`)** — provide your MongoDB connection string; the CLI
provisions everything else on free tiers:

```bash
export PS_ADMIN_TOKEN=<PowerSync Dashboard → Account Settings → token>
npx vercel login          # once
dart run mongo_easy:setup --auto --mongo-uri "mongodb+srv://user:pass@cluster.mongodb.net/mydb"
```

It creates the PowerSync Cloud instance connected to your cluster, deploys
the sync streams, configures a shared dev-auth secret on both sides, deploys
the backend to Vercel with all env vars, and writes the resulting URLs into
`lib/mongo_easy_endpoints.g.dart` — nothing to copy-paste:

```dart
await MongoEasy.init(MongoEasyConfig(
  powersyncUrl: MongoEasyEndpoints.powersyncUrl,
  uploadUrl: MongoEasyEndpoints.uploadUrl,
  ...
));
```

**Self-hosted (`--self-host`)** — no third-party accounts at all; you run
the backend wherever Docker runs:

```bash
dart run mongo_easy:setup --self-host --mongo-uri "mongodb+srv://..."
cd deploy/self-host && docker compose up -d
```

This generates a docker-compose bundling the (source-available) PowerSync
service and your upload backend, wired to your MongoDB. Works against any
MongoDB 6.0+ replica set — including Atlas free M0.

**4. Initialize and build UI** — see the [example app](example/) for a
complete Todo app with login, offline banner and realtime sync.

## Auth: bring your own JWTs

`mongo_easy` is auth-agnostic — anything that issues JWTs works:

```dart
// Supabase Auth
TokenProvider(() async =>
    Supabase.instance.client.auth.currentSession?.accessToken)

// Firebase Auth
TokenProvider(() => FirebaseAuth.instance.currentUser?.getIdToken())

// Auth0
TokenProvider(() => auth0.credentialsManager.credentials()
    .then((c) => c.accessToken))

// Dev mode: the generated backend includes a /token endpoint that signs
// HS256 JWTs for any email — zero third-party accounts to start.
```

Configure the matching verification in two places (the CLI walks you
through it): your PowerSync instance (Client Auth) and the generated
backend (`AUTH_MODE=jwks` + `JWKS_URL`, or `AUTH_MODE=dev` + `JWT_SECRET`).

Call `MongoEasy.instance.refreshToken()` after sign-in/out, and
`MongoEasy.instance.clearLocalData()` on sign-out so the next user can't see
cached documents.

## Typed models

```dart
final todos = MongoEasy.collection('todos').withConverter<Todo>(
  fromJson: Todo.fromJson,
  toJson: (todo) => todo.toJson(),
);

final Stream<List<Todo>> live = todos.where('done', isEqualTo: false).watch();
final String id = await todos.insert(Todo(title: 'Ship it'));
```

## Security model

- **Per-user isolation is server-side.** Every non-`shared` collection needs
  an `owner_field`. The generated Sync Streams filter reads with
  `WHERE owner_field = auth.user_id()` (the verified JWT `sub`), and the
  generated upload endpoint assigns ownership from the token on insert,
  refuses cross-user updates/deletes, and treats the owner field as
  immutable. A malicious client can't read or write anyone else's documents
  — even with a patched binary.
- **No database credentials ship in the app.** MongoDB is only reachable by
  the PowerSync Service and your upload endpoint.
- **Tokens are verified twice** — by PowerSync (sync) and by the upload
  endpoint (writes), against the same JWKS/secret.
- **Dev mode is explicitly not production.** The `/token` endpoint gives a
  token to anyone who knows an email. It exists so your first sync works in
  minutes; switch `AUTH_MODE=jwks` before shipping.
- Upload responses follow the PowerSync contract: validation problems return
  2xx (reported in `skipped`, logged server-side) so a bad op can never
  wedge the client's upload queue; only transient failures return 5xx and
  retry.

## vs Firebase

| | Firestore | mongo_easy (MongoDB + PowerSync) |
|---|---|---|
| Reactive queries | `snapshots()` | `watch()` |
| Offline-first | Cache-based | Full local SQLite replica |
| Backend code | None | None written — generated & deployed by CLI |
| Data model | Proprietary documents | Real MongoDB — use Atlas tooling, aggregation, BI |
| Queries offline | Limited | Full SQL engine underneath (filters, sorts, json paths) |
| Per-user security | Client-visible security rules | Server-side sync streams + endpoint checks |
| Self-hosting | No | Yes (PowerSync is source-available, Mongo is yours) |
| Free tier | Yes | Yes (Atlas M0 + PowerSync Cloud free + serverless free tiers) |

## Limitations (v0.1)

- Web support follows the `powersync` package's beta status; iOS, Android,
  macOS, Windows and Linux are first-class.
- Queries run on synced data only — a device sees its user's documents (plus
  `shared: true` collections), not the whole database.
- `shared: true` collections are readable and writable by any signed-in
  user; role-based rules are on the roadmap.
- No aggregation pipeline on-device; `count()` and SQL-backed filters cover
  the common cases.
- Cloudflare Workers target is experimental (the `mongodb` driver relies on
  `nodejs_compat`); Vercel and Supabase are recommended.

## Troubleshooting

Every `MongoEasyException` carries a `hint` with the likely fix. Common ones:

- *"Unknown collection"* — add it to `mongo_easy.yaml`, re-run
  `dart run mongo_easy:setup`, redeploy the backend, update the sync streams.
- *"Token is not a JWT"* — your `TokenProvider` returned a session object or
  API key instead of the raw JWT string.
- *Upload returns 401* — the backend's `JWT_SECRET`/`JWKS_URL` doesn't match
  what signs your tokens (must be the same config as PowerSync Client Auth).
- *Nothing syncs down* — check the Sync Streams are deployed and that the
  JWT `aud` matches what PowerSync expects.

## License

MIT © Soft2Scale

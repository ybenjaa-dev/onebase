import '../../schema/schema.dart';
import 'backend_core.dart';

/// Generates the backend: relative path → file content.
///
/// One tiny TypeScript server, three routes, no framework. It runs anywhere
/// Node runs — `node server.js`, a Docker host (Fly, Railway, Render, Cloud
/// Run, a VPS), or Vercel through the included adapter.
Map<String, String> generateBackendFiles(MongoEasySchema schema) {
  final core = renderBackendCore(
    schema,
    imports: backendImports(mongodb: 'mongodb', jose: 'jose'),
  );

  return {
    'src/core.ts': core,
    'src/router.ts': _router,
    'src/server.ts': _server,
    'api/index.ts': _vercelAdapter,
    'package.json': _packageJson,
    'tsconfig.json': _tsconfig,
    'Dockerfile': _dockerfile,
    '.dockerignore': _dockerignore,
    'vercel.json': _vercelJson,
    '.env.example': _envExample,
    'README.md': _readme,
  };
}

/// Routing shared by every host, so the adapters stay trivial.
const _router = r'''
import {
  handleHealth,
  handlePull,
  handlePush,
  handleQuery,
  handleStream,
  handleToken,
  json,
  readEnv,
  type Env,
} from './core.js';

let cached: Env | null = null;

/// Configuration is validated once and reused; an invalid deployment fails
/// every request loudly instead of silently accepting bad tokens.
export function loadEnv(get: (key: string) => string | undefined): Env {
  return (cached ??= readEnv(get));
}

export async function route(request: Request, env: Env): Promise<Response> {
  const path = new URL(request.url).pathname.replace(/\/+$/, '') || '/';
  switch (path) {
    case '/push':
      return handlePush(request, env);
    case '/pull':
      return handlePull(request, env);
    case '/query':
      return handleQuery(request, env);
    case '/stream':
      return handleStream(request, env);
    case '/token':
      return handleToken(request, env);
    case '/health':
    case '/':
      return handleHealth();
    default:
      return json(404, { error: `no route for ${path}` });
  }
}

export function configError(error: unknown): Response {
  console.error('mongo_easy: invalid configuration', error);
  return json(500, { error: 'backend is misconfigured' });
}
''';

const _server = r'''
import { createServer } from 'node:http';
import { Readable } from 'node:stream';
import { configError, loadEnv, route } from './router.js';

const port = Number(process.env.PORT ?? 3000);

const server = createServer(async (req, res) => {
  const chunks: Buffer[] = [];
  for await (const chunk of req) chunks.push(chunk as Buffer);
  const body = Buffer.concat(chunks);

  // Lets a handler notice the client hanging up — the realtime stream uses
  // this to close its change stream instead of leaking one per dropped
  // connection.
  const aborter = new AbortController();
  res.on('close', () => aborter.abort());

  const request = new Request(`http://localhost:${port}${req.url ?? '/'}`, {
    method: req.method,
    headers: Object.fromEntries(
      Object.entries(req.headers).map(([key, value]) => [key, String(value)]),
    ),
    body: body.length > 0 ? body : undefined,
    signal: aborter.signal,
  });

  let response: Response;
  try {
    response = await route(request, loadEnv((key) => process.env[key]));
  } catch (error) {
    response = configError(error);
  }

  const headers: Record<string, string> = {};
  response.headers.forEach((value, key) => {
    headers[key] = value;
  });
  res.writeHead(response.status, headers);

  if (response.body) {
    // Streamed straight through, so Server-Sent Events reach the client as
    // they happen rather than being buffered until the response ends.
    Readable.fromWeb(response.body as never).pipe(res);
  } else {
    res.end();
  }
});

server.listen(port, () => {
  console.log(`mongo_easy backend listening on :${port}`);
});
''';

const _vercelAdapter = r'''
import { configError, loadEnv, route } from '../src/router.js';

export const config = { runtime: 'nodejs' };

export default async function handler(request: Request): Promise<Response> {
  try {
    return await route(request, loadEnv((key) => process.env[key]));
  } catch (error) {
    return configError(error);
  }
}
''';

const _packageJson = '''
{
  "name": "mongo-easy-backend",
  "private": true,
  "type": "module",
  "scripts": {
    "build": "tsc",
    "start": "node dist/server.js",
    "dev": "tsx src/server.ts",
    "typecheck": "tsc --noEmit"
  },
  "dependencies": {
    "jose": "^5.9.0",
    "mongodb": "^6.10.0"
  },
  "devDependencies": {
    "@types/node": "^20.0.0",
    "tsx": "^4.19.0",
    "typescript": "^5.5.0"
  }
}
''';

const _tsconfig = '''
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "NodeNext",
    "moduleResolution": "NodeNext",
    "outDir": "dist",
    "rootDir": ".",
    "strict": true,
    "skipLibCheck": true
  },
  "include": ["src/**/*.ts", "api/**/*.ts"]
}
''';

const _dockerfile = '''
FROM node:22-alpine AS build
WORKDIR /app
COPY package.json tsconfig.json ./
RUN npm install
COPY src ./src
RUN npm run build

FROM node:22-alpine
WORKDIR /app
ENV NODE_ENV=production
COPY package.json ./
RUN npm install --omit=dev
COPY --from=build /app/dist ./dist
EXPOSE 3000
CMD ["node", "dist/src/server.js"]
''';

const _dockerignore = '''
node_modules
dist
.env
''';

const _vercelJson = '''
{
  "rewrites": [{ "source": "/(.*)", "destination": "/api" }]
}
''';

const _envExample = '''
# Copy to .env and fill in. NEVER commit the real file.

MONGO_URI=mongodb+srv://user:password@cluster.mongodb.net
MONGO_DB=myapp

# Required. jwks = production (asymmetric keys), hs256 = production (shared
# secret), dev = quickstart only (also exposes /token, which signs a JWT for
# ANY email address).
AUTH_MODE=dev

# dev / hs256
JWT_SECRET=

# jwks
JWKS_URL=

# Required in jwks mode, recommended everywhere.
JWT_AUDIENCE=
JWT_ISSUER=
''';

const _readme = r'''
# mongo_easy backend

Generated by `dart run mongo_easy:setup`. One tiny server, four routes, no
framework:

| Route | Purpose |
|---|---|
| `POST /push` | applies client writes to MongoDB |
| `POST /pull` | returns documents changed since the client's watermark (offline mode) |
| `POST /query` | runs a query server-side (online mode) |
| `GET /stream` | realtime changes over Server-Sent Events |
| `POST /token` | dev-only email login (disabled unless `AUTH_MODE=dev`) |
| `GET /health` | liveness probe |

`/stream` needs a host that allows long-lived responses — any container host
does. Short-lived serverless functions cut the connection; the client
reconnects automatically and its periodic sync covers the gap, so realtime
degrades to polling rather than breaking.

Point your Flutter app's `apiUrl` at wherever this ends up — mongo_easy
appends the routes itself.

## Run it anywhere

**Docker** (Fly, Railway, Render, Cloud Run, a VPS, your laptop):

```bash
docker build -t mongo-easy-backend .
docker run -p 3000:3000 --env-file .env mongo-easy-backend
```

**Node directly:**

```bash
npm install && npm run build && npm start
```

**Vercel** — `api/index.ts` and `vercel.json` are already wired:

```bash
npx vercel deploy --prod
```

**Local development:**

```bash
npm install && npm run dev
```

## Configuration

Copy `.env.example` to `.env`.

| Variable | Required | Description |
|---|---|---|
| `MONGO_URI` | yes | MongoDB connection string. Needs a replica set for transactions — every Atlas tier qualifies, including free M0. |
| `MONGO_DB` | yes | Database name. |
| `AUTH_MODE` | **yes** | `jwks` · `hs256` · `dev`. No default: the server refuses to start without it. |
| `JWT_SECRET` | `dev`/`hs256` | Shared HS256 secret, 32+ chars. |
| `JWKS_URL` | `jwks` | Your auth provider's JWKS endpoint. Must be `https`. |
| `JWT_AUDIENCE` | `jwks` | Expected `aud`. Required in `jwks` mode so tokens issued for other apps are rejected. |
| `JWT_ISSUER` | no | Expected `iss`. Set it whenever your provider publishes one. |

## What it guarantees

- Every request carries a JWT, verified with pinned algorithms.
- Ownership is assigned from the token and never trusted from the client;
  cross-user reads, updates and deletes are impossible.
- Only fields declared in `mongo_easy.yaml` are written — a patched client
  cannot set server-managed fields.
- `push` applies each batch inside a MongoDB transaction.
- `query` accepts only a closed set of operators and fields declared in your
  schema, so a client filter can never become an arbitrary database query.
- `stream` re-checks ownership on every event before it leaves the process.
- Deletes are recorded in `_mongo_easy_tombstones` (TTL: 30 days) so other
  devices learn about them, leaving your collections clean.
- Sync indexes are created automatically on first request.

`AUTH_MODE=dev` exposes `/token`, which signs a JWT for any email address.
It exists so your first sync works in minutes — switch to `jwks` or `hs256`
before real users arrive.
''';

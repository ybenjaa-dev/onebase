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

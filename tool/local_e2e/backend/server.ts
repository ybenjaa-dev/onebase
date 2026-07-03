// Local runner for the CLI-generated upload backend (the exact code a user
// would deploy to Vercel), bridged onto a plain Node http server.
import { createServer } from 'node:http';
import {
  handleToken,
  handleUpload,
  readEnv,
} from '../../../example/backend/vercel/lib/core';

const env = readEnv((key) => process.env[key]);
const port = Number(process.env.PORT ?? 3300);

const server = createServer(async (req, res) => {
  const chunks: Buffer[] = [];
  for await (const chunk of req) chunks.push(chunk as Buffer);
  const body = Buffer.concat(chunks);

  const request = new Request(`http://localhost:${port}${req.url ?? '/'}`, {
    method: req.method,
    headers: Object.fromEntries(
      Object.entries(req.headers).map(([k, v]) => [k, String(v)]),
    ),
    body: body.length > 0 ? body : undefined,
  });

  let response: Response;
  if (req.url === '/upload') {
    response = await handleUpload(request, env);
  } else if (req.url === '/token') {
    response = await handleToken(request, env);
  } else {
    response = new Response('not found', { status: 404 });
  }

  res.writeHead(
    response.status,
    Object.fromEntries(response.headers.entries()),
  );
  res.end(Buffer.from(await response.arrayBuffer()));
});

server.listen(port, () => {
  console.log(`mongo_easy local backend on http://localhost:${port}`);
});

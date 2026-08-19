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
  console.log(`onebase backend listening on :${port}`);
});

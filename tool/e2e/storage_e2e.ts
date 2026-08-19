// Storage end-to-end: the generated backend against a real MongoDB replica set
// and a stub object store that behaves like S3 for presigned requests.
import assert from 'node:assert/strict';
import { createServer, type Server } from 'node:http';
import { MongoMemoryReplSet } from 'mongodb-memory-server';
import { MongoClient } from 'mongodb';
import { SignJWT } from 'jose';
import {
  handleStorageComplete,
  handleStorageDelete,
  handleStorageDownloadUrl,
  handleStorageList,
  handleStorageUploadUrl,
  readEnv,
} from '../../example/backend/src/core.js';

const SECRET = 'storage-e2e-'.padEnd(40, 'x');

/** Records what the "object store" was asked to do. */
const objects = new Map<string, { body: Buffer; contentType?: string }>();
const seen: { method: string; path: string; query: string }[] = [];

const s3: Server = createServer((req, res) => {
  const url = new URL(req.url ?? '/', 'http://localhost');
  seen.push({ method: req.method ?? '', path: url.pathname, query: url.search });

  // A presigned request carries its authorization in the query string.
  if (!url.searchParams.get('X-Amz-Signature')) {
    res.writeHead(403).end('unsigned');
    return;
  }
  const chunks: Buffer[] = [];
  req.on('data', (c) => chunks.push(c as Buffer));
  req.on('end', () => {
    const key = url.pathname;
    if (req.method === 'PUT') {
      objects.set(key, {
        body: Buffer.concat(chunks),
        contentType: req.headers['content-type'] as string | undefined,
      });
      res.writeHead(200).end();
    } else if (req.method === 'DELETE') {
      objects.delete(key);
      res.writeHead(204).end();
    } else {
      const stored = objects.get(key);
      if (!stored) return void res.writeHead(404).end();
      res.writeHead(200).end(stored.body);
    }
  });
});
await new Promise<void>((r) => s3.listen(0, r));
const s3Port = (s3.address() as { port: number }).port;
const s3Origin = `http://127.0.0.1:${s3Port}`;

const replset = await MongoMemoryReplSet.create({ replSet: { count: 1 } });
const uri = replset.getUri();

const baseEnv = {
  MONGO_URI: uri,
  MONGO_DB: 'e2e_storage',
  AUTH_MODE: 'dev',
  JWT_SECRET: SECRET,
  JWT_AUDIENCE: 'aud',
  S3_ENDPOINT: s3Origin,
  S3_REGION: 'auto',
  S3_BUCKET: 'files',
  S3_ACCESS_KEY_ID: 'key',
  S3_SECRET_ACCESS_KEY: 'secret',
};
const env = readEnv((k) => (baseEnv as Record<string, string>)[k]);
const envNoStorage = readEnv((k) =>
  k.startsWith('S3_') ? undefined : (baseEnv as Record<string, string>)[k],
);

const key = new TextEncoder().encode(SECRET);
const tokenFor = (sub: string) =>
  new SignJWT({}).setProtectedHeader({ alg: 'HS256' }).setSubject(sub)
    .setAudience('aud').setIssuedAt().setExpirationTime('1h').sign(key);
const alice = await tokenFor('alice');
const bob = await tokenFor('bob');

const req = (token: string, body: unknown) =>
  new Request('http://x/storage', {
    method: 'POST',
    headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' },
    body: JSON.stringify(body),
  });

let pass = 0;
const t = async (name: string, fn: () => Promise<void>) => {
  try { await fn(); pass++; console.log('  ok  ' + name); }
  catch (e) { console.log('  FAIL ' + name + ' → ' + e); process.exitCode = 1; }
};

/** Full upload flow: sign, PUT the bytes, record the metadata. */
async function upload(
  token: string,
  bucket: string,
  path: string,
  body: Buffer,
  contentType = 'image/png',
) {
  const signed = await handleStorageUploadUrl(
    req(token, { bucket, path, contentType, size: body.length }),
    env,
  );
  if (signed.status !== 200) return signed;
  const { url, headers } = (await signed.json()) as any;
  const put = await fetch(url, { method: 'PUT', headers, body });
  assert.equal(put.status, 200, 'stub store rejected the presigned PUT');
  return handleStorageComplete(
    req(token, { bucket, path, contentType, size: body.length }),
    env,
  );
}

const mongo = new MongoClient(uri);
await mongo.connect();
const files = mongo.db('e2e_storage').collection('_onebase_files');

await t('a presigned upload reaches the object store', async () => {
  const res = await upload(alice, 'avatars', 'me.png', Buffer.from([1, 2, 3]));
  assert.equal(res.status, 200);
  // Private buckets namespace the key by user id.
  assert.ok(objects.has('/files/avatars/alice/me.png'), [...objects.keys()].join(','));
  assert.equal(objects.get('/files/avatars/alice/me.png')!.contentType, 'image/png');
  assert.equal(await files.countDocuments({ _id: 'avatars/alice/me.png' as never }), 1);
});

await t('two users asking for the same path get different objects', async () => {
  await upload(bob, 'avatars', 'me.png', Buffer.from([9]));
  assert.ok(objects.has('/files/avatars/bob/me.png'));
  // Alice's file is untouched.
  assert.deepEqual([...objects.get('/files/avatars/alice/me.png')!.body], [1, 2, 3]);
});

await t('a download URL reads back exactly what was written', async () => {
  const res = await handleStorageDownloadUrl(
    req(alice, { bucket: 'avatars', path: 'me.png' }), env);
  const { url } = (await res.json()) as any;
  const got = await fetch(url);
  assert.equal(got.status, 200);
  assert.deepEqual([...new Uint8Array(await got.arrayBuffer())], [1, 2, 3]);
});

await t('one user cannot reach another user private file', async () => {
  // Bob asks for the same path; the key he gets is his own, not alice's.
  const res = await handleStorageDownloadUrl(
    req(bob, { bucket: 'avatars', path: 'me.png' }), env);
  const { url, key: objectKey } = (await res.json()) as any;
  assert.equal(objectKey, 'avatars/bob/me.png');
  const got = await fetch(url);
  assert.deepEqual([...new Uint8Array(await got.arrayBuffer())], [9]);
});

await t('path traversal is refused', async () => {
  for (const path of ['../bob/me.png', 'a/../../x', '/etc/passwd', 'a\\b', '', 'a//b']) {
    const res = await handleStorageUploadUrl(
      req(alice, { bucket: 'avatars', path, contentType: 'image/png', size: 1 }), env);
    assert.equal(res.status, 400, `should refuse "${path}"`);
  }
});

await t('an undeclared bucket is refused', async () => {
  const res = await handleStorageUploadUrl(
    req(alice, { bucket: 'secrets', path: 'x.png', contentType: 'image/png', size: 1 }), env);
  assert.equal(res.status, 400);
});

await t('content type rules are enforced server-side', async () => {
  const res = await handleStorageUploadUrl(
    req(alice, { bucket: 'avatars', path: 'x.pdf', contentType: 'application/pdf', size: 1 }), env);
  assert.equal(res.status, 400);
  assert.match(JSON.stringify(await res.json()), /does not accept/);
});

await t('the size limit is enforced server-side and pinned in the signature', async () => {
  const tooBig = await handleStorageUploadUrl(
    req(alice, { bucket: 'avatars', path: 'big.png', contentType: 'image/png', size: 3 * 1024 * 1024 }), env);
  assert.equal(tooBig.status, 400);

  // Signing content-length means the store sees the approved size.
  const ok = await handleStorageUploadUrl(
    req(alice, { bucket: 'avatars', path: 'ok.png', contentType: 'image/png', size: 4 }), env);
  const { headers } = (await ok.json()) as any;
  assert.equal(headers['content-length'], '4');
  assert.equal(headers['content-type'], 'image/png');
});

await t('size must be supplied', async () => {
  const res = await handleStorageUploadUrl(
    req(alice, { bucket: 'avatars', path: 'x.png', contentType: 'image/png' }), env);
  assert.equal(res.status, 400);
});

await t('listing a private bucket shows only your files', async () => {
  const mine = await handleStorageList(req(alice, { bucket: 'avatars' }), env);
  const paths = ((await mine.json()) as any).files.map((f: any) => f.path);
  assert.ok(paths.includes('me.png'));
  const bobs = await handleStorageList(req(bob, { bucket: 'avatars' }), env);
  const bobPaths = ((await bobs.json()) as any).files.map((f: any) => f.path);
  assert.deepEqual(bobPaths, ['me.png'], 'bob sees his own, not alice count');
  assert.equal(paths.length, 1);
});

await t('a shared bucket is readable by everyone, deletable by the uploader', async () => {
  await upload(alice, 'brochures', 'plan.pdf', Buffer.from([7]), 'application/pdf');
  assert.ok(objects.has('/files/brochures/plan.pdf'), 'shared keys are not namespaced');

  const listed = await handleStorageList(req(bob, { bucket: 'brochures' }), env);
  assert.deepEqual(((await listed.json()) as any).files.map((f: any) => f.path), ['plan.pdf']);

  const bobDelete = await handleStorageDelete(
    req(bob, { bucket: 'brochures', path: 'plan.pdf' }), env);
  assert.equal(bobDelete.status, 403, 'only the uploader may delete');
  assert.ok(objects.has('/files/brochures/plan.pdf'));

  const aliceDelete = await handleStorageDelete(
    req(alice, { bucket: 'brochures', path: 'plan.pdf' }), env);
  assert.equal(aliceDelete.status, 200);
  assert.ok(!objects.has('/files/brochures/plan.pdf'));
});

await t('delete removes the object and its metadata', async () => {
  const res = await handleStorageDelete(req(bob, { bucket: 'avatars', path: 'me.png' }), env);
  assert.equal(res.status, 200);
  assert.ok(!objects.has('/files/avatars/bob/me.png'));
  assert.equal(await files.countDocuments({ _id: 'avatars/bob/me.png' as never }), 0);
  // Alice's copy survives.
  assert.ok(objects.has('/files/avatars/alice/me.png'));
});

await t('deleting something that is gone still succeeds', async () => {
  const res = await handleStorageDelete(req(alice, { bucket: 'avatars', path: 'never.png' }), env);
  assert.equal(res.status, 200);
});

await t('every storage route needs a token', async () => {
  for (const handler of [
    handleStorageUploadUrl, handleStorageDownloadUrl,
    handleStorageDelete, handleStorageList, handleStorageComplete,
  ]) {
    const res = await handler(
      new Request('http://x/storage', { method: 'POST', body: '{}' }), env);
    assert.equal(res.status, 401);
  }
});

await t('storage reports 501 until it is configured', async () => {
  const res = await handleStorageUploadUrl(
    req(alice, { bucket: 'avatars', path: 'x.png', contentType: 'image/png', size: 1 }),
    envNoStorage);
  assert.equal(res.status, 501);
  assert.match(JSON.stringify(await res.json()), /S3_BUCKET/);
});

await t('unsigned requests are rejected by the store', async () => {
  const direct = await fetch(`${s3Origin}/files/avatars/alice/me.png`);
  assert.equal(direct.status, 403, 'a URL without a signature must not work');
});

console.log(`\n${pass} storage end-to-end checks passed`);
await mongo.close();
await replset.stop();
s3.close();
process.exit(process.exitCode ?? 0);

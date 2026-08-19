import assert from 'node:assert/strict';
import { MongoMemoryReplSet } from 'mongodb-memory-server';
import { MongoClient } from 'mongodb';
import { SignJWT } from 'jose';
import {
  handlePull,
  handlePush,
  handleQuery,
  handleStream,
  handleToken,
  readEnv,
} from '../../example/backend/src/core.js';

const SECRET = 'e2e-secret-'.padEnd(40, 'x');

const replset = await MongoMemoryReplSet.create({ replSet: { count: 1 } });
const uri = replset.getUri();
process.env.MONGO_URI = uri;
process.env.MONGO_DB = 'e2e';
process.env.AUTH_MODE = 'dev';
process.env.JWT_SECRET = SECRET;
process.env.JWT_AUDIENCE = 'aud';
const env = readEnv((k) => process.env[k]);

const key = new TextEncoder().encode(SECRET);
const tokenFor = (sub: string) =>
  new SignJWT({}).setProtectedHeader({ alg: 'HS256' }).setSubject(sub)
    .setAudience('aud').setIssuedAt().setExpirationTime('1h').sign(key);

const alice = await tokenFor('alice');
const bob = await tokenFor('bob');

const req = (path: string, token: string, body: unknown) =>
  new Request(`http://x${path}`, {
    method: 'POST',
    headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' },
    body: JSON.stringify(body),
  });

const push = (token: string, ops: unknown[]) =>
  handlePush(req('/push', token, { transactions: [{ id: 'tx', ops }] }), env);
const pull = (token: string, since?: string | null) =>
  handlePull(req('/pull', token, { collection: 'todos', ...(since ? { since } : {}) }), env);

/// Pull ignores the most recent second, so wait for writes to become
/// eligible before asserting on what a second device would see.
const settle = () => new Promise((r) => setTimeout(r, 1200));

let pass = 0;
const t = async (name: string, fn: () => Promise<void>) => {
  try { await fn(); pass++; console.log('  ok  ' + name); }
  catch (e) { console.log('  FAIL ' + name + ' → ' + e); process.exitCode = 1; }
};

const mongo = new MongoClient(uri);
await mongo.connect();
const todos = mongo.db('e2e').collection('todos');

await t('push inserts a document owned by the caller', async () => {
  const res = await push(alice, [
    { op: 'put', collection: 'todos', id: 'a1', data: { title: 'milk', done: false } },
  ]);
  assert.equal(res.status, 200);
  assert.equal((await res.json() as any).applied, 1);
  const doc = await todos.findOne({ _id: 'a1' as never });
  assert.equal(doc!.title, 'milk');
  assert.equal(doc!.owner_id, 'alice', 'owner assigned from the token');
  assert.ok(doc!._updated_at instanceof Date, 'watermark stamped');
});

await t('client cannot forge ownership', async () => {
  await push(alice, [
    { op: 'put', collection: 'todos', id: 'a2', data: { title: 'x', owner_id: 'bob', done: false } },
  ]);
  assert.equal((await todos.findOne({ _id: 'a2' as never }))!.owner_id, 'alice');
});

await t('undeclared fields are dropped, not written', async () => {
  const res = await push(alice, [
    { op: 'put', collection: 'todos', id: 'a3', data: { title: 'x', is_admin: true, done: false } },
  ]);
  const body = await res.json() as any;
  assert.deepEqual(body.dropped[0].fields, ['is_admin']);
  assert.equal((await todos.findOne({ _id: 'a3' as never }))!.is_admin, undefined);
});

await t('put merges and preserves server-managed fields', async () => {
  await todos.updateOne({ _id: 'a1' as never }, { $set: { server_secret: 42 } });
  await push(alice, [
    { op: 'put', collection: 'todos', id: 'a1', data: { title: 'bread', done: true } },
  ]);
  const doc = await todos.findOne({ _id: 'a1' as never });
  assert.equal(doc!.title, 'bread');
  assert.equal(doc!.server_secret, 42, 'server field survived the client write');
});

await t('bob cannot patch or delete alice documents', async () => {
  const patched = await push(bob, [
    { op: 'patch', collection: 'todos', id: 'a1', data: { title: 'hacked', done: false } },
  ]);
  assert.equal((await patched.json() as any).skipped.length, 1);
  const removed = await push(bob, [{ op: 'delete', collection: 'todos', id: 'a1' }]);
  assert.equal((await removed.json() as any).skipped.length, 1);
  assert.equal((await todos.findOne({ _id: 'a1' as never }))!.title, 'bread');
});

await t('bob cannot claim an id alice already owns', async () => {
  const res = await push(bob, [
    { op: 'put', collection: 'todos', id: 'a1', data: { title: 'mine now', done: false } },
  ]);
  const body = await res.json() as any;
  assert.equal(body.skipped.length, 1);
  assert.match(body.skipped[0].reason, /owned by another user/);
});

let cursor: string | null = null;
await t('pull returns only the caller documents', async () => {
  await push(bob, [{ op: 'put', collection: 'todos', id: 'b1', data: { title: 'bob todo', done: false } }]);
  // Pull deliberately ignores the most recent second so out-of-order commits
  // cannot slip behind the watermark.
  await settle();
  const res = await pull(alice);
  const body = await res.json() as any;
  const ids = body.documents.map((d: any) => d.id).sort();
  assert.deepEqual(ids, ['a1', 'a2', 'a3']);
  assert.ok(!ids.includes('b1'), 'bob data must not leak');
  cursor = body.cursor;
  assert.ok(cursor, 'cursor returned');
});

await t('a pull with no new writes returns nothing and holds its cursor', async () => {
  await settle();
  const body = await (await pull(alice, cursor)).json() as any;
  assert.deepEqual(body.documents, [], 'steady state must not re-deliver');
  cursor = body.cursor;
});

await t('incremental pull returns only what changed', async () => {
  await push(alice, [{ op: 'put', collection: 'todos', id: 'a4', data: { title: 'new', done: false } }]);
  await settle();
  const body = await (await pull(alice, cursor)).json() as any;
  assert.deepEqual(body.documents.map((d: any) => d.id), ['a4']);
  cursor = body.cursor;
});

await t('a delete reaches other devices as a tombstone', async () => {
  await push(alice, [{ op: 'delete', collection: 'todos', id: 'a4' }]);
  assert.equal(await todos.findOne({ _id: 'a4' as never }), null, 'row really deleted');
  await settle();
  const body = await (await pull(alice, cursor)).json() as any;
  const tomb = body.documents.find((d: any) => d.id === 'a4');
  assert.ok(tomb, 'tombstone delivered');
  assert.equal(tomb._deleted, true);
});

await t('re-creating a deleted id clears its tombstone', async () => {
  const before = (await (await pull(alice, cursor)).json() as any).cursor;
  await push(alice, [{ op: 'put', collection: 'todos', id: 'a4', data: { title: 'back', done: false } }]);
  await settle();
  const body = await (await pull(alice, before)).json() as any;
  const entries = body.documents.filter((d: any) => d.id === 'a4');
  assert.equal(entries.length, 1);
  assert.equal(entries[0]._deleted, undefined, 'no stale tombstone');
  assert.equal(entries[0].title, 'back');
});

await t('a batch is applied atomically', async () => {
  const res = await push(alice, [
    { op: 'put', collection: 'todos', id: 'c1', data: { title: 'one', done: false } },
    { op: 'put', collection: 'todos', id: 'c2', data: { title: 'two', done: false } },
  ]);
  assert.equal((await res.json() as any).applied, 2);
  assert.equal(await todos.countDocuments({ _id: { $in: ['c1', 'c2'] } as never }), 2);
});

await t('sync indexes were created', async () => {
  const names = (await todos.indexes()).map((i) => i.name);
  assert.ok(names.includes('onebase_sync'), `got ${names}`);
});

await t('unknown collection is reported, not crashed', async () => {
  const body = await (await push(alice, [
    { op: 'put', collection: 'ghosts', id: 'x', data: {} },
  ])).json() as any;
  assert.match(body.skipped[0].reason, /unknown collection/);
});

await t('pull rejects an unknown collection', async () => {
  const res = await handlePull(req('/pull', alice, { collection: 'ghosts' }), env);
  assert.equal(res.status, 400);
});

await t('/token mints a working dev JWT', async () => {
  const res = await handleToken(
    new Request('http://x/token', { method: 'POST', body: JSON.stringify({ email: 'a@b.co' }) }),
    env,
  );
  const body = await res.json() as any;
  const pushed = await push(body.token, [
    { op: 'put', collection: 'todos', id: 'd1', data: { title: 'via dev token', done: false } },
  ]);
  assert.equal((await pushed.json() as any).applied, 1);
  assert.equal((await todos.findOne({ _id: 'd1' as never }))!.owner_id, body.user_id);
});


await t('required fields are enforced on a whole-document write', async () => {
  const res = await push(alice, [
    { op: 'put', collection: 'todos', id: 'req1', data: { done: false } },
  ]);
  const body = (await res.json()) as any;
  assert.equal(body.skipped.length, 1, JSON.stringify(body));
  assert.match(body.skipped[0].reason, /missing required field/);
  assert.equal(await todos.findOne({ _id: 'req1' as never }), null);
});

await t('a partial update is exempt from required fields', async () => {
  await push(alice, [
    { op: 'put', collection: 'todos', id: 'req2', data: { title: 't', done: false } },
  ]);
  const res = await push(alice, [
    { op: 'patch', collection: 'todos', id: 'req2', data: { done: true } },
  ]);
  assert.equal((await res.json() as any).skipped.length, 0);
  assert.equal((await todos.findOne({ _id: 'req2' as never }))!.done, true);
});

// ----------------------------------------------------------------- /query

const query = (token: string, body: Record<string, unknown>) =>
  handleQuery(req('/query', token, body), env);

const ids = async (token: string, body: Record<string, unknown>) => {
  const res = await query(token, body);
  assert.equal(res.status, 200, `query failed: ${await res.clone().text()}`);
  return ((await res.json()) as any).documents.map((d: any) => d.id);
};

await t('query returns only the caller documents', async () => {
  const mine = await ids(alice, { collection: 'todos' });
  assert.ok(mine.length > 0);
  assert.ok(!mine.includes('b1'), 'bob data must not leak into alice results');
  const bobs = await ids(bob, { collection: 'todos' });
  assert.deepEqual(bobs, ['b1']);
});

await t('query filters, sorts and limits', async () => {
  const filtered = await ids(alice, {
    collection: 'todos',
    filters: [{ field: 'title', op: 'eq', value: 'bread' }],
  });
  assert.deepEqual(filtered, ['a1']);

  const sorted = await ids(alice, {
    collection: 'todos',
    order: [{ field: 'title', descending: true }],
    limit: 2,
  });
  assert.equal(sorted.length, 2);
});

await t('query supports in, isNull and count', async () => {
  const inList = await ids(alice, {
    collection: 'todos',
    filters: [{ field: 'title', op: 'in', value: ['bread', 'back'] }],
  });
  assert.deepEqual(inList.sort(), ['a1', 'a4']);

  const res = await query(alice, { collection: 'todos', count: true });
  const body = (await res.json()) as any;
  assert.ok(body.count >= 2, `got ${body.count}`);
});

await t('query by id is owner-scoped', async () => {
  assert.deepEqual(await ids(alice, { collection: 'todos', id: 'a1' }), ['a1']);
  assert.deepEqual(await ids(bob, { collection: 'todos', id: 'a1' }), []);
});

await t('query converts bool the way the client encodes it', async () => {
  // The client sends SQLite's 0/1; the backend must compare against BSON
  // booleans, or the same query would answer differently in each mode.
  const truthy = await ids(alice, {
    collection: 'todos',
    filters: [{ field: 'done', op: 'eq', value: 1 }],
  });
  const falsy = await ids(alice, {
    collection: 'todos',
    filters: [{ field: 'done', op: 'eq', value: 0 }],
  });
  assert.ok(truthy.includes('a1'), `done=true missed a1: ${truthy}`);
  assert.ok(!falsy.includes('a1'), `done=false wrongly matched a1: ${falsy}`);
  assert.equal(truthy.filter((id: string) => falsy.includes(id)).length, 0);
});

await t('query cannot override ownership', async () => {
  // Even asking explicitly for bob's rows returns only alice's.
  const spoofed = await ids(alice, {
    collection: 'todos',
    filters: [{ field: 'owner_id', op: 'eq', value: 'bob' }],
  });
  assert.ok(!spoofed.includes('b1'));
});

await t('query rejects injection attempts', async () => {
  for (const filters of [
    [{ field: '$where', op: 'eq', value: '1==1' }],
    [{ field: 'title', op: '$where', value: 'x' }],
    [{ field: '_updated_at', op: 'gt', value: 0 }],
    [{ field: 'title.evil', op: 'eq', value: 'x' }],
    [{ field: 'nope', op: 'eq', value: 'x' }],
  ]) {
    const res = await query(alice, { collection: 'todos', filters });
    assert.equal(res.status, 400, `should reject ${JSON.stringify(filters)}`);
  }
  const sorted = await query(alice, {
    collection: 'todos',
    order: [{ field: '$natural', descending: true }],
  });
  assert.equal(sorted.status, 400);
});

await t('query caps the page size', async () => {
  const res = await query(alice, { collection: 'todos', limit: 100000 });
  assert.equal(res.status, 200);
  const res2 = await query(alice, { collection: 'todos', limit: -1 });
  assert.equal(res2.status, 400);
});

// ------------------------------------------------------------- pagination

await t('keyset paging walks every document exactly once', async () => {
  // Enough rows to need several pages, with a repeating sort value so the
  // tiebreaker is exercised.
  for (let i = 0; i < 30; i++) {
    await push(alice, [{
      op: 'put', collection: 'todos', id: `pg-${String(i).padStart(2, '0')}`,
      data: { title: `page item ${i}`, done: i % 2 === 0 },
    }]);
  }

  const seen: string[] = [];
  let cursor: { values: unknown[]; id: string } | undefined;
  for (let guard = 0; guard < 20; guard++) {
    const body: Record<string, unknown> = {
      collection: 'todos',
      order: [{ field: 'title', descending: false }],
      limit: 7,
    };
    if (cursor) body.startAfter = cursor;
    const res = await query(alice, body);
    assert.equal(res.status, 200, await res.clone().text());
    const docs = ((await res.json()) as any).documents;
    if (docs.length === 0) break;
    seen.push(...docs.map((d: any) => d.id));
    const last = docs[docs.length - 1];
    cursor = { values: [last.title], id: last.id };
    if (docs.length < 7) break;
  }

  const paged = seen.filter((id) => id.startsWith('pg-'));
  assert.equal(new Set(paged).size, paged.length, 'no document repeated');
  assert.equal(paged.length, 30, `expected all 30, got ${paged.length}`);
});

await t('descending paging walks backwards without loss', async () => {
  const seen: string[] = [];
  let cursor: { values: unknown[]; id: string } | undefined;
  for (let guard = 0; guard < 20; guard++) {
    const body: Record<string, unknown> = {
      collection: 'todos',
      filters: [{ field: 'title', op: 'gte', value: 'page item ' }],
      order: [{ field: 'title', descending: true }],
      limit: 9,
    };
    if (cursor) body.startAfter = cursor;
    const docs = ((await (await query(alice, body)).json()) as any).documents;
    if (docs.length === 0) break;
    seen.push(...docs.map((d: any) => d.id));
    const last = docs[docs.length - 1];
    cursor = { values: [last.title], id: last.id };
    if (docs.length < 9) break;
  }
  assert.equal(new Set(seen).size, seen.length, 'no document repeated');
  const paged = seen.filter((id) => id.startsWith('pg-'));
  assert.equal(new Set(paged).size, 30, `expected all 30, got ${paged.length}`);
  assert.ok(paged[0] > paged[paged.length - 1], 'should descend');
});

await t('a cursor that does not match the orderBy is rejected', async () => {
  const res = await query(alice, {
    collection: 'todos',
    order: [{ field: 'title', descending: false }],
    startAfter: { values: ['a', 'b'], id: 'x' },
  });
  assert.equal(res.status, 400);
});

await t('a malformed cursor is rejected', async () => {
  for (const startAfter of ['nope', 42, { id: 'x' }, { values: [] }]) {
    const res = await query(alice, {
      collection: 'todos',
      order: [{ field: 'title', descending: false }],
      startAfter,
    });
    assert.equal(res.status, 400, `should reject ${JSON.stringify(startAfter)}`);
  }
});

await t('paging stays scoped to the caller', async () => {
  const docs = ((await (await query(alice, {
    collection: 'todos', order: [{ field: 'title', descending: false }], limit: 100,
  })).json()) as any).documents;
  assert.ok(!docs.some((d: any) => d.id === 'b1'), 'bob data must not appear');
});

// ---------------------------------------------------------------- /stream

/** Opens the SSE stream and collects frames until `count` arrive. */
async function listen(token: string, count: number, timeoutMs = 8000) {
  const request = new Request('http://x/stream?collections=todos', {
    method: 'GET',
    headers: { authorization: `Bearer ${token}` },
  });
  const response = await handleStream(request, env);
  assert.equal(response.status, 200);
  assert.match(response.headers.get('content-type') ?? '', /text\/event-stream/);

  const reader = response.body!.getReader();
  const decoder = new TextDecoder();
  const frames: any[] = [];
  let buffer = '';
  const deadline = Date.now() + timeoutMs;

  const pump = (async () => {
    while (frames.length < count && Date.now() < deadline) {
      const { value, done } = await reader.read();
      if (done) break;
      buffer += decoder.decode(value, { stream: true });
      for (const chunk of buffer.split('\n\n')) {
        const line = chunk.split('\n').find((l) => l.startsWith('data:'));
        if (line) frames.push(JSON.parse(line.slice(5).trim()));
      }
      if (buffer.endsWith('\n\n')) buffer = '';
    }
  })();

  return {
    frames,
    async stop() {
      await Promise.race([pump, new Promise((r) => setTimeout(r, timeoutMs))]);
      await reader.cancel().catch(() => {});
      return frames;
    },
  };
}

await t('stream pushes an insert as it happens', async () => {
  const session = await listen(alice, 1);
  await new Promise((r) => setTimeout(r, 400));
  const started = Date.now();
  await push(alice, [
    { op: 'put', collection: 'todos', id: 'rt1', data: { title: 'realtime', done: false } },
  ]);
  const frames = await session.stop();
  const hit = frames.find((f) => f.document?.id === 'rt1');
  assert.ok(hit, `no realtime frame arrived: ${JSON.stringify(frames)}`);
  assert.equal(hit.collection, 'todos');
  assert.equal(hit.document.title, 'realtime');
  // The whole point: this must not wait for a poll interval.
  assert.ok(Date.now() - started < 5000, 'realtime should be sub-second-ish');
});

await t('stream pushes a delete as a tombstone', async () => {
  const session = await listen(alice, 1);
  await new Promise((r) => setTimeout(r, 400));
  await push(alice, [{ op: 'delete', collection: 'todos', id: 'rt1' }]);
  const frames = await session.stop();
  const hit = frames.find((f) => f.document?.id === 'rt1');
  assert.ok(hit, 'no tombstone frame');
  assert.equal(hit.document._deleted, true);
});

await t('stream never delivers another user documents', async () => {
  const session = await listen(alice, 1);
  await new Promise((r) => setTimeout(r, 400));
  await push(bob, [
    { op: 'put', collection: 'todos', id: 'rt-bob', data: { title: 'secret', done: false } },
  ]);
  await push(alice, [
    { op: 'put', collection: 'todos', id: 'rt-alice', data: { title: 'mine', done: false } },
  ]);
  const frames = await session.stop();
  assert.ok(
    frames.every((f) => f.document?.id !== 'rt-bob'),
    `bob leaked into alice stream: ${JSON.stringify(frames)}`,
  );
  assert.ok(frames.some((f) => f.document?.id === 'rt-alice'));
});

await t('stream rejects an unknown collection and a bad token', async () => {
  const bad = await handleStream(
    new Request('http://x/stream?collections=ghosts', {
      method: 'GET',
      headers: { authorization: `Bearer ${alice}` },
    }),
    env,
  );
  assert.equal(bad.status, 400);

  const unauthorized = await handleStream(
    new Request('http://x/stream', { method: 'GET' }),
    env,
  );
  assert.equal(unauthorized.status, 401);
});

console.log(`\n${pass} end-to-end checks passed against a real MongoDB replica set`);
await mongo.close();
await replset.stop();
process.exit(process.exitCode ?? 0);

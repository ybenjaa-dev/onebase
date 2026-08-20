// Group permissions against a real MongoDB replica set: two families, four
// people, and every way one of them might reach data that is not theirs.
import assert from 'node:assert/strict';
import { MongoMemoryReplSet } from 'mongodb-memory-server';
import { MongoClient } from 'mongodb';
import { SignJWT } from 'jose';
import {
  handlePull,
  handlePush,
  handleQuery,
  readEnv,
} from './fixture/backend/src/core.js';

const SECRET = 'group-e2e-'.padEnd(40, 'x');
const replset = await MongoMemoryReplSet.create({ replSet: { count: 1 } });
const uri = replset.getUri();

const vars: Record<string, string> = {
  MONGO_URI: uri,
  MONGO_DB: 'e2e_groups',
  AUTH_MODE: 'dev',
  JWT_SECRET: SECRET,
  JWT_AUDIENCE: 'aud',
};
const env = readEnv((k) => vars[k]);

const key = new TextEncoder().encode(SECRET);
const tokenFor = (sub: string) =>
  new SignJWT({}).setProtectedHeader({ alg: 'HS256' }).setSubject(sub)
    .setAudience('aud').setIssuedAt().setExpirationTime('1h').sign(key);

// The Smiths: alice is an admin, bob an ordinary member.
// The Joneses: carol. dan belongs to no family at all.
const alice = await tokenFor('alice');
const bob = await tokenFor('bob');
const carol = await tokenFor('carol');
const dan = await tokenFor('dan');

const mongo = new MongoClient(uri);
await mongo.connect();
const db = mongo.db('e2e_groups');

await db.collection('family_members').insertMany([
  { _id: 'm1' as never, family_id: 'smith', user_id: 'alice', role: 'admin' },
  { _id: 'm2' as never, family_id: 'smith', user_id: 'bob', role: 'member' },
  { _id: 'm3' as never, family_id: 'jones', user_id: 'carol', role: 'admin' },
]);

const req = (token: string, body: unknown) =>
  new Request('http://x/r', {
    method: 'POST',
    headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' },
    body: JSON.stringify(body),
  });

const push = (token: string, ops: unknown[]) =>
  handlePush(req(token, { transactions: [{ id: 'tx', ops }] }), env);
const query = (token: string, body: Record<string, unknown>) =>
  handleQuery(req(token, body), env);

const skippedOf = async (res: Response) => ((await res.json()) as any).skipped;
const idsOf = async (token: string, collection: string) => {
  const res = await query(token, { collection, limit: 100 });
  assert.equal(res.status, 200, await res.clone().text());
  return ((await res.json()) as any).documents.map((d: any) => d.id).sort();
};

let pass = 0;
const t = async (name: string, fn: () => Promise<void>) => {
  try { await fn(); pass++; console.log('  ok  ' + name); }
  catch (e) { console.log('  FAIL ' + name + ' → ' + e); process.exitCode = 1; }
};

// ------------------------------------------------------- write: member

await t('a member can write to their family', async () => {
  const res = await push(alice, [
    { op: 'put', collection: 'chores', id: 'c1',
      data: { title: 'dishes', family_id: 'smith' } },
  ]);
  assert.equal((await res.json() as any).applied, 1);
  assert.equal((await db.collection('chores').findOne({ _id: 'c1' as never }))!.title, 'dishes');
});

await t('another member of the same family can write too', async () => {
  const res = await push(bob, [
    { op: 'put', collection: 'chores', id: 'c2',
      data: { title: 'bins', family_id: 'smith' } },
  ]);
  assert.equal((await res.json() as any).applied, 1);
});

await t('an outsider cannot write into a family they are not in', async () => {
  const res = await push(carol, [
    { op: 'put', collection: 'chores', id: 'c3',
      data: { title: 'intruder', family_id: 'smith' } },
  ]);
  const skipped = await skippedOf(res);
  assert.equal(skipped.length, 1);
  assert.match(skipped[0].reason, /not a member/);
  assert.equal(await db.collection('chores').findOne({ _id: 'c3' as never }), null);
});

await t('someone in no group at all is refused', async () => {
  const res = await push(dan, [
    { op: 'put', collection: 'chores', id: 'c4',
      data: { title: 'nobody', family_id: 'smith' } },
  ]);
  assert.equal((await skippedOf(res)).length, 1);
});

await t('an outsider cannot update or delete a family document', async () => {
  const patched = await push(carol, [
    { op: 'patch', collection: 'chores', id: 'c1', data: { title: 'hacked' } },
  ]);
  assert.equal((await skippedOf(patched)).length, 1);

  const removed = await push(carol, [{ op: 'delete', collection: 'chores', id: 'c1' }]);
  assert.equal((await skippedOf(removed)).length, 1);
  assert.equal((await db.collection('chores').findOne({ _id: 'c1' as never }))!.title, 'dishes');
});

await t('a document cannot be moved between groups', async () => {
  // Reassigning the group would hand the document to people who were never
  // allowed to see it.
  await push(alice, [
    { op: 'patch', collection: 'chores', id: 'c1', data: { family_id: 'jones' } },
  ]);
  assert.equal(
    (await db.collection('chores').findOne({ _id: 'c1' as never }))!.family_id,
    'smith',
  );
});

// -------------------------------------------------------- write: admin

await t('an admin can write an admin-only collection', async () => {
  const res = await push(alice, [
    { op: 'put', collection: 'family_settings', id: 's1',
      data: { family_id: 'smith', quiet_hours: '22:00' } },
  ]);
  assert.equal((await res.json() as any).applied, 1);
});

await t('an ordinary member cannot', async () => {
  const res = await push(bob, [
    { op: 'put', collection: 'family_settings', id: 's2',
      data: { family_id: 'smith', quiet_hours: '06:00' } },
  ]);
  const skipped = await skippedOf(res);
  assert.equal(skipped.length, 1);
  assert.match(skipped[0].reason, /admin/);
});

await t('a member can still read admin-only settings', async () => {
  assert.deepEqual(await idsOf(bob, 'family_settings'), ['s1']);
});

// -------------------------------------------------------- write: owner

await t('a diary is readable by the family but writable only by its author', async () => {
  const mine = await push(alice, [
    { op: 'put', collection: 'diaries', id: 'd1',
      data: { family_id: 'smith', owner_id: 'alice', entry: 'private' } },
  ]);
  assert.equal((await mine.json() as any).applied, 1);

  // bob is in the family, so he can see it...
  assert.ok((await idsOf(bob, 'diaries')).includes('d1'));

  // ...but not change it.
  const theirs = await push(bob, [
    { op: 'patch', collection: 'diaries', id: 'd1', data: { entry: 'edited' } },
  ]);
  assert.equal((await skippedOf(theirs)).length, 1);
  assert.equal(
    (await db.collection('diaries').findOne({ _id: 'd1' as never }))!.entry,
    'private',
  );
});

// ------------------------------------------------------------- reading

await t('query returns only your family documents', async () => {
  await push(carol, [
    { op: 'put', collection: 'chores', id: 'j1',
      data: { title: 'jones chore', family_id: 'jones' } },
  ]);
  assert.deepEqual(await idsOf(alice, 'chores'), ['c1', 'c2']);
  assert.deepEqual(await idsOf(carol, 'chores'), ['j1']);
});

await t('belonging to no group returns nothing, not everything', async () => {
  // The failure mode worth guarding: an empty group list becoming an
  // unfiltered query.
  assert.deepEqual(await idsOf(dan, 'chores'), []);
  const counted = await query(dan, { collection: 'chores', count: true });
  assert.equal(((await counted.json()) as any).count, 0);
});

await t('pull is scoped to your groups', async () => {
  await new Promise((r) => setTimeout(r, 1200));
  const res = await handlePull(req(alice, { collection: 'chores' }), env);
  const ids = ((await res.json()) as any).documents.map((d: any) => d.id).sort();
  assert.deepEqual(ids, ['c1', 'c2']);
  assert.ok(!ids.includes('j1'), 'another family must not sync down');
});

await t('pull returns nothing for someone in no group', async () => {
  const res = await handlePull(req(dan, { collection: 'chores' }), env);
  assert.equal(res.status, 200);
  assert.deepEqual(((await res.json()) as any).documents, []);
});

await t('a delete reaches the family as a group tombstone', async () => {
  await push(alice, [{ op: 'delete', collection: 'chores', id: 'c2' }]);
  await new Promise((r) => setTimeout(r, 1200));

  const res = await handlePull(req(bob, { collection: 'chores' }), env);
  const docs = ((await res.json()) as any).documents;
  const tomb = docs.find((d: any) => d.id === 'c2' && d._deleted);
  assert.ok(tomb, `bob should learn of the delete: ${JSON.stringify(docs)}`);

  // And it must not leak to another family.
  const outsider = await handlePull(req(carol, { collection: 'chores' }), env);
  const theirs = ((await outsider.json()) as any).documents;
  assert.ok(!theirs.some((d: any) => d.id === 'c2'));
});

await t('adding a membership grants access from then on', async () => {
  assert.deepEqual(await idsOf(dan, 'chores'), []);
  await db.collection('family_members').insertOne(
    { _id: 'm4' as never, family_id: 'smith', user_id: 'dan', role: 'member' },
  );
  assert.deepEqual(await idsOf(dan, 'chores'), ['c1']);
});

// -------------------------------------------------------- sync policy

await t('a windowed collection only syncs its recent slice', async () => {
  const now = Date.now();
  await db.collection('messages').insertMany([
    { _id: 'recent' as never, family_id: 'smith', body: 'hi',
      sent_at: new Date(now - 5 * 86400_000), _updated_at: new Date(now - 60_000) },
    { _id: 'ancient' as never, family_id: 'smith', body: 'old',
      sent_at: new Date(now - 365 * 86400_000), _updated_at: new Date(now - 60_000) },
  ]);

  const res = await handlePull(req(alice, { collection: 'messages' }), env);
  const ids = ((await res.json()) as any).documents.map((d: any) => d.id);
  assert.ok(ids.includes('recent'), `expected the recent one: ${ids}`);
  assert.ok(
    !ids.includes('ancient'),
    'a document outside the window must not be downloaded',
  );
});

await t('the window does not hide documents from a direct query', async () => {
  // Not synced is not the same as not readable: the old message is still
  // there when the app asks for it.
  const res = await query(alice, {
    collection: 'messages',
    filters: [{ field: 'body', op: 'eq', value: 'old' }],
  });
  const ids = ((await res.json()) as any).documents.map((d: any) => d.id);
  assert.deepEqual(ids, ['ancient']);
});

await t('a collection marked sync: none is never pulled', async () => {
  await db.collection('audit_log').insertOne(
    { _id: 'a1' as never, family_id: 'smith', message: 'logged',
      _updated_at: new Date(Date.now() - 60_000) },
  );

  const res = await handlePull(req(alice, { collection: 'audit_log' }), env);
  assert.equal(res.status, 200);
  assert.deepEqual(
    ((await res.json()) as any).documents,
    [],
    'it costs the device nothing',
  );
});

await t('but it is still queryable, and still group-scoped', async () => {
  assert.deepEqual(await idsOf(alice, 'audit_log'), ['a1']);
  assert.deepEqual(await idsOf(carol, 'audit_log'), []);
});

await t('write: none refuses client writes to the audit log', async () => {
  const res = await push(alice, [
    { op: 'put', collection: 'audit_log', id: 'a2',
      data: { family_id: 'smith', message: 'forged' } },
  ]);
  const skipped = await skippedOf(res);
  assert.equal(skipped.length, 1);
  assert.match(skipped[0].reason, /read-only/);
});

console.log(`\n${pass} group permission checks passed`);
await mongo.close();
await replset.stop();
process.exit(process.exitCode ?? 0);

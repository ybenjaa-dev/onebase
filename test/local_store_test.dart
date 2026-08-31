import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:onebase/src/schema/schema.dart';
import 'package:onebase/src/store/local_store.dart';
import 'package:sqlite_async/sqlite_async.dart';

void main() {
  final schema = OnebaseSchema([
    MongoCollectionSchema(
      'todos',
      fields: {
        'title': MongoFieldType.text,
        'done': MongoFieldType.bool,
        'owner_id': MongoFieldType.text,
      },
      ownerField: 'owner_id',
    ),
  ]);

  late Directory dir;
  late SqliteDatabase db;
  late LocalStore store;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('onebase_store');
    db = SqliteDatabase(path: '${dir.path}/test.db');
    await db.initialize();
    store = LocalStore(db, schema);
    await store.migrate();
  });

  tearDown(() async {
    await db.close();
    dir.deleteSync(recursive: true);
  });

  Future<List<Map<String, Object?>>> rows_() async => (await db.getAll(
    'SELECT * FROM "todos" ORDER BY id',
  )).map(Map<String, Object?>.of).toList();

  group('migrate', () {
    test('creates a table per collection with the declared columns', () async {
      final info = await db.getAll('PRAGMA table_info("todos")');
      final columns = {for (final row in info) row['name'] as String};
      expect(columns, containsAll(<String>['id', 'title', 'done', 'owner_id']));
      expect(columns, contains(updatedAtColumn));
    });

    test('is idempotent and adds columns for new schema fields', () async {
      await store.migrate();

      final widened = OnebaseSchema([
        MongoCollectionSchema(
          'todos',
          fields: {
            'title': MongoFieldType.text,
            'done': MongoFieldType.bool,
            'owner_id': MongoFieldType.text,
            'priority': MongoFieldType.int,
          },
          ownerField: 'owner_id',
        ),
      ]);
      await LocalStore(db, widened).migrate();

      final info = await db.getAll('PRAGMA table_info("todos")');
      expect({
        for (final row in info) row['name'] as String,
      }, contains('priority'));
    });
  });

  group('writes', () {
    test('insert stores the row and queues one op', () async {
      await store.insert('todos', 'a', {
        'title': 'milk',
        'done': 0,
      }, transactionId: 'tx-1');

      expect((await rows_()).single['title'], 'milk');
      final pending = await store.pendingOps();
      expect(pending.single.op, 'put');
      expect(pending.single.documentId, 'a');
      expect(pending.single.data, {'title': 'milk', 'done': 0});
      expect(await store.pendingCount(), 1);
    });

    test('update patches only the given fields', () async {
      await store.insert('todos', 'a', {
        'title': 'milk',
        'done': 0,
      }, transactionId: 'tx-1');
      await store.update('todos', 'a', {'done': 1}, transactionId: 'tx-2');

      final row = (await rows_()).single;
      expect(row['title'], 'milk');
      expect(row['done'], 1);
      expect((await store.pendingOps()).last.op, 'patch');
    });

    test('delete removes the row and queues a delete op', () async {
      await store.insert('todos', 'a', {
        'title': 'milk',
      }, transactionId: 'tx-1');
      await store.delete('todos', 'a', transactionId: 'tx-2');

      expect(await rows_(), isEmpty);
      final pending = await store.pendingOps();
      expect(pending.last.op, 'delete');
      expect(pending.last.data, isNull);
    });

    test('a write and its outbox entry land together', () async {
      // Both statements share one transaction, so a crash can never leave a
      // local row that will not be uploaded.
      await store.insert('todos', 'a', {'title': 'x'}, transactionId: 'tx-1');
      expect((await rows_()).length, await store.pendingCount());
    });
  });

  group('applyPull', () {
    test('upserts server documents and advances the cursor', () async {
      await store.applyPull('todos', [
        {'id': 'srv-1', 'title': 'from server', 'done': 1},
      ], '2026-01-01T00:00:00.000Z');

      expect((await rows_()).single['title'], 'from server');
      expect(await store.cursor('todos'), '2026-01-01T00:00:00.000Z');
    });

    test('removes documents flagged deleted', () async {
      await store.applyPull('todos', [
        {'id': 'srv-1', 'title': 'x'},
      ], 'c1');
      await store.applyPull('todos', [
        {'id': 'srv-1', '_deleted': true},
      ], 'c2');

      expect(await rows_(), isEmpty);
    });

    test('accepts _id as well as id', () async {
      await store.applyPull('todos', [
        {'_id': 'srv-1', 'title': 'x'},
      ], 'c1');
      expect((await rows_()).single['id'], 'srv-1');
    });

    test(
      'replays pending local writes on top of the server snapshot',
      () async {
        // The user edits a row while a pull is in flight: their change must
        // still be on screen after the server snapshot is applied.
        await store.applyPull('todos', [
          {'id': 'a', 'title': 'server title', 'done': 0},
        ], 'c1');
        await store.update('todos', 'a', {
          'title': 'my edit',
        }, transactionId: 'tx-1');

        await store.applyPull('todos', [
          {'id': 'a', 'title': 'server title', 'done': 1},
        ], 'c2');

        final row = (await rows_()).single;
        expect(row['title'], 'my edit', reason: 'local edit must survive');
        expect(row['done'], 1, reason: 'untouched server field must apply');
      },
    );

    test('a pending local delete is not resurrected by a pull', () async {
      await store.applyPull('todos', [
        {'id': 'a', 'title': 'x'},
      ], 'c1');
      await store.delete('todos', 'a', transactionId: 'tx-1');

      await store.applyPull('todos', [
        {'id': 'a', 'title': 'x'},
      ], 'c2');

      expect(await rows_(), isEmpty);
    });

    test('a scoped replay only reapplies the named document', () async {
      await store.applyPull('todos', [
        {'id': 'a', 'title': 'server a'},
        {'id': 'b', 'title': 'server b'},
      ], 'c1');

      // Two pending edits; a realtime event for 'a' must not have to walk
      // both, and must not resurrect the edit to 'b'.
      await store.update('todos', 'a', {
        'title': 'my edit a',
      }, transactionId: 'tx-a');
      await store.update('todos', 'b', {
        'title': 'my edit b',
      }, transactionId: 'tx-b');

      await store.applyPull(
        'todos',
        [
          {'id': 'a', 'title': 'server a2'},
          {'id': 'b', 'title': 'server b2'},
        ],
        null,
        replayOnly: {'a'},
      );

      final rows = await rows_();
      expect(rows.firstWhere((r) => r['id'] == 'a')['title'], 'my edit a');
      expect(
        rows.firstWhere((r) => r['id'] == 'b')['title'],
        'server b2',
        reason: 'outside the scope, the server value stands',
      );
    });

    test('an empty replay scope skips the queue entirely', () async {
      await store.insert('todos', 'a', {
        'title': 'mine',
      }, transactionId: 'tx-1');
      // Nothing to reapply, so the pull must not undo the local row either.
      await store.applyPull('todos', const [], null, replayOnly: const {});
      expect((await rows_()).single['title'], 'mine');
    });

    test('does nothing when there is nothing to apply', () async {
      await store.applyPull('todos', const [], null);
      expect(await store.cursor('todos'), isNull);
    });
  });

  group('outbox lifecycle', () {
    test('clearOps removes confirmed writes only', () async {
      await store.insert('todos', 'a', {'title': 'a'}, transactionId: 'tx-1');
      await store.insert('todos', 'b', {'title': 'b'}, transactionId: 'tx-2');

      final pending = await store.pendingOps();
      await store.clearOps([pending.first.seq]);

      final left = await store.pendingOps();
      expect(left.single.documentId, 'b');
    });

    test('ops come back in the order they were made', () async {
      await store.insert('todos', 'a', {'title': 'a'}, transactionId: 'tx-1');
      await store.update('todos', 'a', {'done': 1}, transactionId: 'tx-2');
      await store.delete('todos', 'a', transactionId: 'tx-3');

      expect(
        [for (final op in await store.pendingOps()) op.op],
        ['put', 'patch', 'delete'],
      );
    });
  });

  group('clear', () {
    test('wipes rows, queue and cursors', () async {
      await store.insert('todos', 'a', {'title': 'x'}, transactionId: 'tx-1');
      await store.setCursor('todos', 'c1');

      await store.clear();

      expect(await rows_(), isEmpty);
      expect(await store.pendingCount(), 0);
      expect(await store.cursor('todos'), isNull);
    });
  });

  group('exportAll / importAll', () {
    test('export includes synced rows and edits still in the outbox', () async {
      await store.applyPull('todos', [
        {'id': 'a', 'title': 'synced', updatedAtColumn: '2026-01-01'},
      ], 'cursor-1');
      await store.insert('todos', 'b', {
        'title': 'still uploading',
      }, transactionId: 'tx-1');

      final export = await store.exportAll();

      expect(export.keys, ['todos']);
      final titles = {
        for (final row in export['todos']!) row['id']: row['title'],
      };
      expect(titles, {'a': 'synced', 'b': 'still uploading'});
    });

    test('a remote-only collection is not exported', () async {
      final withRemoteOnly = OnebaseSchema([
        ...schema.collections.values,
        MongoCollectionSchema(
          'audit_log',
          fields: {
            'note': MongoFieldType.text,
            'owner_id': MongoFieldType.text,
          },
          ownerField: 'owner_id',
          sync: const SyncPolicy(mode: SyncMode.none),
        ),
      ]);
      final remoteStore = LocalStore(db, withRemoteOnly);
      await remoteStore.migrate();

      final export = await remoteStore.exportAll();

      expect(export.keys, isNot(contains('audit_log')));
    });

    test('import restores rows into a fresh store', () async {
      final exported = {
        'todos': [
          {'id': 'a', 'title': 'restored', 'done': 0, updatedAtColumn: 't1'},
        ],
      };

      await store.importAll(exported, reupload: false);

      final rows = await rows_();
      expect(rows.single['id'], 'a');
      expect(rows.single['title'], 'restored');
    });

    test(
      'import with reupload true queues the row for the next sync',
      () async {
        await store.importAll({
          'todos': [
            {'id': 'a', 'title': 'restored'},
          ],
        }, reupload: true);

        final ops = await store.pendingOps();
        expect(ops.single.op, 'put');
        expect(ops.single.documentId, 'a');
        // _updated_at and id must never be re-sent — the server owns one and
        // assigns the other.
        expect(ops.single.data, isNot(contains(updatedAtColumn)));
        expect(ops.single.data, isNot(contains('id')));
      },
    );

    test(
      'import with reupload false restores silently, no outbox entry',
      () async {
        await store.importAll({
          'todos': [
            {'id': 'a', 'title': 'restored'},
          ],
        }, reupload: false);

        expect(await store.pendingCount(), 0);
      },
    );

    test(
      'a collection name the current schema no longer declares is skipped',
      () async {
        await store.importAll({
          'ghost_collection': [
            {'id': 'a', 'note': 'from an older app version'},
          ],
        }, reupload: false);

        expect(await rows_(), isEmpty);
      },
    );

    test('round-trips through export and import unchanged', () async {
      await store.insert('todos', 'a', {
        'title': 'roundtrip',
        'done': 1,
      }, transactionId: 'tx-1');

      final exported = await store.exportAll();
      await store.clear();
      await store.importAll(exported, reupload: false);

      final rows = await rows_();
      expect(rows.single['title'], 'roundtrip');
      expect(rows.single['done'], 1);
    });
  });
}

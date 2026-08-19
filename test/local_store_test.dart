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

  Future<List<Map<String, Object?>>> rows() async => (await db.getAll(
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

      expect((await rows()).single['title'], 'milk');
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

      final row = (await rows()).single;
      expect(row['title'], 'milk');
      expect(row['done'], 1);
      expect((await store.pendingOps()).last.op, 'patch');
    });

    test('delete removes the row and queues a delete op', () async {
      await store.insert('todos', 'a', {
        'title': 'milk',
      }, transactionId: 'tx-1');
      await store.delete('todos', 'a', transactionId: 'tx-2');

      expect(await rows(), isEmpty);
      final pending = await store.pendingOps();
      expect(pending.last.op, 'delete');
      expect(pending.last.data, isNull);
    });

    test('a write and its outbox entry land together', () async {
      // Both statements share one transaction, so a crash can never leave a
      // local row that will not be uploaded.
      await store.insert('todos', 'a', {'title': 'x'}, transactionId: 'tx-1');
      expect((await rows()).length, await store.pendingCount());
    });
  });

  group('applyPull', () {
    test('upserts server documents and advances the cursor', () async {
      await store.applyPull('todos', [
        {'id': 'srv-1', 'title': 'from server', 'done': 1},
      ], '2026-01-01T00:00:00.000Z');

      expect((await rows()).single['title'], 'from server');
      expect(await store.cursor('todos'), '2026-01-01T00:00:00.000Z');
    });

    test('removes documents flagged deleted', () async {
      await store.applyPull('todos', [
        {'id': 'srv-1', 'title': 'x'},
      ], 'c1');
      await store.applyPull('todos', [
        {'id': 'srv-1', '_deleted': true},
      ], 'c2');

      expect(await rows(), isEmpty);
    });

    test('accepts _id as well as id', () async {
      await store.applyPull('todos', [
        {'_id': 'srv-1', 'title': 'x'},
      ], 'c1');
      expect((await rows()).single['id'], 'srv-1');
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

        final row = (await rows()).single;
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

      expect(await rows(), isEmpty);
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

      expect(await rows(), isEmpty);
      expect(await store.pendingCount(), 0);
      expect(await store.cursor('todos'), isNull);
    });
  });
}

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:onebase/src/client/batch.dart';
import 'package:onebase/src/errors.dart';
import 'package:onebase/src/schema/schema.dart';
import 'package:onebase/src/store/local_store.dart';
import 'package:onebase/src/store/local_writer.dart';
import 'package:sqlite_async/sqlite_async.dart';

import 'fake_executor.dart';

void main() {
  final schema = OnebaseSchema([
    MongoCollectionSchema(
      'orders',
      fields: {'total': MongoFieldType.int, 'owner_id': MongoFieldType.text},
      ownerField: 'owner_id',
    ),
    MongoCollectionSchema(
      'inventory',
      fields: {'count': MongoFieldType.int},
      shared: true,
    ),
  ]);

  group('grouping', () {
    late FakeWriter writer;

    setUp(() => writer = FakeWriter());

    test('every operation shares one transaction id', () async {
      final batch = WriteBatch(writer, schema, ownerId: 'user-1');
      batch.insert('orders', {'total': 42});
      batch.update('inventory', 'stock-1', {'count': 9});
      batch.delete('inventory', 'stock-2');
      await batch.commit();

      final ids = writer.writes.map((w) => w.transactionId).toSet();
      expect(ids, hasLength(1), reason: 'the backend applies these together');
      expect(ids.single, isNotNull);
    });

    test('separate batches do not share a transaction', () async {
      final first = WriteBatch(writer, schema, ownerId: 'user-1')
        ..insert('orders', {'total': 1});
      await first.commit();
      final second = WriteBatch(writer, schema, ownerId: 'user-1')
        ..insert('orders', {'total': 2});
      await second.commit();

      expect(writer.writes.map((w) => w.transactionId).toSet(), hasLength(2));
    });

    test('nothing is written before commit', () async {
      WriteBatch(writer, schema, ownerId: 'user-1')
        ..insert('orders', {'total': 42})
        ..update('inventory', 'stock-1', {'count': 9});
      expect(writer.writes, isEmpty);
    });

    test('operations apply in the order they were queued', () async {
      final batch = WriteBatch(writer, schema, ownerId: 'user-1');
      batch.insert('orders', {'total': 1}, id: 'a');
      batch.delete('orders', 'b');
      batch.update('orders', 'c', {'total': 2});
      await batch.commit();

      expect(writer.writes.map((w) => w.op), ['put', 'delete', 'patch']);
    });
  });

  group('behaviour', () {
    late FakeWriter writer;
    setUp(() => writer = FakeWriter());

    test('insert returns the id up front, so it can be referenced', () async {
      final batch = WriteBatch(writer, schema, ownerId: 'user-1');
      final orderId = batch.insert('orders', {'total': 42});
      // The id exists before commit, which is what lets a later operation in
      // the same batch point at it.
      batch.update('orders', orderId, {'total': 43});
      await batch.commit();

      expect(writer.writes.first.id, orderId);
      expect(writer.writes.last.id, orderId);
    });

    test('the owner field is filled from the signed-in user', () async {
      final batch = WriteBatch(writer, schema, ownerId: 'alice');
      batch.insert('orders', {'total': 42});
      await batch.commit();
      expect(writer.lastWrite.data!['owner_id'], 'alice');
    });

    test('an explicit owner is respected', () async {
      final batch = WriteBatch(writer, schema, ownerId: 'alice');
      batch.insert('orders', {'total': 1, 'owner_id': 'bob'});
      await batch.commit();
      expect(writer.lastWrite.data!['owner_id'], 'bob');
    });

    test('values are encoded like any other write', () async {
      final batch = WriteBatch(writer, schema, ownerId: 'alice');
      batch.insert('orders', {'total': 7});
      await batch.commit();
      expect(writer.lastWrite.data!['total'], 7);
    });

    test('a shared collection needs no user', () async {
      final batch = WriteBatch(writer, schema);
      batch.insert('inventory', {'count': 3});
      await batch.commit();
      expect(writer.writes, hasLength(1));
    });
  });

  group('validation', () {
    late FakeWriter writer;
    setUp(() => writer = FakeWriter());

    test('rejects an unknown collection where it was written', () {
      final batch = WriteBatch(writer, schema, ownerId: 'user-1');
      expect(
        () => batch.insert('ghosts', {'a': 1}),
        throwsA(isA<UnknownCollectionException>()),
      );
      expect(
        () => batch.delete('ghosts', 'x'),
        throwsA(isA<UnknownCollectionException>()),
      );
    });

    test('rejects an unknown field', () {
      final batch = WriteBatch(writer, schema, ownerId: 'user-1');
      expect(
        () => batch.insert('orders', {'nope': 1}),
        throwsA(isA<UnknownFieldException>()),
      );
    });

    test('rejects an empty update', () {
      final batch = WriteBatch(writer, schema, ownerId: 'user-1');
      expect(
        () => batch.update('orders', 'a', {}),
        throwsA(isA<QueryException>()),
      );
    });

    test('refuses a second commit', () async {
      final batch = WriteBatch(writer, schema, ownerId: 'user-1')
        ..insert('orders', {'total': 1});
      await batch.commit();
      await expectLater(batch.commit(), throwsA(isA<OnebaseException>()));
    });

    test('refuses more operations after commit', () async {
      final batch = WriteBatch(writer, schema, ownerId: 'user-1')
        ..insert('orders', {'total': 1});
      await batch.commit();
      expect(
        () => batch.insert('orders', {'total': 2}),
        throwsA(isA<OnebaseException>()),
      );
    });

    test('requires a signed-in user for an owned collection', () {
      final batch = WriteBatch(writer, schema);
      expect(
        () => batch.insert('orders', {'total': 1}),
        throwsA(isA<InvalidTokenException>()),
      );
    });
  });

  group('against real SQLite', () {
    late Directory dir;
    late SqliteDatabase db;
    late LocalStore store;

    setUp(() async {
      dir = Directory.systemTemp.createTempSync('onebase_batch');
      db = SqliteDatabase(path: '${dir.path}/test.db');
      await db.initialize();
      store = LocalStore(db, schema);
      await store.migrate();
    });

    tearDown(() async {
      await db.close();
      dir.deleteSync(recursive: true);
    });

    test('the outbox queues one transaction for the whole batch', () async {
      final batch = WriteBatch(LocalWriter(store), schema, ownerId: 'alice');
      batch.insert('orders', {'total': 1});
      batch.insert('orders', {'total': 2});
      batch.insert('inventory', {'count': 3});
      await batch.commit();

      final pending = await store.pendingOps();
      expect(pending, hasLength(3));
      expect(
        pending.map((op) => op.transactionId).toSet(),
        hasLength(1),
        reason: 'uploaded and applied as one unit',
      );
    });

    test('rows are visible locally straight away', () async {
      final batch = WriteBatch(LocalWriter(store), schema, ownerId: 'alice');
      batch.insert('orders', {'total': 42});
      await batch.commit();

      final rows = await db.getAll('SELECT * FROM "orders"');
      expect(rows.single['total'], 42);
      expect(rows.single['owner_id'], 'alice');
    });
  });
}

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:onebase/src/client/collection.dart';
import 'package:onebase/src/client/document_writer.dart';
import 'package:onebase/src/query/cursor.dart';
import 'package:onebase/src/query/local_query_runner.dart';
import 'package:onebase/src/schema/schema.dart';
import 'package:onebase/src/store/local_store.dart';
import 'package:onebase/src/store/local_writer.dart';
import 'package:onebase/src/store/sqlite_executor.dart';
import 'package:sqlite_async/sqlite_async.dart';

void main() {
  final collectionSchema = MongoCollectionSchema(
    'todos',
    fields: {
      'title': MongoFieldType.text,
      'priority': MongoFieldType.int,
      'done': MongoFieldType.bool,
    },
    shared: true,
  );
  final schema = OnebaseSchema([collectionSchema]);

  late Directory dir;
  late SqliteDatabase db;
  late LocalStore store;
  late MongoCollection todos;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('onebase_paging');
    db = SqliteDatabase(path: '${dir.path}/test.db');
    await db.initialize();
    store = LocalStore(db, schema);
    await store.migrate();

    final DocumentWriter writer = LocalWriter(store);
    todos = MongoCollection(
      LocalQueryRunner(SqliteExecutor(db)),
      writer,
      collectionSchema,
      currentUserId: () async => 'user-1',
      newId: () => 'unused',
    );

    // 25 rows, deliberately with duplicate sort values so the tiebreaker
    // matters.
    for (var i = 0; i < 25; i++) {
      await store.insert('todos', 'id-${i.toString().padLeft(2, '0')}', {
        'title': 'todo $i',
        'priority': i % 5,
        'done': 0,
      }, transactionId: 'tx-$i');
    }
  });

  tearDown(() async {
    await db.close();
    dir.deleteSync(recursive: true);
  });

  Future<List<String>> idsOf(Page<Map<String, Object?>> page) async => [
    for (final row in page.items) row['id']! as String,
  ];

  group('paging through a collection', () {
    test('walks every row exactly once, in order', () async {
      final seen = <String>[];
      var page = await todos.orderBy('id').limit(10).page();
      seen.addAll(await idsOf(page));

      while (page.hasMore) {
        page = await todos
            .orderBy('id')
            .limit(10)
            .startAfter(page.cursor!)
            .page();
        seen.addAll(await idsOf(page));
      }

      expect(seen, hasLength(25));
      expect(seen.toSet(), hasLength(25), reason: 'no duplicates');
      expect(seen, orderedEquals(List.of(seen)..sort()));
    });

    test('reports hasMore correctly at the boundary', () async {
      final exact = await todos.orderBy('id').limit(25).page();
      expect(exact.items, hasLength(25));
      expect(exact.hasMore, isFalse, reason: 'exactly the last page');

      final under = await todos.orderBy('id').limit(24).page();
      expect(under.hasMore, isTrue);
    });

    test('an empty result has no cursor', () async {
      final page = await todos
          .where('title', isEqualTo: 'nothing')
          .orderBy('id')
          .page();
      expect(page.items, isEmpty);
      expect(page.cursor, isNull);
      expect(page.hasMore, isFalse);
    });

    test('paging is stable when rows are inserted while scrolling', () async {
      final first = await todos.orderBy('id').limit(10).page();
      // A new row that sorts before the cursor would shift an offset window
      // and make the next page repeat an item.
      await store.insert('todos', 'id-00-new', {
        'title': 'inserted',
        'priority': 0,
        'done': 0,
      }, transactionId: 'tx-new');

      final second = await todos
          .orderBy('id')
          .limit(10)
          .startAfter(first.cursor!)
          .page();

      final overlap = (await idsOf(first)).toSet()
        ..retainAll(await idsOf(second));
      expect(overlap, isEmpty, reason: 'a page must never repeat a row');
    });
  });

  group('ordering', () {
    test('descending pages walk the collection backwards', () async {
      final seen = <String>[];
      var page = await todos.orderBy('id', descending: true).limit(10).page();
      seen.addAll(await idsOf(page));
      while (page.hasMore) {
        page = await todos
            .orderBy('id', descending: true)
            .limit(10)
            .startAfter(page.cursor!)
            .page();
        seen.addAll(await idsOf(page));
      }
      expect(seen, hasLength(25));
      expect(seen.first, 'id-24');
      expect(seen.last, 'id-00');
    });

    test('duplicate sort values still page without loss', () async {
      // priority repeats every 5 rows: the id tiebreaker is what saves this.
      final seen = <String>[];
      var page = await todos.orderBy('priority').limit(7).page();
      seen.addAll(await idsOf(page));
      while (page.hasMore) {
        page = await todos
            .orderBy('priority')
            .limit(7)
            .startAfter(page.cursor!)
            .page();
        seen.addAll(await idsOf(page));
      }
      expect(seen.toSet(), hasLength(25));
    });

    test('filters are preserved across pages', () async {
      final seen = <String>[];
      var page = await todos
          .where('priority', isEqualTo: 0)
          .orderBy('id')
          .limit(2)
          .page();
      seen.addAll(await idsOf(page));
      while (page.hasMore) {
        page = await todos
            .where('priority', isEqualTo: 0)
            .orderBy('id')
            .limit(2)
            .startAfter(page.cursor!)
            .page();
        seen.addAll(await idsOf(page));
      }
      expect(seen, hasLength(5), reason: '25 rows, priority 0 every 5th');
    });
  });

  group('cursors', () {
    test('round-trip through their encoded form', () {
      final cursor = QueryCursor(['a', 2, null], 'id-1');
      final decoded = QueryCursor.decode(cursor.encode());
      expect(decoded.values, ['a', 2, null]);
      expect(decoded.id, 'id-1');
    });

    test('a malformed cursor is rejected with an actionable message', () {
      expect(
        () => QueryCursor.decode('not-a-cursor'),
        throwsA(isA<Exception>()),
      );
    });
  });

  group('pager', () {
    test('accumulates pages and stops at the end', () async {
      final pager = todos.orderBy('id').pager(pageSize: 10);
      addTearDown(pager.dispose);

      await pager.loadMore();
      expect(pager.items, hasLength(10));
      expect(pager.hasMore, isTrue);

      await pager.loadMore();
      await pager.loadMore();
      expect(pager.items, hasLength(25));
      expect(pager.hasMore, isFalse);

      // Past the end is a no-op, not an error or a duplicate page.
      await pager.loadMore();
      expect(pager.items, hasLength(25));
    });

    test('concurrent loadMore calls do not double-load', () async {
      final pager = todos.orderBy('id').pager(pageSize: 10);
      addTearDown(pager.dispose);

      // What a scroll listener does: fire repeatedly during one frame.
      await Future.wait([pager.loadMore(), pager.loadMore(), pager.loadMore()]);

      expect(pager.items, hasLength(10), reason: 'one page, not three');
      expect(pager.items.map((e) => e['id']).toSet(), hasLength(10));
    });

    test('refresh starts over', () async {
      final pager = todos.orderBy('id').pager(pageSize: 10);
      addTearDown(pager.dispose);

      await pager.loadMore();
      await pager.loadMore();
      expect(pager.items, hasLength(20));

      await pager.refresh();
      expect(pager.items, hasLength(10));
      expect(pager.hasMore, isTrue);
    });

    test('emits on every state change so a widget can rebuild', () async {
      final pager = todos.orderBy('id').pager(pageSize: 10);
      addTearDown(pager.dispose);

      final states = <bool>[];
      pager.changes.listen((p) => states.add(p.isLoading));
      await pager.loadMore();
      await Future<void>.delayed(Duration.zero);

      expect(states, contains(true), reason: 'loading started');
      expect(states.last, isFalse, reason: 'loading finished');
    });
  });
}

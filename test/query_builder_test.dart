import 'package:flutter_test/flutter_test.dart';
import 'package:onebase/src/errors.dart';
import 'package:onebase/src/query/local_query_runner.dart';
import 'package:onebase/src/query/query_builder.dart';
import 'package:onebase/src/schema/schema.dart';

import 'fake_executor.dart';

void main() {
  final schema = MongoCollectionSchema(
    'todos',
    fields: {
      'title': MongoFieldType.text,
      'done': MongoFieldType.bool,
      'priority': MongoFieldType.int,
      'score': MongoFieldType.double,
      'due_at': MongoFieldType.datetime,
      'meta': MongoFieldType.json,
      'owner_id': MongoFieldType.text,
    },
    ownerField: 'owner_id',
  );

  MongoQuery query() => MongoQuery(LocalQueryRunner(FakeExecutor()), schema);

  group('compile', () {
    test('bare query selects everything', () {
      final compiled = query().compile();
      expect(compiled.sql, 'SELECT * FROM "todos"');
      expect(compiled.parameters, isEmpty);
    });

    test('isEqualTo on text', () {
      final compiled = query().where('title', isEqualTo: 'milk').compile();
      expect(compiled.sql, 'SELECT * FROM "todos" WHERE "title" = ?');
      expect(compiled.parameters, ['milk']);
    });

    test('bool values encode to 0/1', () {
      final compiled = query().where('done', isEqualTo: false).compile();
      expect(compiled.sql, 'SELECT * FROM "todos" WHERE "done" = ?');
      expect(compiled.parameters, [0]);
    });

    test('DateTime values encode to UTC ISO-8601', () {
      final due = DateTime.utc(2026, 7, 2, 12);
      final compiled = query().where('due_at', isLessThan: due).compile();
      expect(compiled.sql, 'SELECT * FROM "todos" WHERE "due_at" < ?');
      expect(compiled.parameters, ['2026-07-02T12:00:00.000Z']);
    });

    test('comparison operators', () {
      expect(query().where('priority', isGreaterThan: 2).compile().sql,
          contains('"priority" > ?'));
      expect(query().where('priority', isGreaterThanOrEqualTo: 2).compile().sql,
          contains('"priority" >= ?'));
      expect(query().where('priority', isLessThanOrEqualTo: 2).compile().sql,
          contains('"priority" <= ?'));
      expect(query().where('priority', isNotEqualTo: 2).compile().sql,
          contains('"priority" != ?'));
    });

    test('whereIn expands placeholders', () {
      final compiled = query().where('priority', whereIn: [1, 2, 3]).compile();
      expect(
          compiled.sql, 'SELECT * FROM "todos" WHERE "priority" IN (?, ?, ?)');
      expect(compiled.parameters, [1, 2, 3]);
    });

    test('isNull true and false', () {
      expect(query().where('due_at', isNull: true).compile().sql,
          contains('"due_at" IS NULL'));
      expect(query().where('due_at', isNull: false).compile().sql,
          contains('"due_at" IS NOT NULL'));
    });

    test('chained wheres combine with AND', () {
      final compiled = query()
          .where('done', isEqualTo: false)
          .where('priority', isGreaterThan: 1)
          .compile();
      expect(compiled.sql,
          'SELECT * FROM "todos" WHERE "done" = ? AND "priority" > ?');
      expect(compiled.parameters, [0, 1]);
    });

    test('orderBy, limit and offset', () {
      final compiled = query()
          .orderBy('due_at', descending: true)
          .orderBy('title')
          .limit(10)
          .offset(20)
          .compile();
      expect(
          compiled.sql,
          'SELECT * FROM "todos" ORDER BY "due_at" DESC, "title" ASC '
          'LIMIT ? OFFSET ?');
      expect(compiled.parameters, [10, 20]);
    });

    test('offset without limit uses LIMIT -1', () {
      final compiled = query().offset(5).compile();
      expect(compiled.sql, 'SELECT * FROM "todos" LIMIT -1 OFFSET ?');
      expect(compiled.parameters, [5]);
    });

    test('count query ignores order and limit', () {
      final compiled = query()
          .where('done', isEqualTo: true)
          .orderBy('title')
          .limit(5)
          .compile(count: true);
      expect(
          compiled.sql, 'SELECT COUNT(*) AS c FROM "todos" WHERE "done" = ?');
      expect(compiled.parameters, [1]);
    });

    test('dot-path on json field compiles to json_extract', () {
      final compiled =
          query().where('meta.tags.primary', isEqualTo: 'work').compile();
      expect(
          compiled.sql,
          'SELECT * FROM "todos" WHERE '
          "json_extract(\"meta\", '\$.tags.primary') = ?");
      expect(compiled.parameters, ['work']);
    });

    test('dot-path bool encodes as json scalar 0/1', () {
      final compiled =
          query().where('meta.archived', isEqualTo: true).compile();
      expect(compiled.parameters, [1]);
    });
  });

  group('validation', () {
    test('unknown field throws with declared fields listed', () {
      expect(
        () => query().where('titel', isEqualTo: 'x').compile(),
        throwsA(isA<UnknownFieldException>()
            .having((e) => e.hint, 'hint', contains('title'))),
      );
    });

    test('dot-path on non-json root is rejected', () {
      expect(
        () => query().where('title.foo', isEqualTo: 'x').compile(),
        throwsA(isA<QueryException>()),
      );
    });

    test('SQL injection through field names is impossible', () {
      expect(
        () => query().where('title"; DROP TABLE todos; --', isEqualTo: 'x'),
        throwsA(isA<InvalidFieldNameException>()),
      );
      expect(
        () => query().orderBy('title; DROP').compile(),
        throwsA(isA<InvalidFieldNameException>()),
      );
    });

    test('values are always parameterized, never inlined', () {
      final compiled = query()
          .where('title', isEqualTo: "'; DROP TABLE todos; --")
          .compile();
      expect(compiled.sql, isNot(contains('DROP')));
      expect(compiled.parameters, ["'; DROP TABLE todos; --"]);
    });

    test('where with no operator throws', () {
      expect(() => query().where('title'), throwsA(isA<QueryException>()));
    });

    test('where with two operators throws', () {
      expect(
        () => query().where('priority', isGreaterThan: 1, isLessThan: 5),
        throwsA(isA<QueryException>()),
      );
    });

    test('empty whereIn throws', () {
      expect(
        () => query().where('priority', whereIn: const []).compile(),
        throwsA(isA<QueryException>()),
      );
    });

    test('non-positive limit and negative offset throw', () {
      expect(() => query().limit(0), throwsA(isA<QueryException>()));
      expect(() => query().offset(-1), throwsA(isA<QueryException>()));
    });

    test('wrong value type for declared field throws', () {
      expect(
        () => query().where('done', isEqualTo: 'yes').compile(),
        throwsA(isA<QueryException>()),
      );
    });
  });

  group('execution', () {
    test('find decodes rows through the schema', () async {
      final executor = FakeExecutor()
        ..rows = [
          {
            'id': 'a',
            'title': 'milk',
            'done': 1,
            'due_at': '2026-07-02T12:00:00.000Z',
            'meta': '{"tags":["home"]}',
            'score': 3,
          },
        ];
      final results = await MongoQuery(LocalQueryRunner(executor), schema)
          .where('done', isEqualTo: true)
          .find();

      expect(results, hasLength(1));
      final doc = results.single;
      expect(doc['done'], true);
      expect(doc['due_at'], DateTime.utc(2026, 7, 2, 12));
      expect(doc['meta'], {
        'tags': ['home']
      });
      expect(doc['score'], 3.0);
      expect(doc['id'], 'a');
    });

    test('findOne returns null on empty result', () async {
      final executor = FakeExecutor();
      expect(await MongoQuery(LocalQueryRunner(executor), schema).findOne(),
          isNull);
      expect(executor.lastCall.sql, endsWith('LIMIT ?'));
    });

    test('count reads the aggregate', () async {
      final executor = FakeExecutor()
        ..rows = [
          {'c': 42}
        ];
      expect(await MongoQuery(LocalQueryRunner(executor), schema).count(), 42);
    });

    test('watch decodes every emission', () async {
      final executor = FakeExecutor()
        ..rows = [
          {'id': 'a', 'done': 0},
        ];
      final emission =
          await MongoQuery(LocalQueryRunner(executor), schema).watch().first;
      expect(emission.single['done'], false);
    });
  });
}

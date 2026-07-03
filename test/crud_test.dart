import 'package:flutter_test/flutter_test.dart';
import 'package:mongo_easy/src/client/collection.dart';
import 'package:mongo_easy/src/errors.dart';
import 'package:mongo_easy/src/schema/schema.dart';

import 'fake_executor.dart';

void main() {
  final schema = MongoCollectionSchema(
    'todos',
    fields: {
      'title': MongoFieldType.text,
      'done': MongoFieldType.bool,
      'due_at': MongoFieldType.datetime,
      'meta': MongoFieldType.json,
      'owner_id': MongoFieldType.text,
    },
    ownerField: 'owner_id',
  );

  late FakeExecutor executor;

  MongoCollection collection({String userId = 'user-1'}) {
    return MongoCollection(
      executor,
      schema,
      currentUserId: () async => userId,
      newId: () => 'generated-id',
    );
  }

  setUp(() => executor = FakeExecutor());

  group('insert', () {
    test('generates an id and returns it', () async {
      final id = await collection().insert({'title': 'milk'});
      expect(id, 'generated-id');

      final call = executor.lastCall;
      expect(call.sql,
          'INSERT INTO "todos" (id, "title", "owner_id") VALUES (?, ?, ?)');
      expect(call.parameters, ['generated-id', 'milk', 'user-1']);
    });

    test('auto-fills the owner field with the current user', () async {
      await collection(userId: 'alice').insert({'title': 'x'});
      expect(executor.lastCall.parameters, contains('alice'));
    });

    test('respects an explicitly provided owner', () async {
      await collection().insert({'title': 'x', 'owner_id': 'custom'});
      expect(executor.lastCall.parameters, contains('custom'));
      expect(executor.lastCall.parameters, isNot(contains('user-1')));
    });

    test('encodes bool, DateTime and json values', () async {
      await collection().insert({
        'title': 'x',
        'done': true,
        'due_at': DateTime.utc(2026, 1, 1),
        'meta': {'a': 1},
      });
      expect(executor.lastCall.parameters, [
        'generated-id',
        'x',
        1,
        '2026-01-01T00:00:00.000Z',
        '{"a":1}',
        'user-1',
      ]);
    });

    test('rejects fields not in the schema', () {
      expect(
        () => collection().insert({'nope': 1}),
        throwsA(isA<UnknownFieldException>()),
      );
    });
  });

  group('update', () {
    test('builds a partial SET statement', () async {
      await collection().update('abc', {'done': true, 'title': 'new'});
      final call = executor.lastCall;
      expect(
          call.sql, 'UPDATE "todos" SET "done" = ?, "title" = ? WHERE id = ?');
      expect(call.parameters, [1, 'new', 'abc']);
    });

    test('rejects empty changes', () {
      expect(
          () => collection().update('abc', {}), throwsA(isA<QueryException>()));
    });

    test('rejects unknown fields', () {
      expect(() => collection().update('abc', {'ghost': 1}),
          throwsA(isA<UnknownFieldException>()));
    });
  });

  group('delete', () {
    test('deletes by id', () async {
      await collection().delete('abc');
      final call = executor.lastCall;
      expect(call.sql, 'DELETE FROM "todos" WHERE id = ?');
      expect(call.parameters, ['abc']);
    });
  });

  group('findById', () {
    test('decodes the row', () async {
      executor.rows = [
        {'id': 'abc', 'done': 1, 'meta': '{"k":true}'},
      ];
      final doc = await collection().findById('abc');
      expect(doc!['done'], true);
      expect(doc['meta'], {'k': true});
    });

    test('returns null when missing', () async {
      expect(await collection().findById('nope'), isNull);
    });
  });

  group('withConverter', () {
    test('round-trips through fromJson/toJson and strips id on insert',
        () async {
      final typed = collection().withConverter<_Todo>(
        fromJson: _Todo.fromJson,
        toJson: (todo) => todo.toJson(),
      );

      await typed.insert(const _Todo(id: 'ignored', title: 'a', done: false));
      expect(executor.lastCall.sql, isNot(contains('"id" =')));
      expect(executor.lastCall.parameters.first, 'generated-id');

      executor.rows = [
        {'id': 'abc', 'title': 'a', 'done': 1},
      ];
      final todos = await typed.find();
      expect(todos.single, const _Todo(id: 'abc', title: 'a', done: true));
    });

    test('typed queries chain and decode', () async {
      final typed = collection().withConverter<_Todo>(
        fromJson: _Todo.fromJson,
        toJson: (todo) => todo.toJson(),
      );
      executor.rows = [
        {'id': 'abc', 'title': 'a', 'done': 0},
      ];
      final results = await typed
          .where('done', isEqualTo: false)
          .orderBy('title')
          .limit(5)
          .find();
      expect(results.single.done, false);
      expect(executor.lastCall.sql,
          contains('WHERE "done" = ? ORDER BY "title" ASC LIMIT ?'));
    });
  });

  group('collection without owner (shared)', () {
    test('insert does not require a user', () async {
      final shared = MongoCollection(
        executor,
        MongoCollectionSchema('tags',
            fields: {'name': MongoFieldType.text}, shared: true),
        currentUserId: () async => throw StateError('must not be called'),
        newId: () => 'id-1',
      );
      await shared.insert({'name': 'work'});
      expect(executor.lastCall.parameters, ['id-1', 'work']);
    });
  });
}

class _Todo {
  const _Todo({required this.id, required this.title, required this.done});

  factory _Todo.fromJson(Map<String, Object?> json) => _Todo(
        id: json['id']! as String,
        title: json['title']! as String,
        done: json['done']! as bool,
      );

  final String id;
  final String title;
  final bool done;

  Map<String, Object?> toJson() => {'id': id, 'title': title, 'done': done};

  @override
  bool operator ==(Object other) =>
      other is _Todo &&
      other.id == id &&
      other.title == title &&
      other.done == done;

  @override
  int get hashCode => Object.hash(id, title, done);
}

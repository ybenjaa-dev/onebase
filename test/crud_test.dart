import 'package:flutter_test/flutter_test.dart';
import 'package:onebase/src/client/collection.dart';
import 'package:onebase/src/errors.dart';
import 'package:onebase/src/query/local_query_runner.dart';
import 'package:onebase/src/schema/schema.dart';

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
  late FakeWriter writer;

  MongoCollection collection({String userId = 'user-1'}) {
    return MongoCollection(
      LocalQueryRunner(executor),
      writer,
      schema,
      currentUserId: () async => userId,
      newId: () => 'generated-id',
    );
  }

  setUp(() {
    executor = FakeExecutor();
    writer = FakeWriter();
  });

  group('insert', () {
    test('generates an id and returns it', () async {
      final id = await collection().insert({'title': 'milk'});
      expect(id, 'generated-id');

      final write = writer.lastWrite;
      expect(write.op, 'put');
      expect(write.collection, 'todos');
      expect(write.id, 'generated-id');
      expect(write.data, {'title': 'milk', 'owner_id': 'user-1'});
    });

    test('auto-fills the owner field with the current user', () async {
      await collection(userId: 'alice').insert({'title': 'x'});
      expect(writer.lastWrite.data!['owner_id'], 'alice');
    });

    test('respects an explicitly provided owner', () async {
      await collection().insert({'title': 'x', 'owner_id': 'custom'});
      expect(writer.lastWrite.data!['owner_id'], 'custom');
    });

    test('encodes bool, DateTime and json values', () async {
      await collection().insert({
        'title': 'x',
        'done': true,
        'due_at': DateTime.utc(2026, 1, 1),
        'meta': {'a': 1},
      });
      expect(writer.lastWrite.data, {
        'title': 'x',
        'done': 1,
        'due_at': '2026-01-01T00:00:00.000Z',
        'meta': '{"a":1}',
        'owner_id': 'user-1',
      });
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
      final write = writer.lastWrite;
      expect(write.op, 'patch');
      expect(write.id, 'abc');
      expect(write.data, {'done': 1, 'title': 'new'});
    });

    test('rejects empty changes', () {
      expect(
        () => collection().update('abc', {}),
        throwsA(isA<QueryException>()),
      );
    });

    test('rejects unknown fields', () {
      expect(
        () => collection().update('abc', {'ghost': 1}),
        throwsA(isA<UnknownFieldException>()),
      );
    });
  });

  group('delete', () {
    test('deletes by id', () async {
      await collection().delete('abc');
      final write = writer.lastWrite;
      expect(write.op, 'delete');
      expect(write.collection, 'todos');
      expect(write.id, 'abc');
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
    test(
      'round-trips through fromJson/toJson and strips id on insert',
      () async {
        final typed = collection().withConverter<_Todo>(
          fromJson: _Todo.fromJson,
          toJson: (todo) => todo.toJson(),
        );

        await typed.insert(const _Todo(id: 'ignored', title: 'a', done: false));
        expect(writer.lastWrite.id, 'generated-id');
        expect(writer.lastWrite.data, isNot(contains('id')));

        executor.rows = [
          {'id': 'abc', 'title': 'a', 'done': 1},
        ];
        final todos = await typed.find();
        expect(todos.single, const _Todo(id: 'abc', title: 'a', done: true));
      },
    );

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
      expect(
        executor.lastCall.sql,
        contains('WHERE "done" = ? ORDER BY "title" ASC, "id" ASC LIMIT ?'),
      );
    });
  });

  group('collection without owner (shared)', () {
    test('insert does not require a user', () async {
      final shared = MongoCollection(
        LocalQueryRunner(executor),
        writer,
        MongoCollectionSchema(
          'tags',
          fields: {'name': MongoFieldType.text},
          shared: true,
        ),
        currentUserId: () async => throw StateError('must not be called'),
        newId: () => 'id-1',
      );
      await shared.insert({'name': 'work'});
      expect(writer.lastWrite.id, 'id-1');
      expect(writer.lastWrite.data, {'name': 'work'});
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

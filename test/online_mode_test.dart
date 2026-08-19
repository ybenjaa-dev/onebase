import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:onebase/src/auth/token_provider.dart';
import 'package:onebase/src/client/collection.dart';
import 'package:onebase/src/client/remote_writer.dart';
import 'package:onebase/src/errors.dart';
import 'package:onebase/src/query/query_spec.dart';
import 'package:onebase/src/query/remote_query_runner.dart';
import 'package:onebase/src/schema/schema.dart';
import 'package:onebase/src/sync/sync_api.dart';

void main() {
  final schema = MongoCollectionSchema(
    'todos',
    fields: {
      'title': MongoFieldType.text,
      'done': MongoFieldType.bool,
      'owner_id': MongoFieldType.text,
    },
    ownerField: 'owner_id',
  );

  late List<Map<String, Object?>> sent;
  late List<String> paths;

  setUp(() {
    sent = [];
    paths = [];
  });

  SyncApi apiWith(Future<http.Response> Function(http.Request) handler) {
    return SyncApi(
      baseUrl: 'https://api.test',
      tokenProvider: TokenProvider.static('token'),
      httpClient: MockClient((request) async {
        paths.add(request.url.path);
        sent.add((jsonDecode(request.body) as Map).cast<String, Object?>());
        return handler(request);
      }),
    );
  }

  http.Response ok(Map<String, Object?> body) =>
      http.Response(jsonEncode(body), 200,
          headers: {'content-type': 'application/json'});

  group('reads', () {
    test('find posts the encoded query and decodes the response', () async {
      final api = apiWith((_) async => ok({
            'documents': [
              {'id': 'a', 'title': 'milk', 'done': 1},
            ],
          }));
      final runner = RemoteQueryRunner(api);

      final results = await MongoCollection(
        runner,
        RemoteWriter(api),
        schema,
        currentUserId: () async => 'user-1',
        newId: () => 'id-1',
      ).where('done', isEqualTo: false).orderBy('title').limit(5).find();

      expect(paths.single, '/query');
      expect(sent.single['collection'], 'todos');
      expect(sent.single['limit'], 5);
      // Decoding still happens client-side, so bool stays a Dart bool.
      expect(results.single['done'], true);
    });

    test('count asks the backend to count, not to send documents', () async {
      final api = apiWith((_) async => ok({'count': 7}));
      expect(await RemoteQueryRunner(api).count(schema, const QuerySpec()), 7);
      expect(sent.single['count'], true);
    });

    test('findById returns null when the backend has nothing', () async {
      final api = apiWith((_) async => ok({'documents': const []}));
      expect(await RemoteQueryRunner(api).findById(schema, 'missing'), isNull);
      expect(sent.single['id'], 'missing');
    });
  });

  group('writes', () {
    test('insert posts one transaction to /push', () async {
      final api = apiWith((_) async => ok({'applied': 1, 'skipped': const []}));
      final id = await MongoCollection(
        RemoteQueryRunner(api),
        RemoteWriter(api),
        schema,
        currentUserId: () async => 'user-1',
        newId: () => 'id-1',
      ).insert({'title': 'milk'});

      expect(id, 'id-1');
      expect(paths.single, '/push');
      final ops = ((sent.single['transactions']! as List).single as Map)['ops']!
          as List;
      expect((ops.single as Map)['op'], 'put');
      expect(
          (ops.single as Map)['data'], {'title': 'milk', 'owner_id': 'user-1'});
    });

    test('a refused write throws instead of failing silently', () async {
      final api = apiWith((_) async => ok({
            'applied': 0,
            'skipped': [
              {'id': 'a', 'collection': 'todos', 'reason': 'not owned'},
            ],
          }));
      // Online mode has no queue, so the caller must learn immediately.
      await expectLater(
        RemoteWriter(api).delete('todos', 'a'),
        throwsA(isA<UploadException>()),
      );
    });
  });

  group('watch', () {
    test('re-queries when realtime reports a change, and dedupes', () async {
      var title = 'first';
      final api = apiWith((_) async => ok({
            'documents': [
              {'id': 'a', 'title': title},
            ],
          }));
      final changes = StreamController<String>.broadcast();
      final runner = RemoteQueryRunner(
        api,
        changes: changes.stream,
        pollInterval: const Duration(hours: 1),
      );

      final seen = <List<Map<String, Object?>>>[];
      final sub = runner.watch(schema, const QuerySpec()).listen(seen.add);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      // Same data → no second emission.
      changes.add('todos');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(seen, hasLength(1));

      title = 'second';
      changes.add('todos');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(seen, hasLength(2));
      expect(seen.last.single['title'], 'second');

      await sub.cancel();
      await changes.close();
    });

    test('ignores changes to other collections', () async {
      final api = apiWith((_) async => ok({'documents': const []}));
      final changes = StreamController<String>.broadcast();
      final runner = RemoteQueryRunner(
        api,
        changes: changes.stream,
        pollInterval: const Duration(hours: 1),
      );

      final sub = runner.watch(schema, const QuerySpec()).listen((_) {});
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final before = paths.length;

      changes.add('other_collection');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(paths.length, before);

      await sub.cancel();
      await changes.close();
    });

    test('polls when no realtime channel is available', () async {
      final api = apiWith((_) async => ok({'documents': const []}));
      final runner = RemoteQueryRunner(api,
          pollInterval: const Duration(milliseconds: 20));

      final sub = runner.watch(schema, const QuerySpec()).listen((_) {});
      await Future<void>.delayed(const Duration(milliseconds: 120));
      await sub.cancel();

      expect(paths.length, greaterThan(1));
    });

    test('stops querying once the stream is cancelled', () async {
      final api = apiWith((_) async => ok({'documents': const []}));
      final runner = RemoteQueryRunner(api,
          pollInterval: const Duration(milliseconds: 20));

      final sub = runner.watch(schema, const QuerySpec()).listen((_) {});
      await Future<void>.delayed(const Duration(milliseconds: 60));
      await sub.cancel();
      final after = paths.length;

      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(paths.length, after);
    });
  });
}

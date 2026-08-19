import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mongobase/src/auth/token_provider.dart';
import 'package:mongobase/src/schema/schema.dart';
import 'package:mongobase/src/store/local_store.dart';
import 'package:mongobase/src/sync/sync_api.dart';
import 'package:mongobase/src/sync/sync_engine.dart';
import 'package:mongobase/src/sync/sync_status.dart';
import 'package:sqlite_async/sqlite_async.dart';

void main() {
  final schema = MongobaseSchema([
    MongoCollectionSchema(
      'todos',
      fields: {
        'title': MongoFieldType.text,
        'owner_id': MongoFieldType.text,
      },
      ownerField: 'owner_id',
    ),
  ]);

  late Directory dir;
  late SqliteDatabase db;
  late LocalStore store;
  late List<String> routes;
  late List<Map<String, Object?>> bodies;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('mongobase_sync');
    db = SqliteDatabase(path: '${dir.path}/test.db');
    await db.initialize();
    store = LocalStore(db, schema);
    await store.migrate();
    routes = [];
    bodies = [];
  });

  tearDown(() async {
    await db.close();
    dir.deleteSync(recursive: true);
  });

  /// Builds an engine whose backend responds via [handler].
  SyncEngine engineWith(
    Future<http.Response> Function(http.Request request) handler,
  ) {
    final client = MockClient((request) async {
      routes.add(request.url.path);
      bodies.add((jsonDecode(request.body) as Map).cast<String, Object?>());
      return handler(request);
    });
    return SyncEngine(
      store: store,
      api: SyncApi(
        baseUrl: 'https://api.test',
        tokenProvider: TokenProvider.static('token'),
        httpClient: client,
      ),
      schema: schema,
      interval: const Duration(hours: 1),
    );
  }

  http.Response ok(Map<String, Object?> body) =>
      http.Response(jsonEncode(body), 200,
          headers: {'content-type': 'application/json'});

  SyncEngine happyEngine({List<Map<String, Object?>> documents = const []}) {
    return engineWith((request) async {
      if (request.url.path == '/push') {
        return ok({'applied': 1, 'skipped': const []});
      }
      return ok({'documents': documents, 'cursor': 'c1', 'has_more': false});
    });
  }

  group('push', () {
    test('uploads queued writes grouped by transaction, then clears them',
        () async {
      await store.insert('todos', 'a', {'title': 'milk'},
          transactionId: 'tx-1');
      await store.update('todos', 'a', {'title': 'bread'},
          transactionId: 'tx-1');
      await store.insert('todos', 'b', {'title': 'eggs'},
          transactionId: 'tx-2');

      final engine = happyEngine();
      addTearDown(engine.close);
      expect(await engine.syncNow(), isTrue);

      final push = bodies.first['transactions']! as List;
      expect(push, hasLength(2), reason: 'two transaction groups');
      expect((push.first as Map)['id'], 'tx-1');
      expect(((push.first as Map)['ops'] as List), hasLength(2));
      expect(await store.pendingCount(), 0);
    });

    test('runs before pull so a fresh write is never clobbered', () async {
      await store.insert('todos', 'a', {'title': 'milk'},
          transactionId: 'tx-1');
      final engine = happyEngine();
      addTearDown(engine.close);
      await engine.syncNow();

      expect(routes.first, '/push');
      expect(routes, contains('/pull'));
    });

    test('skips push entirely when nothing is queued', () async {
      final engine = happyEngine();
      addTearDown(engine.close);
      await engine.syncNow();

      expect(routes, isNot(contains('/push')));
    });

    test('drops writes the backend permanently refused and reports them',
        () async {
      await store.insert('todos', 'a', {'title': 'milk'},
          transactionId: 'tx-1');

      final engine = engineWith((request) async {
        if (request.url.path == '/push') {
          return ok({
            'applied': 0,
            'skipped': [
              {'id': 'a', 'collection': 'todos', 'reason': 'not owned'},
            ],
          });
        }
        return ok({'documents': const [], 'cursor': null, 'has_more': false});
      });
      addTearDown(engine.close);
      await engine.syncNow();

      // Retrying forever would wedge every later write behind this one.
      expect(await store.pendingCount(), 0);
    });
  });

  group('pull', () {
    test('applies documents and advances the cursor', () async {
      final engine = happyEngine(documents: [
        {'id': 'srv-1', 'title': 'from server'},
      ]);
      addTearDown(engine.close);
      await engine.syncNow();

      final rows = await db.getAll('SELECT * FROM "todos"');
      expect(rows.single['title'], 'from server');
      expect(await store.cursor('todos'), 'c1');
    });

    test('sends the stored cursor on the next sync', () async {
      final engine = happyEngine(documents: [
        {'id': 'srv-1', 'title': 'x'},
      ]);
      addTearDown(engine.close);
      await engine.syncNow();
      await engine.syncNow();

      final pulls = bodies.where((b) => b.containsKey('collection')).toList();
      expect(pulls.first['since'], isNull);
      expect(pulls.last['since'], 'c1');
    });

    test('drains pages while the server reports more', () async {
      var page = 0;
      final engine = engineWith((request) async {
        page++;
        return ok({
          'documents': [
            {'id': 'srv-$page', 'title': 'page $page'},
          ],
          'cursor': 'c$page',
          'has_more': page < 3,
        });
      });
      addTearDown(engine.close);
      await engine.syncNow();

      final rows = await db.getAll('SELECT * FROM "todos"');
      expect(rows, hasLength(3));
      expect(await store.cursor('todos'), 'c3');
    });
  });

  group('failure handling', () {
    test('a network failure never throws and is reported in the status',
        () async {
      final engine = engineWith((_) async => throw const SocketException('x'));
      addTearDown(engine.close);

      expect(await engine.syncNow(), isFalse);
      expect(engine.status.connected, isFalse);
      expect(engine.status.offlineReason, SyncOffline.unreachable);
      expect(engine.status.error, isNotNull);
    });

    test('queued writes survive a failed sync', () async {
      await store.insert('todos', 'a', {'title': 'milk'},
          transactionId: 'tx-1');
      final engine = engineWith((_) async => http.Response('boom', 503));
      addTearDown(engine.close);

      await engine.syncNow();

      expect(await store.pendingCount(), 1);
      expect(engine.status.pendingWrites, 1);
    });

    test('a rejected token is reported as signed out', () async {
      final engine = SyncEngine(
        store: store,
        api: SyncApi(
          baseUrl: 'https://api.test',
          tokenProvider: const TokenProvider(_noToken),
          httpClient: MockClient((_) async => ok({})),
        ),
        schema: schema,
        interval: const Duration(hours: 1),
      );
      addTearDown(engine.close);
      await store.insert('todos', 'a', {'title': 'x'}, transactionId: 'tx-1');

      expect(await engine.syncNow(), isFalse);
      expect(engine.status.offlineReason, SyncOffline.signedOut);
    });

    test('recovers on the next attempt', () async {
      var fail = true;
      final engine = engineWith((request) async {
        if (fail) throw const SocketException('down');
        return ok({'documents': const [], 'cursor': 'c1', 'has_more': false});
      });
      addTearDown(engine.close);

      expect(await engine.syncNow(), isFalse);
      fail = false;
      expect(await engine.syncNow(), isTrue);
      expect(engine.status.connected, isTrue);
    });
  });

  group('status', () {
    test('reports a successful sync as up to date', () async {
      final engine = happyEngine();
      addTearDown(engine.close);
      await engine.syncNow();

      expect(engine.status.connected, isTrue);
      expect(engine.status.isUpToDate, isTrue);
      expect(engine.status.hasSynced, isTrue);
      expect(engine.status.error, isNull);
    });

    test('waitForFirstSync completes after the first success', () async {
      final engine = happyEngine();
      addTearDown(engine.close);

      final waiting = engine.firstSync;
      await engine.syncNow();
      await expectLater(waiting, completes);
    });

    test('emits status updates on the stream', () async {
      final engine = happyEngine();
      addTearDown(engine.close);

      final seen = <SyncStatus>[];
      final sub = engine.statusStream.listen(seen.add);
      await engine.syncNow();
      // Broadcast events are delivered asynchronously; let them land.
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();

      expect(seen, isNotEmpty);
      expect(seen.last.connected, isTrue);
      expect(seen.any((s) => s.downloading), isTrue);
    });
  });
}

Future<String?> _noToken() async => null;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mongo_easy/src/auth/token_provider.dart';
import 'package:mongo_easy/src/sync/realtime_client.dart';
import 'package:mongo_easy/src/sync/sync_api.dart';

void main() {
  late List<Uri> opened;
  late List<Map<String, String>> headers;

  setUp(() {
    opened = [];
    headers = [];
  });

  /// A backend whose stream body is driven by [frames].
  SyncApi streamingApi(
    Stream<String> frames, {
    int status = 200,
    TokenProvider? tokenProvider,
  }) {
    return SyncApi(
      baseUrl: 'https://api.test',
      tokenProvider: tokenProvider ?? TokenProvider.static('token'),
      httpClient: MockClient.streaming((request, _) async {
        opened.add(request.url);
        headers.add(Map.of(request.headers));
        return http.StreamedResponse(
          frames.map(utf8.encode),
          status,
          headers: {'content-type': 'text/event-stream'},
        );
      }),
    );
  }

  String frame(String collection, Map<String, Object?> document) =>
      'data: ${jsonEncode({
            'collection': collection,
            'document': document
          })}\n\n';

  test('subscribes with the token and the requested collections', () async {
    final client = RealtimeClient(
      api: streamingApi(const Stream.empty()),
      collections: ['todos', 'notes'],
    );
    addTearDown(client.close);

    client.start();
    await Future<void>.delayed(const Duration(milliseconds: 40));

    expect(opened.single.path, '/stream');
    expect(opened.single.queryParameters['collections'], 'todos,notes');
    expect(headers.single['Authorization'], 'Bearer token');
    expect(headers.single['Accept'], 'text/event-stream');
  });

  test('emits a document as it arrives', () async {
    final controller = StreamController<String>();
    final client = RealtimeClient(
      api: streamingApi(controller.stream),
      collections: ['todos'],
    );
    addTearDown(client.close);

    final received = <RealtimeEvent>[];
    client.events.listen(received.add);
    client.start();
    await Future<void>.delayed(const Duration(milliseconds: 40));

    controller.add(frame('todos', {'id': 'a', 'title': 'milk'}));
    await Future<void>.delayed(const Duration(milliseconds: 40));

    expect(received.single.collection, 'todos');
    expect(received.single.document['title'], 'milk');
    expect(received.single.isDelete, isFalse);
    await controller.close();
  });

  test('recognises a tombstone frame as a delete', () async {
    final controller = StreamController<String>();
    final client = RealtimeClient(
      api: streamingApi(controller.stream),
      collections: ['todos'],
    );
    addTearDown(client.close);

    final received = <RealtimeEvent>[];
    client.events.listen(received.add);
    client.start();
    await Future<void>.delayed(const Duration(milliseconds: 40));

    controller.add(frame('todos', {'id': 'a', '_deleted': true}));
    await Future<void>.delayed(const Duration(milliseconds: 40));

    expect(received.single.isDelete, isTrue);
    await controller.close();
  });

  test('handles frames split across chunks and ignores keepalives', () async {
    final controller = StreamController<String>();
    final client = RealtimeClient(
      api: streamingApi(controller.stream),
      collections: ['todos'],
    );
    addTearDown(client.close);

    final received = <RealtimeEvent>[];
    client.events.listen(received.add);
    client.start();
    await Future<void>.delayed(const Duration(milliseconds: 40));

    controller
      ..add(': keepalive\n\n')
      ..add('data: {"collection":"todos",')
      ..add('"document":{"id":"a"}}\n\n');
    await Future<void>.delayed(const Duration(milliseconds: 40));

    expect(received.single.document['id'], 'a');
    await controller.close();
  });

  test('reports connection state and reconnects after a drop', () async {
    var attempts = 0;
    final api = SyncApi(
      baseUrl: 'https://api.test',
      tokenProvider: TokenProvider.static('token'),
      httpClient: MockClient.streaming((request, _) async {
        attempts++;
        // First attempt ends immediately; the client must come back.
        return http.StreamedResponse(const Stream.empty(), 200);
      }),
    );
    final client = RealtimeClient(
      api: api,
      collections: ['todos'],
      retryDelay: const Duration(milliseconds: 20),
    );
    addTearDown(client.close);

    final states = <bool>[];
    client.connectionState.listen(states.add);
    client.start();
    await Future<void>.delayed(const Duration(milliseconds: 200));

    expect(attempts, greaterThan(1), reason: 'must retry a dropped stream');
    expect(states, contains(true));
    expect(states, contains(false));
  });

  test('backs off instead of hammering a failing backend', () async {
    var attempts = 0;
    final api = SyncApi(
      baseUrl: 'https://api.test',
      tokenProvider: TokenProvider.static('token'),
      httpClient: MockClient.streaming((request, _) async {
        attempts++;
        throw const SocketFailure();
      }),
    );
    final client = RealtimeClient(
      api: api,
      collections: ['todos'],
      retryDelay: const Duration(milliseconds: 10),
      maxRetryDelay: const Duration(milliseconds: 80),
    );
    addTearDown(client.close);

    client.start();
    await Future<void>.delayed(const Duration(milliseconds: 300));

    // Exponential backoff: far fewer than 30 attempts in 300ms.
    expect(attempts, lessThan(12));
    expect(client.isConnected, isFalse);
  });

  test('stop() ends reconnection attempts', () async {
    var attempts = 0;
    final api = SyncApi(
      baseUrl: 'https://api.test',
      tokenProvider: TokenProvider.static('token'),
      httpClient: MockClient.streaming((request, _) async {
        attempts++;
        return http.StreamedResponse(const Stream.empty(), 200);
      }),
    );
    final client = RealtimeClient(
      api: api,
      collections: ['todos'],
      retryDelay: const Duration(milliseconds: 10),
    );

    client.start();
    await Future<void>.delayed(const Duration(milliseconds: 60));
    await client.stop();
    final after = attempts;

    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(attempts, after);
    await client.close();
  });
}

class SocketFailure implements Exception {
  const SocketFailure();
}

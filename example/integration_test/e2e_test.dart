// Full-pipeline E2E against a running backend. Proves writes round-trip
// app → local SQLite → /push → MongoDB → /pull → back into SQLite.
//
// Start the backend first (example/backend: `npm run dev`), then:
//   flutter test integration_test/e2e_test.dart -d macos \
//     --dart-define=API_URL=http://localhost:3000
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:integration_test/integration_test.dart';
import 'package:onebase/onebase.dart';
import 'package:onebase_example/config.dart';
import 'package:onebase_example/onebase_schema.g.dart';

Future<String> fetchDevToken(String email) async {
  final response = await http.post(
    Uri.parse(AppConfig.tokenUrl),
    headers: {'Content-Type': 'application/json'},
    body: jsonEncode({'email': email}),
  );
  expect(response.statusCode, 200,
      reason: 'token endpoint must be up: ${response.body}');
  return (jsonDecode(response.body) as Map<String, Object?>)['token']!
      as String;
}

/// Uploads drain in the background; a fresh download after clearing local
/// data proves the write reached MongoDB itself.
Future<List<Map<String, Object?>>> roundTrip() async {
  final client = Onebase.instance;
  await client.clearLocalData();
  await client.refreshToken();
  await client.waitForFirstSync().timeout(const Duration(seconds: 30));
  return Onebase.collection('todos').find();
}

Future<void> waitForUpload() async {
  // The connector uploads within a second or two locally; poll generously.
  await Future<void>.delayed(const Duration(seconds: 4));
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('insert → update → delete round-trip through MongoDB',
      (tester) async {
    final runId = DateTime.now().millisecondsSinceEpoch;
    final email = 'e2e-$runId@test.dev';
    final token = await fetchDevToken(email);

    final databasePath =
        '${Directory.systemTemp.createTempSync('onebase_e2e').path}/e2e.db';
    await Onebase.init(
      OnebaseConfig(
        apiUrl: AppConfig.apiUrl,
        tokenProvider: TokenProvider.static(token),
        schema: onebaseSchema,
      ),
      databasePath: databasePath,
    );
    addTearDown(Onebase.close);

    await Onebase.instance
        .waitForFirstSync()
        .timeout(const Duration(seconds: 30));

    final todos = Onebase.collection('todos');
    final title = 'e2e todo $runId';

    // INSERT — offline-first write, then prove it reached MongoDB.
    final id = await todos.insert({
      'title': title,
      'done': false,
      'created_at': DateTime.now(),
    });
    await waitForUpload();
    var synced = await roundTrip();
    expect(synced.map((d) => d['title']), contains(title),
        reason: 'insert must round-trip through MongoDB');
    final syncedDoc = synced.singleWhere((d) => d['title'] == title);
    expect(syncedDoc['id'], id, reason: 'client-generated id is preserved');
    expect(syncedDoc['done'], false, reason: 'bool survives BSON round-trip');
    expect(syncedDoc['created_at'], isA<DateTime>(),
        reason: 'datetime survives BSON round-trip');

    // Owner isolation: the doc belongs to the JWT subject, assigned
    // server-side.
    expect(syncedDoc['owner_id'], Onebase.instance.currentUserId);

    // UPDATE (patch) round-trip.
    await todos.update(id, {'done': true});
    await waitForUpload();
    synced = await roundTrip();
    expect(synced.singleWhere((d) => d['id'] == id)['done'], true,
        reason: 'update must round-trip through MongoDB');

    // Query builder against synced data.
    final open = await todos.where('done', isEqualTo: false).count();
    final closed = await todos.where('done', isEqualTo: true).count();
    expect(closed, greaterThanOrEqualTo(1));
    expect(open + closed, synced.length);

    // DELETE round-trip.
    await todos.delete(id);
    await waitForUpload();
    synced = await roundTrip();
    expect(synced.map((d) => d['id']), isNot(contains(id)),
        reason: 'delete must round-trip through MongoDB');

    // Reactive stream sanity: watch emits current state.
    final emission = await todos.watch().first;
    expect(emission.map((d) => d['id']), isNot(contains(id)));
  });

  testWidgets('per-user isolation: another user cannot see the data',
      (tester) async {
    final runId = DateTime.now().millisecondsSinceEpoch;

    // User A writes a doc.
    final tokenA = await fetchDevToken('alice-$runId@test.dev');
    final dirA = Directory.systemTemp.createTempSync('onebase_e2e_a');
    await Onebase.init(
      OnebaseConfig(
        apiUrl: AppConfig.apiUrl,
        tokenProvider: TokenProvider.static(tokenA),
        schema: onebaseSchema,
      ),
      databasePath: '${dirA.path}/a.db',
    );
    await Onebase.instance
        .waitForFirstSync()
        .timeout(const Duration(seconds: 30));
    final secret = 'alice secret $runId';
    await Onebase.collection('todos').insert({
      'title': secret,
      'done': false,
      'created_at': DateTime.now(),
    });
    await waitForUpload();
    expect((await roundTrip()).map((d) => d['title']), contains(secret));
    await Onebase.close();

    // User B syncs and must not receive it.
    final tokenB = await fetchDevToken('bob-$runId@test.dev');
    final dirB = Directory.systemTemp.createTempSync('onebase_e2e_b');
    await Onebase.init(
      OnebaseConfig(
        apiUrl: AppConfig.apiUrl,
        tokenProvider: TokenProvider.static(tokenB),
        schema: onebaseSchema,
      ),
      databasePath: '${dirB.path}/b.db',
    );
    addTearDown(Onebase.close);
    await Onebase.instance
        .waitForFirstSync()
        .timeout(const Duration(seconds: 30));
    final bobSees = await Onebase.collection('todos').find();
    expect(bobSees.map((d) => d['title']), isNot(contains(secret)),
        reason: 'sync streams must isolate per user (server-side)');
  });
}

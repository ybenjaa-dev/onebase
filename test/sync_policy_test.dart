import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:onebase/src/cli/templates/backend_core.dart';
import 'package:onebase/src/errors.dart';
import 'package:onebase/src/schema/schema.dart';
import 'package:onebase/src/schema/schema_parser.dart';
import 'package:onebase/src/store/local_store.dart';
import 'package:sqlite_async/sqlite_async.dart';

void main() {
  group('parsing', () {
    test('defaults to syncing everything', () {
      final schema = parseSchemaYaml('''
collections:
  todos:
    shared: true
    fields:
      title: text!
''');
      final policy = schema.collection('todos').sync;
      expect(policy.mode, SyncMode.full);
      expect(policy.isRemoteOnly, isFalse);
    });

    test('`sync: none` keeps a collection off the device', () {
      final schema = parseSchemaYaml('''
collections:
  audit_log:
    shared: true
    sync: none
    fields:
      message: text!
''');
      expect(schema.collection('audit_log').sync.isRemoteOnly, isTrue);
    });

    test('a window is parsed with its field and duration', () {
      final schema = parseSchemaYaml('''
collections:
  messages:
    shared: true
    sync:
      window: 90d
      field: created_at
    fields:
      body: text!
      created_at: datetime
''');
      final policy = schema.collection('messages').sync;
      expect(policy.mode, SyncMode.window);
      expect(policy.window, const Duration(days: 90));
      expect(policy.field, 'created_at');
    });

    test('accepts hours and minutes too', () {
      for (final (text, expected) in [
        ('12h', Duration(hours: 12)),
        ('30m', Duration(minutes: 30)),
        ('7d', Duration(days: 7)),
      ]) {
        final schema = parseSchemaYaml('''
collections:
  messages:
    shared: true
    sync: {window: $text, field: created_at}
    fields:
      created_at: datetime
''');
        expect(schema.collection('messages').sync.window, expected);
      }
    });

    test('a window needs a real datetime field', () {
      // Measuring a window against text would silently sync nothing.
      expect(
        () => parseSchemaYaml('''
collections:
  messages:
    shared: true
    sync: {window: 90d, field: body}
    fields:
      body: text!
'''),
        throwsA(isA<SchemaParseException>()),
      );

      expect(
        () => parseSchemaYaml('''
collections:
  messages:
    shared: true
    sync: {window: 90d, field: missing}
    fields:
      body: text!
'''),
        throwsA(isA<SchemaParseException>()),
      );
    });

    test('rejects a malformed duration and unknown options', () {
      for (final sync in ['{window: soon, field: created_at}', '{nope: 1}']) {
        expect(
          () => parseSchemaYaml('''
collections:
  messages:
    shared: true
    sync: $sync
    fields:
      created_at: datetime
'''),
          throwsA(isA<SchemaParseException>()),
          reason: sync,
        );
      }
    });
  });

  group('local storage', () {
    late Directory dir;
    late SqliteDatabase db;

    setUp(() async {
      dir = Directory.systemTemp.createTempSync('onebase_sync_policy');
      db = SqliteDatabase(path: '${dir.path}/test.db');
      await db.initialize();
    });

    tearDown(() async {
      await db.close();
      dir.deleteSync(recursive: true);
    });

    test('no table is created for a collection that is not synced', () async {
      final schema = parseSchemaYaml('''
collections:
  todos:
    shared: true
    fields:
      title: text!

  audit_log:
    shared: true
    sync: none
    fields:
      message: text!
''');
      await LocalStore(db, schema).migrate();

      final tables = {
        for (final row in await db.getAll(
          "SELECT name FROM sqlite_master WHERE type = 'table'",
        ))
          row['name'] as String,
      };
      expect(tables, contains('todos'));
      expect(
        tables,
        isNot(contains('audit_log')),
        reason: 'an unsynced collection costs the device nothing',
      );
    });
  });

  group('generated backend', () {
    test('carries the policy so the server enforces it', () {
      final schema = parseSchemaYaml('''
collections:
  messages:
    shared: true
    sync: {window: 90d, field: created_at}
    fields:
      body: text!
      created_at: datetime

  audit_log:
    shared: true
    sync: none
    fields:
      message: text!
''');
      final spec = buildCollectionsTs(schema);
      expect(
        spec,
        contains('"windowMs": ${const Duration(days: 90).inMilliseconds}'),
      );
      expect(spec, contains('"field": "created_at"'));
      expect(spec, contains('"mode": "none"'));
    });

    test('a full collection carries no policy, keeping the spec small', () {
      final schema = parseSchemaYaml('''
collections:
  todos:
    shared: true
    fields:
      title: text!
''');
      expect(buildCollectionsTs(schema), isNot(contains('"sync"')));
    });
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:mongo_easy/src/cli/generate_dart_schema.dart';
import 'package:mongo_easy/src/cli/templates/backend_core.dart';
import 'package:mongo_easy/src/cli/templates/platforms.dart';
import 'package:mongo_easy/src/cli/wizard.dart';
import 'package:mongo_easy/src/schema/schema_parser.dart';

void main() {
  final schema = parseSchemaYaml('''
collections:
  todos:
    owner_field: owner_id
    fields:
      title: text
      done: bool
      due_at: datetime
      meta: json
      owner_id: text
  categories:
    shared: true
    fields:
      name: text
''');

  group('Dart schema codegen', () {
    test('mirrors the YAML schema', () {
      final dart = generateDartSchema(schema);
      expect(dart, contains("import 'package:mongo_easy/mongo_easy.dart';"));
      expect(dart, contains("MongoCollectionSchema(\n    'todos',"));
      expect(dart, contains("'done': MongoFieldType.bool,"));
      expect(dart, contains("'due_at': MongoFieldType.datetime,"));
      expect(dart, contains("ownerField: 'owner_id',"));
      expect(dart, contains('shared: true,'));
      expect(dart, contains('final mongoEasySchema = MongoEasySchema(['));
    });

    test('round-trips: generated code declares every field', () {
      final dart = generateDartSchema(schema);
      for (final collection in schema.collections.values) {
        for (final field in collection.fields.keys) {
          expect(dart, contains("'$field': MongoFieldType."));
        }
      }
    });
  });

  group('backend COLLECTIONS spec', () {
    test('embeds owner fields and field types', () {
      final ts = buildCollectionsTs(schema);
      expect(ts, contains('"ownerField": "owner_id"'));
      expect(ts, contains('"done": "bool"'));
      expect(ts, contains('"meta": "json"'));
      expect(ts, contains('"categories"'));
    });

    test('shared collections have no ownerField key', () {
      final ts = buildCollectionsTs(schema);
      final categories = ts.substring(ts.indexOf('"categories"'));
      expect(categories, isNot(contains('ownerField')));
    });
  });

  group('backend templates', () {
    test('core is complete and placeholders resolved', () {
      final files = generateBackendFiles(schema);
      final all = files.values.join('\n');
      expect(all, isNot(contains('__COLLECTIONS__')));
      expect(all, isNot(contains('__IMPORTS__')));
      expect(all, contains('handlePush'));
      expect(all, contains('handlePull'));
      expect(all, contains('handleToken'));
      expect(all, contains('jwtVerify'));
      expect(all, contains('upsert: true'));
      expect(files.keys, contains('README.md'));
    });

    test('ships one backend that runs on Node, Docker and Vercel', () {
      final files = generateBackendFiles(schema);
      expect(
          files.keys,
          containsAll(<String>[
            'src/core.ts',
            'src/router.ts',
            'src/server.ts',
            'api/index.ts',
            'Dockerfile',
            'package.json',
            '.env.example',
          ]));
      // Routing lives in one place so every host adapter stays trivial.
      expect(files['src/router.ts'], contains("case '/push':"));
      expect(files['src/router.ts'], contains("case '/pull':"));
      expect(files['src/router.ts'], contains("case '/health':"));
    });

    test('pull is owner-scoped and paged', () {
      final core = generateBackendFiles(schema)['src/core.ts']!;
      expect(core, contains('const scope: Record<string, unknown> = owner'));
      expect(core, contains('.limit(PULL_LIMIT)'));
      expect(core, contains('has_more'));
    });

    test('deletes are recorded as tombstones with a TTL', () {
      final core = generateBackendFiles(schema)['src/core.ts']!;
      expect(core, contains('TOMBSTONES'));
      expect(core, contains('expireAfterSeconds: TOMBSTONE_TTL_SECONDS'));
      expect(core, contains('_deleted: true'));
    });

    test('sync indexes are created automatically', () {
      final core = generateBackendFiles(schema)['src/core.ts']!;
      expect(core, contains('createIndex'));
      expect(core, contains("name: 'mongo_easy_sync'"));
    });

    test('ownership is enforced server-side in the core', () {
      final core = generateBackendFiles(schema)['src/core.ts']!;
      expect(core, contains('doc[owner] = userId'));
      expect(core, contains('delete changes[owner]'));
      expect(core, contains('[owner]: userId'));
    });

    test('AUTH_MODE has no default and is validated', () {
      final core = generateBackendFiles(schema)['src/core.ts']!;
      // A forgotten env var must not silently enable the dev token endpoint.
      expect(core, isNot(contains("get('AUTH_MODE') ?? 'dev'")));
      expect(core, contains('Missing required env var: AUTH_MODE'));
      expect(core, contains('AUTH_MODES.includes(authMode)'));
      expect(core, contains(r"['dev', 'hs256', 'jwks']"));
    });

    test('jwks mode requires an https JWKS_URL and an audience', () {
      final core = generateBackendFiles(schema)['src/core.ts']!;
      expect(core, contains('AUTH_MODE=jwks requires JWKS_URL.'));
      expect(core, contains('JWKS_URL must be https'));
      expect(core, contains('AUTH_MODE=jwks requires JWT_AUDIENCE'));
    });

    test('token verification pins algorithms and honours the issuer', () {
      final core = generateBackendFiles(schema)['src/core.ts']!;
      expect(core, contains("const SYMMETRIC_ALGORITHMS = ['HS256'];"));
      expect(core, contains('algorithms: ASYMMETRIC_ALGORITHMS'));
      expect(core, contains('algorithms: SYMMETRIC_ALGORITHMS'));
      expect(core, contains('options.issuer = env.JWT_ISSUER'));
      expect(core, contains('MIN_SECRET_LENGTH'));
    });

    test('only declared fields are written (no mass assignment)', () {
      final core = generateBackendFiles(schema)['src/core.ts']!;
      expect(core, contains('const type = spec.fields[key];'));
      expect(core, contains('if (type === undefined) {'));
      expect(core, contains('dropped.push(key)'));
    });

    test('put merges instead of replacing, so server fields survive', () {
      final core = generateBackendFiles(schema)['src/core.ts']!;
      expect(core, isNot(contains('collection.replaceOne')));
      expect(core, contains(r'$setOnInsert'));
      expect(core, contains('upsert: true'));
    });

    test('ops are applied in a transaction with a documented fallback', () {
      final core = generateBackendFiles(schema)['src/core.ts']!;
      expect(core, contains('session.withTransaction'));
      expect(core, contains('isTransactionUnsupportedError'));
      expect(core, contains('transactionsSupported = false'));
    });

    test('malformed ops are rejected before reaching MongoDB', () {
      final core = generateBackendFiles(schema)['src/core.ts']!;
      expect(core, contains('function parseOp('));
      expect(core, contains('malformed op'));
    });

    test('every host adapter validates config through readEnv', () {
      final files = generateBackendFiles(schema);
      expect(files['src/router.ts'], contains('readEnv(get)'));
      expect(files['api/index.ts'], contains('loadEnv'));
      expect(files['src/server.ts'], contains('loadEnv'));
    });
  });

  group('buildSetupFiles', () {
    test('assembles the dart schema and backend under one root', () {
      final setup = buildSetupFiles(schema);
      expect(
          setup.files.keys,
          containsAll(<String>[
            'lib/mongo_easy_schema.g.dart',
            'backend/src/core.ts',
            'backend/src/server.ts',
            'backend/Dockerfile',
            'backend/README.md',
          ]));
      // No PowerSync artefacts remain.
      expect(setup.files.keys.where((k) => k.contains('powersync')), isEmpty);
    });
  });
}

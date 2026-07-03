import 'package:flutter_test/flutter_test.dart';
import 'package:mongo_easy/src/cli/generate_dart_schema.dart';
import 'package:mongo_easy/src/cli/generate_streams.dart';
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

  group('sync streams YAML', () {
    test('per-user collections filter on auth.user_id()', () {
      final yaml = generateSyncStreamsYaml(schema);
      expect(yaml, contains('edition: 3'));
      expect(
          yaml,
          contains('query: SELECT *, _id as id FROM todos '
              'WHERE owner_id = auth.user_id()'));
    });

    test('shared collections have no user filter', () {
      final yaml = generateSyncStreamsYaml(schema);
      expect(yaml, contains('query: SELECT *, _id as id FROM categories\n'));
      expect(yaml, isNot(contains('categories WHERE')));
    });

    test('streams auto-subscribe', () {
      expect(generateSyncStreamsYaml(schema), contains('auto_subscribe: true'));
    });
  });

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
    for (final target in BackendTarget.values) {
      test('${target.id}: core is complete and placeholders resolved', () {
        final files = generateBackendFiles(schema, target);
        final all = files.values.join('\n');
        expect(all, isNot(contains('__COLLECTIONS__')));
        expect(all, isNot(contains('__IMPORTS__')));
        expect(all, contains('handleUpload'));
        expect(all, contains('handleToken'));
        expect(all, contains('jwtVerify'));
        expect(all, contains('replaceOne'));
        expect(files.keys, contains('README.md'));
      });
    }

    test('vercel uses node-style imports, supabase uses npm: specifiers', () {
      expect(generateBackendFiles(schema, BackendTarget.vercel)['lib/core.ts'],
          contains("from 'mongodb'"));
      expect(
          generateBackendFiles(
              schema, BackendTarget.supabase)['functions/_shared/core.ts'],
          contains("from 'npm:mongodb@6'"));
    });

    test('ownership is enforced server-side in the core', () {
      final core =
          generateBackendFiles(schema, BackendTarget.vercel)['lib/core.ts']!;
      expect(core, contains('doc[owner] = userId'));
      expect(core, contains('delete changes[owner]'));
      expect(core, contains('[owner]: userId'));
    });
  });

  group('buildSetupFiles', () {
    test('assembles streams, dart schema and backend under one root', () {
      final setup = buildSetupFiles(schema, BackendTarget.vercel);
      expect(
          setup.files.keys,
          containsAll(<String>[
            'powersync/sync-streams.yaml',
            'lib/mongo_easy_schema.g.dart',
            'backend/vercel/lib/core.ts',
            'backend/vercel/api/upload.ts',
            'backend/vercel/README.md',
          ]));
    });
  });
}

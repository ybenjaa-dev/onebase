import 'dart:io';

import 'package:args/args.dart';
import 'package:path/path.dart' as p;

import '../errors.dart';
import '../schema/schema.dart';
import '../schema/schema_parser.dart';
import 'doctor.dart';
import 'generate_dart_schema.dart';
import 'templates/platforms.dart';

const _starterYaml = '''
# onebase schema — the single source of truth for your collections.
# After editing, re-run:  dart run onebase:setup
#
# Field types: text, int, double, bool, datetime, json
# Per-user collections need owner_field (filled automatically on insert).
# Public/shared collections set `shared: true` instead.

collections:
  todos:
    owner_field: owner_id
    fields:
      title: text!        # trailing ! = required (non-nullable in Dart)
      done: bool!
      created_at: datetime
      owner_id: text

# File storage (optional). Delete this section if your app stores no files.
# `private` means each user only ever sees their own files.
# storage:
#   avatars:
#     access: private
#     max_size: 5MB
#     content_types: [image/*]
''';

/// Everything `dart run onebase:setup` generates, before touching disk.
class SetupOutput {
  SetupOutput(this.files);

  /// Relative path (from the project root) → content.
  final Map<String, String> files;
}

/// Assembles all generated files for [schema]. Pure — used by tests.
SetupOutput buildSetupFiles(OnebaseSchema schema) {
  final files = <String, String>{
    'lib/onebase_schema.g.dart': generateDartSchema(schema),
  };
  generateBackendFiles(schema).forEach((path, content) {
    files['backend/$path'] = content;
  });
  return SetupOutput(files);
}

/// Entry point for `dart run onebase:setup`.
Future<int> runSetup(List<String> arguments, {StringSink? output}) async {
  final out = output ?? stdout;
  final parser = ArgParser()
    ..addOption(
      'schema',
      abbr: 's',
      defaultsTo: 'onebase.yaml',
      help: 'Path to the schema file.',
    )
    ..addOption(
      'out',
      abbr: 'o',
      defaultsTo: '.',
      help: 'Project root to write into.',
    )
    ..addFlag(
      'init',
      negatable: false,
      help: 'Create a starter onebase.yaml and exit.',
    )
    ..addFlag(
      'doctor',
      negatable: false,
      help:
          'Diagnose the project: schema drift, backend configuration, '
          'and (with --api-url) whether the backend answers.',
    )
    ..addOption('api-url', help: '[--doctor] Backend root URL to health-check.')
    ..addFlag(
      'force',
      negatable: false,
      help: 'Overwrite existing generated files.',
    )
    ..addFlag('help', abbr: 'h', negatable: false);

  final ArgResults args;
  try {
    args = parser.parse(arguments);
  } on FormatException catch (error) {
    out
      ..writeln(error.message)
      ..writeln(parser.usage);
    return 64;
  }

  if (args['help'] as bool) {
    out
      ..writeln('onebase setup — generates typed models, the Dart schema')
      ..writeln('and your backend from onebase.yaml.\n')
      ..writeln('  --init     create a starter onebase.yaml')
      ..writeln('  --doctor   diagnose an existing project\n')
      ..writeln(parser.usage);
    return 0;
  }

  final root = args['out'] as String;
  final schemaPath = p.join(root, args['schema'] as String);

  if (args['init'] as bool) {
    return _init(schemaPath, out, force: args['force'] as bool);
  }

  if (args['doctor'] as bool) {
    final findings = await diagnose(
      root: root,
      schemaFile: args['schema'] as String,
      apiUrl: args['api-url'] as String?,
    );
    return reportDiagnosis(findings, out);
  }

  final file = File(schemaPath);
  if (!file.existsSync()) {
    out
      ..writeln('No schema found at $schemaPath.')
      ..writeln('Create one with:  dart run onebase:setup --init');
    return 66;
  }

  final OnebaseSchema schema;
  try {
    schema = parseSchemaYaml(file.readAsStringSync());
  } on OnebaseException catch (error) {
    out.writeln(error.toString());
    return 65;
  }

  final setup = buildSetupFiles(schema);
  final force = args['force'] as bool;
  for (final MapEntry(key: path, value: content) in setup.files.entries) {
    final target = File(p.join(root, path));
    if (target.existsSync() && !force && !path.endsWith('.g.dart')) {
      out.writeln('• skipped $path (exists — pass --force to overwrite)');
      continue;
    }
    target
      ..createSync(recursive: true)
      ..writeAsStringSync(content);
    out.writeln('✓ $path');
  }

  _printNextSteps(out, schema);
  return 0;
}

int _init(String schemaPath, StringSink out, {required bool force}) {
  final file = File(schemaPath);
  if (file.existsSync() && !force) {
    out.writeln('$schemaPath already exists. Pass --force to overwrite.');
    return 1;
  }
  file
    ..createSync(recursive: true)
    ..writeAsStringSync(_starterYaml);
  out
    ..writeln('✓ Created $schemaPath')
    ..writeln()
    ..writeln('Edit it to describe your collections, then run:')
    ..writeln('  dart run onebase:setup');
  return 0;
}

void _printNextSteps(StringSink out, OnebaseSchema schema) {
  final collections = schema.collections.keys.join(', ');
  out
    ..writeln()
    ..writeln('Generated the schema for: $collections')
    ..writeln()
    ..writeln('Next:')
    ..writeln('1. Configure the backend:')
    ..writeln('       cd backend && cp .env.example .env')
    ..writeln('   Set MONGO_URI, MONGO_DB and AUTH_MODE (no default —')
    ..writeln('   use dev to start, jwks or hs256 for production).')
    ..writeln('2. Deploy it anywhere Node or Docker runs:')
    ..writeln(
      '       docker build -t my-backend . && docker run -p 3000:3000 \\',
    )
    ..writeln('         --env-file .env my-backend')
    ..writeln('   …or `npx vercel deploy --prod` — the adapter is included.')
    ..writeln('3. Point your app at it:')
    ..writeln('       await Onebase.init(OnebaseConfig(')
    ..writeln("         apiUrl: 'https://<your-backend>',")
    ..writeln('         tokenProvider: TokenProvider(() async => /* JWT */),')
    ..writeln('         schema: onebaseSchema,')
    ..writeln('       ));')
    ..writeln()
    ..writeln('See backend/README.md for the full configuration table.');
}

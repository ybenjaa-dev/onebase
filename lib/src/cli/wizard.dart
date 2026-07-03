import 'dart:io';
import 'dart:math';

import 'package:args/args.dart';
import 'package:path/path.dart' as p;

import '../errors.dart';
import '../schema/schema.dart';
import '../schema/schema_parser.dart';
import 'auto_cloud.dart';
import 'generate_dart_schema.dart';
import 'generate_endpoints.dart';
import 'generate_streams.dart';
import 'mongo_uri.dart';
import 'process_runner.dart';
import 'templates/platforms.dart';
import 'templates/self_host.dart';

const _starterYaml = '''
# mongo_easy schema — the single source of truth for your collections.
# After editing, re-run:  dart run mongo_easy:setup
#
# Field types: text, int, double, bool, datetime, json
# Per-user collections need owner_field (filled automatically on insert).
# Public/shared collections set `shared: true` instead.

collections:
  todos:
    owner_field: owner_id
    fields:
      title: text
      done: bool
      created_at: datetime
      owner_id: text
''';

/// Everything `dart run mongo_easy:setup` generates, before touching disk.
class SetupOutput {
  SetupOutput(this.files, this.target);

  /// Relative path (from the project root) → content.
  final Map<String, String> files;
  final BackendTarget target;
}

/// Assembles all generated files for [schema]. Pure — used by tests.
SetupOutput buildSetupFiles(MongoEasySchema schema, BackendTarget target) {
  final files = <String, String>{
    'powersync/sync-streams.yaml': generateSyncStreamsYaml(schema),
    'lib/mongo_easy_schema.g.dart': generateDartSchema(schema),
  };
  generateBackendFiles(schema, target).forEach((path, content) {
    files['backend/${target.id}/$path'] = content;
  });
  return SetupOutput(files, target);
}

/// Entry point for `dart run mongo_easy:setup`.
Future<int> runSetup(List<String> arguments,
    {Stdin? input, StringSink? output, ProcessRunner? processRunner}) async {
  final out = output ?? stdout;
  final parser = ArgParser()
    ..addOption('schema',
        abbr: 's',
        defaultsTo: 'mongo_easy.yaml',
        help: 'Path to the schema file.')
    ..addOption('out',
        abbr: 'o', defaultsTo: '.', help: 'Project root to write into.')
    ..addOption('target',
        abbr: 't',
        allowed: [for (final t in BackendTarget.values) t.id],
        help: 'Backend deploy target (prompts when omitted).')
    ..addFlag('auto',
        negatable: false,
        help: 'Provision everything automatically: PowerSync Cloud instance '
            '+ sync streams + Vercel backend, from --mongo-uri. Needs '
            'PS_ADMIN_TOKEN and a logged-in Vercel CLI.')
    ..addFlag('self-host',
        negatable: false,
        help: 'Generate a docker-compose deployment (PowerSync service + '
            'backend) wired to --mongo-uri. No third-party accounts.')
    ..addOption('mongo-uri',
        help: 'MongoDB connection string (Atlas → Connect → Drivers).')
    ..addOption('mongo-db',
        help: 'Database name (defaults to the one in --mongo-uri).')
    ..addOption('project-id',
        help: '[--auto] PowerSync project id (auto-detected when the '
            'account has exactly one).')
    ..addOption('org-id', help: '[--auto] PowerSync organization id.')
    ..addOption('name',
        defaultsTo: 'mongo-easy',
        help: '[--auto] Name for the PowerSync instance.')
    ..addFlag('init',
        negatable: false, help: 'Create a starter mongo_easy.yaml and exit.')
    ..addFlag('force',
        negatable: false, help: 'Overwrite existing generated files.')
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
      ..writeln('mongo_easy setup — generates PowerSync sync streams, the')
      ..writeln('Dart schema, and a deployable write-upload backend from')
      ..writeln('mongo_easy.yaml.\n')
      ..writeln('One-command modes:')
      ..writeln('  --auto       provision PowerSync Cloud + Vercel from '
          '--mongo-uri')
      ..writeln('  --self-host  generate a docker-compose deployment from '
          '--mongo-uri\n')
      ..writeln(parser.usage);
    return 0;
  }

  final root = args['out'] as String;
  final schemaPath = p.join(root, args['schema'] as String);
  final schemaFile = File(schemaPath);

  if (args['init'] as bool) {
    if (schemaFile.existsSync() && !(args['force'] as bool)) {
      out.writeln('✗ $schemaPath already exists (use --force to overwrite).');
      return 1;
    }
    schemaFile
      ..createSync(recursive: true)
      ..writeAsStringSync(_starterYaml);
    out
      ..writeln('✓ Created $schemaPath')
      ..writeln()
      ..writeln('Edit it to describe your collections, then run:')
      ..writeln('  dart run mongo_easy:setup');
    return 0;
  }

  if (!schemaFile.existsSync()) {
    out
      ..writeln('✗ No schema found at $schemaPath.')
      ..writeln()
      ..writeln('Create a starter schema with:')
      ..writeln('  dart run mongo_easy:setup --init');
    return 1;
  }

  final MongoEasySchema schema;
  try {
    schema = parseSchemaYaml(schemaFile.readAsStringSync());
  } on SchemaParseException catch (error) {
    out.writeln('✗ ${error.message}');
    if (error.hint != null) out.writeln('  ${error.hint}');
    return 1;
  }

  out
    ..writeln('mongo_easy setup')
    ..writeln('────────────────')
    ..writeln('Schema: $schemaPath — '
        '${schema.collections.length} collection(s): '
        '${schema.collections.keys.join(', ')}')
    ..writeln();

  final auto = args['auto'] as bool;
  final selfHost = args['self-host'] as bool;
  if (auto && selfHost) {
    out.writeln('✗ --auto and --self-host are mutually exclusive.');
    return 64;
  }

  if (selfHost) {
    return _runSelfHost(args, schema, root, input ?? stdin, out);
  }

  final target = auto
      ? BackendTarget.vercel
      : _resolveTarget(args['target'] as String?, input ?? stdin, out);
  if (target == null) return 1;

  _writeSetupFiles(buildSetupFiles(schema, target), root,
      force: args['force'] as bool, out: out);

  if (auto) {
    return _runAutoCloud(args, schema, root, input ?? stdin, out,
        processRunner ?? const SystemProcessRunner());
  }

  _printNextSteps(out, target, schema);
  return 0;
}

void _writeSetupFiles(SetupOutput setup, String root,
    {required bool force, required StringSink out}) {
  for (final MapEntry(key: path, value: content) in setup.files.entries) {
    File(p.join(root, path))
      ..createSync(recursive: true)
      ..writeAsStringSync(content);
    out.writeln('✓ $path');
  }
}

Future<int> _runAutoCloud(ArgResults args, MongoEasySchema schema, String root,
    Stdin input, StringSink out, ProcessRunner runner) async {
  final MongoUriInfo mongo;
  final String mongoDb;
  try {
    mongo = parseMongoUri(
        _requireMongoUri(args['mongo-uri'] as String?, input, out));
    mongoDb = _resolveMongoDb(args['mongo-db'] as String?, mongo);
  } on ConfigurationException catch (error) {
    out.writeln('✗ ${error.message}');
    if (error.hint != null) out.writeln('  ${error.hint}');
    return 1;
  }

  final setup = AutoCloudSetup(
    runner: runner,
    out: out,
    root: root,
    schema: schema,
    mongo: mongo,
    mongoDatabase: mongoDb,
    jwtSecret: _persistentSecret(p.join(root, 'powersync-cloud')),
    instanceName: args['name'] as String,
    projectId: args['project-id'] as String?,
    orgId: args['org-id'] as String?,
  );

  final AutoCloudResult result;
  try {
    result = await setup.run();
  } on AutoCloudException catch (error) {
    out.writeln('✗ $error');
    return 1;
  }

  File(p.join(root, 'lib', 'mongo_easy_endpoints.g.dart'))
    ..createSync(recursive: true)
    ..writeAsStringSync(generateEndpointsDart(
      powersyncUrl: result.powersyncUrl,
      uploadUrl: result.uploadUrl,
      tokenUrl: result.tokenUrl,
    ));
  out
    ..writeln('✓ lib/mongo_easy_endpoints.g.dart written')
    ..writeln()
    ..writeln('Done — your backend is live. In the app:')
    ..writeln()
    ..writeln('  await MongoEasy.init(MongoEasyConfig(')
    ..writeln('    powersyncUrl: MongoEasyEndpoints.powersyncUrl,')
    ..writeln('    uploadUrl: MongoEasyEndpoints.uploadUrl,')
    ..writeln('    tokenProvider: TokenProvider(() async => /* JWT */),')
    ..writeln('    schema: mongoEasySchema,')
    ..writeln('  ));')
    ..writeln()
    ..writeln('Dev login: POST ${result.tokenUrl} {"email": "..."}')
    ..writeln('Production: switch AUTH_MODE=jwks — see the README.');
  return 0;
}

Future<int> _runSelfHost(ArgResults args, MongoEasySchema schema, String root,
    Stdin input, StringSink out) async {
  final MongoUriInfo mongo;
  final String mongoDb;
  try {
    mongo = parseMongoUri(
        _requireMongoUri(args['mongo-uri'] as String?, input, out));
    mongoDb = _resolveMongoDb(args['mongo-db'] as String?, mongo);
  } on ConfigurationException catch (error) {
    out.writeln('✗ ${error.message}');
    if (error.hint != null) out.writeln('  ${error.hint}');
    return 1;
  }

  // Base artifacts (Dart schema for the app; streams for reference).
  File(p.join(root, 'lib', 'mongo_easy_schema.g.dart'))
    ..createSync(recursive: true)
    ..writeAsStringSync(generateDartSchema(schema));
  out.writeln('✓ lib/mongo_easy_schema.g.dart');

  final deployDir = p.join(root, 'deploy', 'self-host');
  final envFile = File(p.join(deployDir, '.env'));
  final existingSecret = envFile.existsSync()
      ? RegExp('^JWT_SECRET=(.+)\$', multiLine: true)
          .firstMatch(envFile.readAsStringSync())
          ?.group(1)
      : null;

  final files = generateSelfHostFiles(
    schema,
    mongoUri: mongo.uri,
    mongoDatabase: mongoDb,
    storageUri: mongo.withDatabase('powersync_storage'),
    jwtSecret: existingSecret ?? _randomSecret(),
  );
  for (final MapEntry(key: path, value: content) in files.entries) {
    File(p.join(deployDir, path))
      ..createSync(recursive: true)
      ..writeAsStringSync(content);
    out.writeln('✓ deploy/self-host/$path');
  }

  File(p.join(root, 'lib', 'mongo_easy_endpoints.g.dart'))
    ..createSync(recursive: true)
    ..writeAsStringSync(generateEndpointsDart(
      powersyncUrl: 'http://localhost:8080',
      uploadUrl: 'http://localhost:3300/upload',
      tokenUrl: 'http://localhost:3300/token',
    ));
  out
    ..writeln('✓ lib/mongo_easy_endpoints.g.dart (localhost — edit for your '
        'server)')
    ..writeln()
    ..writeln('Start the whole backend:')
    ..writeln('  cd deploy/self-host && docker compose up -d')
    ..writeln()
    ..writeln('⚠ deploy/self-host/.env contains your MongoDB credentials —')
    ..writeln('  add it to .gitignore.')
    ..writeln('Requires MongoDB 6.0+ as a replica set (all Atlas tiers '
        'qualify).');
  return 0;
}

String _requireMongoUri(String? flag, Stdin input, StringSink out) {
  if (flag != null && flag.trim().isNotEmpty) return flag;
  out.write('MongoDB connection string (mongodb+srv://…): ');
  final line = input.readLineSync()?.trim() ?? '';
  if (line.isEmpty) {
    throw const ConfigurationException('A MongoDB connection string is '
        'required for this mode (--mongo-uri).');
  }
  return line;
}

String _resolveMongoDb(String? flag, MongoUriInfo mongo) {
  final db = flag ?? mongo.database;
  if (db == null || db.isEmpty) {
    throw const ConfigurationException(
      'No database name found.',
      hint: 'Add it to the connection string '
          '(…mongodb.net/MYDB?…) or pass --mongo-db=MYDB.',
    );
  }
  return db;
}

/// Generates once, then reuses — rotating the secret on every run would
/// invalidate outstanding dev tokens and desync PowerSync vs the backend.
String _persistentSecret(String dir) {
  final file = File(p.join(dir, '.jwt-secret'));
  if (file.existsSync()) {
    final existing = file.readAsStringSync().trim();
    if (existing.length >= 32) return existing;
  }
  final secret = _randomSecret();
  file
    ..createSync(recursive: true)
    ..writeAsStringSync(secret);
  return secret;
}

BackendTarget? _resolveTarget(String? flag, Stdin input, StringSink out) {
  if (flag != null) {
    return BackendTarget.values.firstWhere((t) => t.id == flag);
  }

  out.writeln('Where will you deploy the write-upload backend?');
  for (final (index, target) in BackendTarget.values.indexed) {
    out.writeln('  ${index + 1}) ${target.label}');
  }
  out.write('Choose [1-${BackendTarget.values.length}] (default 1): ');

  final line = input.readLineSync()?.trim() ?? '';
  if (line.isEmpty) return BackendTarget.values.first;
  final choice = int.tryParse(line);
  if (choice == null || choice < 1 || choice > BackendTarget.values.length) {
    out.writeln('✗ Invalid choice "$line".');
    return null;
  }
  return BackendTarget.values[choice - 1];
}

void _printNextSteps(
    StringSink out, BackendTarget target, MongoEasySchema schema) {
  final secret = _randomSecret();
  final deployCommand = switch (target) {
    BackendTarget.vercel =>
      'cd backend/vercel && npm install && npx vercel deploy --prod',
    BackendTarget.supabase => 'cd backend/supabase && '
        'supabase functions deploy upload --no-verify-jwt && '
        'supabase functions deploy token --no-verify-jwt',
    BackendTarget.cloudflare =>
      'cd backend/cloudflare && npm install && npx wrangler deploy',
  };

  out
    ..writeln()
    ..writeln('Next steps (≈10 minutes) — or do it all in one command:')
    ..writeln('  dart run mongo_easy:setup --auto --mongo-uri "<uri>"')
    ..writeln('────────────────────────')
    ..writeln('1. MongoDB Atlas (free M0): https://www.mongodb.com/cloud/atlas')
    ..writeln('   • Create a cluster + database, and a database user with')
    ..writeln('     read/write access. MongoDB 6.0+ is required.')
    ..writeln(
        '2. PowerSync Cloud (free): https://accounts.journeyapps.com/portal/powersync-signup')
    ..writeln('   • Create an instance → connect it to your Atlas cluster')
    ..writeln('     (Atlas user needs: read on your db, readWrite on')
    ..writeln('     _powersync_checkpoints, dbAdmin for auto post-images).')
    ..writeln('   • Paste powersync/sync-streams.yaml into')
    ..writeln('     Dashboard → Sync Streams and deploy.')
    ..writeln('   • Instance → Client Auth: enable HS256 with this secret')
    ..writeln('     (dev mode):')
    ..writeln('       $secret')
    ..writeln('3. Deploy the backend:')
    ..writeln('       $deployCommand')
    ..writeln('   • Set env vars (see backend/${target.id}/README.md) —')
    ..writeln('     use the SAME JWT_SECRET as step 2, and set')
    ..writeln('     JWT_AUDIENCE to your PowerSync instance URL.')
    ..writeln('4. In your app:')
    ..writeln('       await MongoEasy.init(MongoEasyConfig(')
    ..writeln(
        "         powersyncUrl: 'https://<instance>.powersync.journeyapps.com',")
    ..writeln("         uploadUrl: '<your deployed upload URL>',")
    ..writeln(
        '         tokenProvider: TokenProvider(() async => /* your JWT */),')
    ..writeln(
        '         schema: mongoEasySchema, // lib/mongo_easy_schema.g.dart')
    ..writeln('       ));')
    ..writeln()
    ..writeln('Going to production? Switch AUTH_MODE=jwks and plug in your')
    ..writeln('real auth provider (Supabase/Firebase/Auth0) — see the README.');
}

String _randomSecret() {
  final random = Random.secure();
  const chars =
      'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
  return List.generate(48, (_) => chars[random.nextInt(chars.length)]).join();
}

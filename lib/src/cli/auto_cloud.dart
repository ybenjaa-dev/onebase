import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../schema/schema.dart';
import 'generate_streams.dart';
import 'mongo_uri.dart';
import 'process_runner.dart';

/// Everything the automated cloud setup provisions.
class AutoCloudResult {
  const AutoCloudResult({
    required this.powersyncUrl,
    required this.uploadUrl,
    required this.tokenUrl,
    required this.instanceId,
  });

  final String powersyncUrl;
  final String uploadUrl;
  final String tokenUrl;
  final String instanceId;
}

/// Thrown when a provisioning step fails; [step] tells the user where.
class AutoCloudException implements Exception {
  const AutoCloudException(this.step, this.detail, {this.hint});

  final String step;
  final String detail;
  final String? hint;

  @override
  String toString() =>
      'Setup failed at: $step\n$detail${hint == null ? '' : '\n→ $hint'}';
}

/// Orchestrates PowerSync Cloud (instance + sync streams + HS256 auth) and
/// the backend deploy (Vercel) from a single MongoDB connection string.
///
/// Requires once-off credentials:
/// - `PS_ADMIN_TOKEN` (PowerSync Dashboard → Account Settings → tokens)
/// - a logged-in Vercel CLI (`npx vercel login`)
class AutoCloudSetup {
  AutoCloudSetup({
    required this.runner,
    required this.out,
    required this.root,
    required this.schema,
    required this.mongo,
    required this.mongoDatabase,
    required this.jwtSecret,
    this.instanceName = 'mongo-easy',
    this.projectId,
    this.orgId,
    Map<String, String>? environment,
  }) : environment = environment ?? Platform.environment;

  final ProcessRunner runner;
  final StringSink out;

  /// Project root; the PowerSync CLI config dir is written to
  /// `<root>/powersync-cloud/`.
  final String root;
  final MongoEasySchema schema;
  final MongoUriInfo mongo;
  final String mongoDatabase;
  final String jwtSecret;
  final String instanceName;
  final String? projectId;
  final String? orgId;

  /// Host environment (injectable for tests).
  final Map<String, String> environment;

  Map<String, String> get _psEnv => {
        'PS_MONGO_URI': mongo.withDatabase(mongoDatabase),
        'PS_JWT_K':
            base64Url.encode(utf8.encode(jwtSecret)).replaceAll('=', ''),
      };

  Future<AutoCloudResult> run() async {
    await _checkPrerequisites();
    final configDir = _writePowerSyncConfig();
    final instanceId = await _ensureInstance(configDir);
    await _deployPowerSync(configDir);
    final powersyncUrl = 'https://$instanceId.powersync.journeyapps.com';
    final backendUrl = await _deployBackend(powersyncUrl);
    return AutoCloudResult(
      powersyncUrl: powersyncUrl,
      uploadUrl: '$backendUrl/api/upload',
      tokenUrl: '$backendUrl/api/token',
      instanceId: instanceId,
    );
  }

  Future<void> _checkPrerequisites() async {
    if (!await runner.exists('npx')) {
      throw const AutoCloudException(
        'prerequisites',
        'npx (Node.js) is required to run the PowerSync and Vercel CLIs.',
        hint: 'Install Node.js 20+ from https://nodejs.org, then re-run.',
      );
    }
    if ((environment['PS_ADMIN_TOKEN'] ?? '').isEmpty) {
      throw const AutoCloudException(
        'prerequisites',
        'PS_ADMIN_TOKEN is not set.',
        hint: 'Create a personal access token in the PowerSync Dashboard '
            '(Account Settings → Personal Access Tokens), then:\n'
            '  export PS_ADMIN_TOKEN=<token>',
      );
    }
    final who = await runner.run('npx', ['-y', 'vercel@latest', 'whoami']);
    if (!who.ok) {
      throw const AutoCloudException(
        'prerequisites',
        'The Vercel CLI is not logged in.',
        hint: 'Run `npx vercel login` once, then re-run setup.',
      );
    }
    out.writeln('✓ prerequisites: npx, PS_ADMIN_TOKEN, vercel '
        '(${who.stdout.trim()})');
  }

  /// Writes the PowerSync CLI config directory (service + sync config).
  String _writePowerSyncConfig() {
    final dir = Directory(p.join(root, 'powersync-cloud'))
      ..createSync(recursive: true);

    File(p.join(dir.path, 'service.yaml')).writeAsStringSync('''
name: $instanceName

replication:
  connections:
    - type: mongodb
      uri: !env PS_MONGO_URI
      post_images: auto_configure

client_auth:
  jwks:
    keys:
      - kty: oct
        alg: HS256
        kid: mongo-easy-dev
        k: !env PS_JWT_K
  audience: ["powersync-dev"]
''');

    File(p.join(dir.path, 'sync-config.yaml'))
        .writeAsStringSync(generateSyncStreamsYaml(schema));

    out.writeln('✓ PowerSync config written to powersync-cloud/');
    return dir.path;
  }

  Future<String> _ensureInstance(String configDir) async {
    // Already linked? cli.yaml holds the instance id.
    final cliYaml = File(p.join(configDir, 'cli.yaml'));
    if (cliYaml.existsSync()) {
      final match = RegExp('instance_id:\\s*(\\S+)')
          .firstMatch(cliYaml.readAsStringSync());
      if (match != null) {
        final id = match.group(1)!;
        out.writeln('✓ using already-linked PowerSync instance $id');
        return id;
      }
    }

    final project = projectId ?? await _discoverProjectId();
    final create = await runner.run(
      'npx',
      [
        '-y',
        'powersync@latest',
        'link',
        'cloud',
        '--create',
        '--project-id=$project',
        if (orgId != null) '--org-id=$orgId',
      ],
      workingDirectory: configDir,
      environment: _psEnv,
    );
    if (!create.ok) {
      throw AutoCloudException(
        'create PowerSync instance',
        create.output,
        hint: 'Check the token has access to project $project '
            '(`npx powersync fetch instances`).',
      );
    }

    final match = cliYaml.existsSync()
        ? RegExp('instance_id:\\s*(\\S+)')
            .firstMatch(cliYaml.readAsStringSync())
        : null;
    if (match == null) {
      throw AutoCloudException(
        'create PowerSync instance',
        'Instance created but cli.yaml has no instance_id.\n${create.output}',
      );
    }
    final id = match.group(1)!;
    out.writeln('✓ PowerSync instance created: $id');
    return id;
  }

  /// When --project-id is not passed, use it if the account has exactly one.
  Future<String> _discoverProjectId() async {
    final fetch = await runner.run(
      'npx',
      ['-y', 'powersync@latest', 'fetch', 'instances', '--output=json'],
    );
    if (fetch.ok) {
      final ids = RegExp('"project_id"\\s*:\\s*"([^"]+)"')
          .allMatches(fetch.stdout)
          .map((m) => m.group(1)!)
          .toSet();
      if (ids.length == 1) return ids.first;
    }
    throw AutoCloudException(
      'select PowerSync project',
      fetch.ok
          ? 'Could not determine a unique project automatically.'
          : fetch.output,
      hint: 'Pass it explicitly: --project-id=<id> '
          '(visible in the PowerSync Dashboard URL, or via '
          '`npx powersync fetch instances`).',
    );
  }

  Future<void> _deployPowerSync(String configDir) async {
    final deploy = await runner.run(
      'npx',
      ['-y', 'powersync@latest', 'deploy'],
      workingDirectory: configDir,
      environment: _psEnv,
    );
    if (!deploy.ok) {
      throw AutoCloudException(
        'deploy PowerSync config',
        deploy.output,
        hint: 'The validation error above usually points at service.yaml or '
            'sync-config.yaml in powersync-cloud/. Fix and re-run.',
      );
    }
    out.writeln('✓ sync streams + connection + auth deployed to PowerSync');
  }

  Future<String> _deployBackend(String powersyncUrl) async {
    final backendDir = p.join(root, 'backend', 'vercel');
    if (!Directory(backendDir).existsSync()) {
      throw AutoCloudException(
        'deploy backend',
        'backend/vercel does not exist.',
        hint: 'Run `dart run mongo_easy:setup --target vercel` first '
            '(the --auto flow does this automatically when combined).',
      );
    }

    final envValues = {
      'MONGO_URI': mongo.uri,
      'MONGO_DB': mongoDatabase,
      'AUTH_MODE': 'dev',
      'JWT_SECRET': jwtSecret,
      'JWT_AUDIENCE': 'powersync-dev',
    };

    // First deploy links/creates the Vercel project.
    var deploy = await _vercelDeploy(backendDir);

    for (final MapEntry(:key, :value) in envValues.entries) {
      // Remove any stale value first; `env add` fails on duplicates.
      await runner.run(
        'npx',
        ['-y', 'vercel@latest', 'env', 'rm', key, 'production', '--yes'],
        workingDirectory: backendDir,
      );
      final add = await runner.run(
        'npx',
        ['-y', 'vercel@latest', 'env', 'add', key, 'production'],
        workingDirectory: backendDir,
        stdinText: value,
      );
      if (!add.ok) {
        throw AutoCloudException('set backend env $key', add.output);
      }
    }
    out.writeln('✓ backend env vars set '
        '(${envValues.keys.join(', ')})');

    // Redeploy so the env vars take effect.
    deploy = await _vercelDeploy(backendDir);
    out.writeln('✓ backend deployed: $deploy');
    return deploy;
  }

  Future<String> _vercelDeploy(String backendDir) async {
    final deploy = await runner.run(
      'npx',
      ['-y', 'vercel@latest', 'deploy', '--prod', '--yes'],
      workingDirectory: backendDir,
    );
    if (!deploy.ok) {
      throw AutoCloudException('deploy backend to Vercel', deploy.output,
          hint: 'Run `npx vercel login` and check the output above.');
    }
    final url = RegExp(r'https://\S+\.vercel\.app')
        .allMatches('${deploy.stdout}\n${deploy.stderr}')
        .map((m) => m.group(0)!)
        .lastOrNull;
    if (url == null) {
      throw AutoCloudException(
        'deploy backend to Vercel',
        'Deploy succeeded but no deployment URL was found in the output:\n'
            '${deploy.output}',
      );
    }
    return url;
  }
}

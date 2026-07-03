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

class _PsProject {
  const _PsProject(
      {required this.id, required this.name, required this.instances});

  final String id;
  final String name;
  final List<_PsInstance> instances;
}

class _PsInstance {
  const _PsInstance({required this.id, required this.name});

  final String id;
  final String name;
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
    await _alignServiceConfig(configDir);
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

  /// Writes the PowerSync CLI config directory. The CLI convention is a
  /// `powersync/` folder inside the working directory, holding
  /// `service.yaml`, `sync-config.yaml` and the CLI-managed `cli.yaml`.
  String _writePowerSyncConfig() {
    final workDir = Directory(p.join(root, 'powersync-cloud'))
      ..createSync(recursive: true);
    Directory(p.join(workDir.path, 'powersync')).createSync(recursive: true);

    _writeServiceYaml(workDir.path, name: instanceName, region: 'us');
    File(p.join(workDir.path, 'powersync', 'sync-config.yaml'))
        .writeAsStringSync(generateSyncStreamsYaml(schema));

    out.writeln('✓ PowerSync config written to powersync-cloud/powersync/');
    return workDir.path;
  }

  void _writeServiceYaml(String configDir,
      {required String name, required String region}) {
    File(p.join(configDir, 'powersync', 'service.yaml')).writeAsStringSync('''
_type: cloud
name: $name
region: $region

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
        k:
          secret: !env PS_JWT_K
''');
  }

  /// Instance name and region are immutable server-side facts — when linked
  /// to an existing instance, mirror them so deploy validation passes.
  Future<void> _alignServiceConfig(String configDir) async {
    final fetch = await runner.run(
      'npx',
      ['-y', 'powersync@latest', 'fetch', 'config', '--output=json'],
      workingDirectory: configDir,
      environment: _psEnv,
    );
    if (!fetch.ok) return; // freshly created instance — defaults are correct

    final start = fetch.stdout.indexOf('{');
    if (start == -1) return;
    try {
      final root = jsonDecode(fetch.stdout.substring(start));
      if (root is! Map<String, Object?>) return;
      final config = root['config'];
      if (config is! Map<String, Object?>) return;
      final region = config['region']?.toString();
      final name = config['name']?.toString();
      if (region == null && name == null) return;
      _writeServiceYaml(configDir,
          name: name ?? instanceName, region: region ?? 'us');
      out.writeln(
          '✓ matched existing instance settings (name: $name, region: $region)');
    } on FormatException {
      // Unparseable — keep defaults and let deploy validation report.
    }
  }

  Future<String> _ensureInstance(String configDir) async {
    // Already linked? cli.yaml holds the instance id.
    final cliYaml = File(p.join(configDir, 'powersync', 'cli.yaml'));
    if (cliYaml.existsSync()) {
      final match = RegExp('instance_id:\\s*(\\S+)')
          .firstMatch(cliYaml.readAsStringSync());
      if (match != null) {
        final id = match.group(1)!;
        out.writeln('✓ using already-linked PowerSync instance $id');
        return id;
      }
    }

    final project = await _discoverProject();

    // The dashboard's onboarding wizard often pre-creates instances
    // (Production/Development). Link to one instead of creating a third —
    // prefer "Development" since --auto configures dev-mode auth.
    final List<String> linkArgs;
    final String describe;
    final existing = project.instances;
    if (existing.isNotEmpty) {
      final instance = existing.firstWhere(
        (i) => i.name.toLowerCase() == 'development',
        orElse: () => existing.first,
      );
      linkArgs = ['--instance-id=${instance.id}'];
      describe = 'linked to existing instance "${instance.name}" '
          '(${instance.id})';
    } else {
      linkArgs = [
        '--create',
        '--project-id=${project.id}',
        if (orgId != null) '--org-id=$orgId',
      ];
      describe = 'instance created';
    }

    final link = await runner.run(
      'npx',
      ['-y', 'powersync@latest', 'link', 'cloud', ...linkArgs],
      workingDirectory: configDir,
      environment: _psEnv,
    );
    if (!link.ok) {
      throw AutoCloudException(
        'link PowerSync instance',
        link.output,
        hint: 'Check the token has access to project ${project.id} '
            '(`npx powersync fetch instances`).',
      );
    }

    final match = cliYaml.existsSync()
        ? RegExp('instance_id:\\s*(\\S+)')
            .firstMatch(cliYaml.readAsStringSync())
        : null;
    if (match == null) {
      throw AutoCloudException(
        'link PowerSync instance',
        'Linked but cli.yaml has no instance_id.\n${link.output}',
      );
    }
    final id = match.group(1)!;
    out.writeln('✓ PowerSync $describe');
    return id;
  }

  /// Resolves the target project from `fetch instances` output
  /// (`--project-id` narrows it when the account has several).
  Future<_PsProject> _discoverProject() async {
    final fetch = await runner.run(
      'npx',
      ['-y', 'powersync@latest', 'fetch', 'instances', '--output=json'],
    );
    final projects = fetch.ok ? _parseProjects(fetch.stdout) : <_PsProject>[];

    if (projectId != null) {
      final chosen = projects.where((p) => p.id == projectId).firstOrNull;
      if (chosen != null) return chosen;
      throw AutoCloudException(
        'select PowerSync project',
        'Project $projectId was not found in this account.',
        hint: 'Check `npx powersync fetch instances`.',
      );
    }
    if (projects.length == 1) return projects.single;

    throw AutoCloudException(
      'select PowerSync project',
      !fetch.ok
          ? fetch.output
          : (projects.isEmpty
              ? 'Your PowerSync account has no projects yet.'
              : 'Multiple projects found: '
                  '${projects.map((p) => '${p.name} (${p.id})').join(', ')}.'),
      hint: projects.isEmpty && fetch.ok
          ? 'Create one first at https://dashboard.powersync.com (fresh '
              'accounts start empty), then re-run — it will be picked up '
              'automatically.'
          : 'Pass it explicitly: --project-id=<id>.',
    );
  }

  static List<_PsProject> _parseProjects(String stdout) {
    // The CLI may print progress lines before the JSON.
    final start = stdout.indexOf('{');
    if (start == -1) return const [];
    final Object? root;
    try {
      root = jsonDecode(stdout.substring(start));
    } on FormatException {
      return const [];
    }
    if (root is! Map<String, Object?>) return const [];

    final projects = <_PsProject>[];
    final orgs = root['cloudInstances'];
    if (orgs is! Map<String, Object?>) return const [];
    for (final org in orgs.values) {
      if (org is! Map<String, Object?>) continue;
      final orgProjects = org['projects'];
      if (orgProjects is! Map<String, Object?>) continue;
      for (final MapEntry(key: id, value: project) in orgProjects.entries) {
        if (project is! Map<String, Object?>) continue;
        projects.add(_PsProject(
          id: id,
          name: project['name']?.toString() ?? id,
          instances: [
            if (project['instances'] case final List<Object?> instances)
              for (final instance in instances)
                if (instance is Map<String, Object?>)
                  _PsInstance(
                    id: instance['id']?.toString() ?? '',
                    name: instance['name']?.toString() ?? '',
                  ),
          ],
        ));
      }
    }
    return projects;
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
      // PowerSync Cloud only accepts its own instance URL as the JWT
      // audience (custom audiences in client_auth are not applied there),
      // so dev tokens must be stamped with it.
      'JWT_AUDIENCE': powersyncUrl,
    };

    // Link with an explicit project name (otherwise Vercel names the
    // project after the directory, i.e. "vercel").
    await runner.run(
      'npx',
      [
        '-y',
        'vercel@latest',
        'link',
        '--yes',
        '--project',
        '$instanceName-backend',
      ],
      workingDirectory: backendDir,
    );

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

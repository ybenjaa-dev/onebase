import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mongo_easy/src/cli/auto_cloud.dart';
import 'package:mongo_easy/src/cli/generate_endpoints.dart';
import 'package:mongo_easy/src/cli/mongo_uri.dart';
import 'package:mongo_easy/src/cli/process_runner.dart';
import 'package:mongo_easy/src/cli/templates/self_host.dart';
import 'package:mongo_easy/src/errors.dart';
import 'package:mongo_easy/src/schema/schema_parser.dart';

final _schema = parseSchemaYaml('''
collections:
  todos:
    owner_field: owner_id
    fields:
      title: text
      done: bool
      owner_id: text
''');

void main() {
  group('parseMongoUri', () {
    test('parses srv URIs with a database', () {
      final info =
          parseMongoUri('mongodb+srv://user:pass@cluster0.x.mongodb.net/mydb'
              '?retryWrites=true');
      expect(info.isSrv, isTrue);
      expect(info.database, 'mydb');
    });

    test('database is null when the path is empty', () {
      expect(
          parseMongoUri('mongodb+srv://u:p@c.mongodb.net/').database, isNull);
      expect(parseMongoUri('mongodb://localhost:27017').database, isNull);
    });

    test('withDatabase swaps the db and keeps the query', () {
      final info = parseMongoUri(
          'mongodb+srv://u:p@c.mongodb.net/appdb?retryWrites=true');
      expect(info.withDatabase('powersync_storage'),
          'mongodb+srv://u:p@c.mongodb.net/powersync_storage?retryWrites=true');
    });

    test('withDatabase works without an existing db or query', () {
      final info = parseMongoUri('mongodb://localhost:27017');
      expect(info.withDatabase('storage'), 'mongodb://localhost:27017/storage');
    });

    test('rejects non-mongodb strings with a hint', () {
      expect(
        () => parseMongoUri('postgres://nope'),
        throwsA(isA<ConfigurationException>()
            .having((e) => e.hint, 'hint', contains('mongodb+srv'))),
      );
    });
  });

  group('generateEndpointsDart', () {
    test('emits compilable consts', () {
      final dart = generateEndpointsDart(
        powersyncUrl: 'https://abc.powersync.journeyapps.com',
        uploadUrl: 'https://x.vercel.app/api/upload',
        tokenUrl: 'https://x.vercel.app/api/token',
      );
      expect(dart, contains('class MongoEasyEndpoints'));
      expect(dart,
          contains("powersyncUrl = 'https://abc.powersync.journeyapps.com'"));
      expect(dart, contains("uploadUrl = 'https://x.vercel.app/api/upload'"));
    });
  });

  group('generateSelfHostFiles', () {
    late Map<String, String> files;

    setUp(() {
      files = generateSelfHostFiles(
        _schema,
        mongoUri: 'mongodb+srv://u:p@c.mongodb.net/appdb?retryWrites=true',
        mongoDatabase: 'appdb',
        storageUri:
            'mongodb+srv://u:p@c.mongodb.net/powersync_storage?retryWrites=true',
        jwtSecret: 'a-very-long-secret-value-0123456789abcdef',
      );
    });

    test('bundles compose, service config, sync config and backend', () {
      expect(
          files.keys,
          containsAll(<String>[
            'docker-compose.yaml',
            'powersync/service.yaml',
            'powersync/sync-config.yaml',
            'backend/core.ts',
            'backend/server.ts',
            'backend/Dockerfile',
            '.env',
            'README.md',
          ]));
    });

    test('.env carries the credentials and the derived storage uri', () {
      final env = files['.env']!;
      expect(env, contains('MONGO_URI=mongodb+srv://u:p@c.mongodb.net/appdb'));
      expect(env, contains('MONGO_DB=appdb'));
      expect(env, contains('STORAGE_URI='));
      expect(env, contains('powersync_storage'));
      expect(env,
          contains('JWT_SECRET=a-very-long-secret-value-0123456789abcdef'));
      expect(env, contains('JWT_SECRET_B64='));
    });

    test('service.yaml reads secrets via !env, never inline', () {
      final service = files['powersync/service.yaml']!;
      expect(service, contains('uri: !env PS_MONGO_URI'));
      expect(service, contains('k: !env PS_JWT_K'));
      expect(service, isNot(contains('mongodb+srv://u:p@')));
    });

    test('sync config is the generated streams yaml', () {
      expect(files['powersync/sync-config.yaml'],
          contains('WHERE owner_id = auth.user_id()'));
    });

    test('backend core embeds the schema spec', () {
      expect(files['backend/core.ts'], contains('"ownerField": "owner_id"'));
      expect(files['backend/core.ts'], isNot(contains('__COLLECTIONS__')));
    });
  });

  group('AutoCloudSetup', () {
    late Directory temp;
    late FakeRunner runner;
    late StringBuffer log;

    setUp(() {
      temp = Directory.systemTemp.createTempSync('mongo_easy_auto');
      Directory('${temp.path}/backend/vercel').createSync(recursive: true);
      runner = FakeRunner();
      log = StringBuffer();
    });

    tearDown(() => temp.deleteSync(recursive: true));

    AutoCloudSetup setup({String? projectId}) => AutoCloudSetup(
          runner: runner,
          out: log,
          root: temp.path,
          schema: _schema,
          mongo:
              parseMongoUri('mongodb+srv://u:p@c.mongodb.net/appdb?w=majority'),
          mongoDatabase: 'appdb',
          jwtSecret: 'secret-0123456789-0123456789-0123456789',
          projectId: projectId,
          environment: const {'PS_ADMIN_TOKEN': 'test-token'},
        );

    test('happy path provisions instance, deploys config and backend',
        () async {
      runner.onRun = (exe, args, {cwd, stdinText}) {
        final command = args.join(' ');
        if (command.contains('whoami')) {
          return const ProcessResult2(0, 'soft2scale', '');
        }
        if (command.contains('link cloud')) {
          File('$cwd/cli.yaml')
              .writeAsStringSync('type: cloud\ninstance_id: inst-42\n');
          return const ProcessResult2(0, 'linked', '');
        }
        if (command.contains('powersync@latest deploy')) {
          return const ProcessResult2(0, 'deployed', '');
        }
        if (command.contains('vercel@latest deploy')) {
          return const ProcessResult2(
              0, 'https://mongo-easy-backend.vercel.app', '');
        }
        return const ProcessResult2(0, '', '');
      };

      final result = await setup(projectId: 'proj-1').run();

      expect(result.instanceId, 'inst-42');
      expect(result.powersyncUrl, 'https://inst-42.powersync.journeyapps.com');
      expect(
          result.uploadUrl, 'https://mongo-easy-backend.vercel.app/api/upload');

      final commands = runner.calls.map((c) => c.args.join(' ')).toList();
      expect(
          commands.any((c) => c.contains('link cloud --create '
              '--project-id=proj-1')),
          isTrue);
      expect(
          commands.where((c) => c.contains('vercel@latest deploy')).length, 2,
          reason: 'deploy, set env, redeploy');

      // Env vars were piped via stdin, with the shared secret.
      final envAdds = runner.calls
          .where((c) => c.args.join(' ').contains('env add'))
          .toList();
      expect(envAdds.map((c) => c.args[4]),
          containsAll(<String>['MONGO_URI', 'JWT_SECRET', 'JWT_AUDIENCE']));
      expect(envAdds.singleWhere((c) => c.args[4] == 'JWT_SECRET').stdinText,
          'secret-0123456789-0123456789-0123456789');

      // PowerSync CLI received the secrets via PS_ env, not files.
      final serviceYaml =
          File('${temp.path}/powersync-cloud/service.yaml').readAsStringSync();
      expect(serviceYaml, contains('!env PS_MONGO_URI'));
      expect(serviceYaml, isNot(contains('u:p@')));
    });

    test('reuses an already-linked instance', () async {
      Directory('${temp.path}/powersync-cloud').createSync(recursive: true);
      File('${temp.path}/powersync-cloud/cli.yaml')
          .writeAsStringSync('type: cloud\ninstance_id: existing-7\n');
      runner.onRun = (exe, args, {cwd, stdinText}) {
        if (args.join(' ').contains('vercel@latest deploy')) {
          return const ProcessResult2(0, 'https://b.vercel.app', '');
        }
        return const ProcessResult2(0, 'ok', '');
      };

      final result = await setup(projectId: 'proj-1').run();
      expect(result.instanceId, 'existing-7');
      expect(runner.calls.any((c) => c.args.join(' ').contains('link cloud')),
          isFalse);
    });

    test('surfaces PowerSync deploy failures with the CLI output', () async {
      runner.onRun = (exe, args, {cwd, stdinText}) {
        final command = args.join(' ');
        if (command.contains('link cloud')) {
          File('$cwd/cli.yaml').writeAsStringSync('instance_id: i\n');
          return const ProcessResult2(0, '', '');
        }
        if (command.contains('powersync@latest deploy')) {
          return const ProcessResult2(1, '', 'invalid sync config: line 3');
        }
        return const ProcessResult2(0, 'ok', '');
      };

      expect(
        () => setup(projectId: 'p').run(),
        throwsA(isA<AutoCloudException>()
            .having((e) => e.step, 'step', 'deploy PowerSync config')
            .having((e) => e.detail, 'detail', contains('line 3'))),
      );
    });

    test('fails clearly when vercel is not logged in', () async {
      runner.onRun = (exe, args, {cwd, stdinText}) {
        if (args.join(' ').contains('whoami')) {
          return const ProcessResult2(1, '', 'not authenticated');
        }
        return const ProcessResult2(0, '', '');
      };

      expect(
        () => setup(projectId: 'p').run(),
        throwsA(isA<AutoCloudException>()
            .having((e) => e.hint, 'hint', contains('vercel login'))),
      );
    });
  });
}

class RecordedProc {
  RecordedProc(this.exe, this.args, this.cwd, this.stdinText);

  final String exe;
  final List<String> args;
  final String? cwd;
  final String? stdinText;
}

typedef OnRun = ProcessResult2 Function(String exe, List<String> args,
    {String? cwd, String? stdinText});

class FakeRunner implements ProcessRunner {
  final List<RecordedProc> calls = [];
  OnRun onRun =
      (exe, args, {cwd, stdinText}) => const ProcessResult2(0, '', '');

  @override
  Future<ProcessResult2> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    String? stdinText,
  }) async {
    calls.add(RecordedProc(executable, arguments, workingDirectory, stdinText));
    return onRun(executable, arguments,
        cwd: workingDirectory, stdinText: stdinText);
  }

  @override
  Future<bool> exists(String executable) async => true;
}

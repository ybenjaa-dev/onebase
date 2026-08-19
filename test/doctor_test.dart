import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mongobase/src/cli/doctor.dart';
import 'package:mongobase/src/cli/generate_dart_schema.dart';
import 'package:mongobase/src/cli/templates/platforms.dart';
import 'package:mongobase/src/schema/schema_parser.dart';
import 'package:path/path.dart' as p;

const _yaml = '''
collections:
  todos:
    owner_field: owner_id
    fields:
      title: text!
      done: bool
      owner_id: text
''';

void main() {
  late Directory root;

  setUp(() => root = Directory.systemTemp.createTempSync('mongobase_doctor'));
  tearDown(() => root.deleteSync(recursive: true));

  void write(String relative, String content) {
    File(p.join(root.path, relative))
      ..createSync(recursive: true)
      ..writeAsStringSync(content);
  }

  /// A project generated exactly as the CLI would.
  void scaffold({String yaml = _yaml}) {
    write('mongobase.yaml', yaml);
    final schema = parseSchemaYaml(yaml);
    write('lib/mongobase_schema.g.dart', generateDartSchema(schema));
    generateBackendFiles(schema).forEach((path, content) {
      write('backend/$path', content);
    });
  }

  Diagnosis findingFor(List<Diagnosis> findings, String fragment) =>
      findings.firstWhere((f) => f.title.contains(fragment),
          orElse: () => throw StateError(
              'no finding matching "$fragment" in ${findings.map((f) => f.title)}'));

  bool hasError(List<Diagnosis> findings) =>
      findings.any((f) => f.level == DiagnosisLevel.error);

  test('reports a missing schema with the command that creates one', () async {
    final findings = await diagnose(root: root.path);
    expect(findings.single.level, DiagnosisLevel.error);
    expect(findings.single.fix, contains('--init'));
  });

  test('reports a schema that does not parse', () async {
    write('mongobase.yaml', 'collections: []');
    final findings = await diagnose(root: root.path);
    expect(findings.single.level, DiagnosisLevel.error);
    expect(findings.single.title, contains('does not parse'));
  });

  test('a freshly generated project is clean apart from the dev warning',
      () async {
    scaffold();
    write('backend/.env', '''
MONGO_URI=mongodb://x
MONGO_DB=app
AUTH_MODE=hs256
JWT_SECRET=${'x' * 40}
''');
    final findings = await diagnose(root: root.path);
    expect(hasError(findings), isFalse,
        reason: findings.map((f) => f.title).join(', '));
  });

  group('drift', () {
    test('catches a stale generated Dart schema', () async {
      scaffold();
      write('lib/mongobase_schema.g.dart', '// stale');
      final findings = await diagnose(root: root.path);
      expect(findingFor(findings, 'out of date').level, DiagnosisLevel.error);
    });

    test('catches a backend generated from a different schema', () async {
      scaffold();
      // Add a collection to the YAML but leave the backend as it was.
      write('mongobase.yaml', '''
$_yaml
  notes:
    owner_field: owner_id
    fields:
      body: text
      owner_id: text
''');
      final schema = parseSchemaYaml(
          File(p.join(root.path, 'mongobase.yaml')).readAsStringSync());
      write('lib/mongobase_schema.g.dart', generateDartSchema(schema));

      final findings = await diagnose(root: root.path);
      final drift = findingFor(findings, 'different schema');
      expect(drift.level, DiagnosisLevel.error);
      expect(drift.fix, contains('redeploy'));
    });

    test('reports a missing backend', () async {
      write('mongobase.yaml', _yaml);
      write('lib/mongobase_schema.g.dart',
          generateDartSchema(parseSchemaYaml(_yaml)));
      final findings = await diagnose(root: root.path);
      expect(findingFor(findings, 'core.ts is missing').level,
          DiagnosisLevel.error);
    });
  });

  group('environment', () {
    Future<List<Diagnosis>> withEnv(String env) async {
      scaffold();
      write('backend/.env', env);
      return diagnose(root: root.path);
    }

    test('missing AUTH_MODE is an error, not a default', () async {
      final findings = await withEnv('MONGO_URI=x\nMONGO_DB=y\n');
      expect(findingFor(findings, 'AUTH_MODE is not set').level,
          DiagnosisLevel.error);
    });

    test('dev mode is flagged as unsafe for real users', () async {
      final findings = await withEnv(
          'MONGO_URI=x\nMONGO_DB=y\nAUTH_MODE=dev\nJWT_SECRET=${'x' * 40}\n');
      final dev = findingFor(findings, 'AUTH_MODE=dev');
      expect(dev.level, DiagnosisLevel.warning);
      expect(dev.detail, contains('any email'));
    });

    test('a short secret is rejected', () async {
      final findings = await withEnv(
          'MONGO_URI=x\nMONGO_DB=y\nAUTH_MODE=hs256\nJWT_SECRET=short\n');
      expect(findingFor(findings, 'JWT_SECRET is too short').level,
          DiagnosisLevel.error);
    });

    test('jwks without an audience is rejected', () async {
      final findings = await withEnv(
          'MONGO_URI=x\nMONGO_DB=y\nAUTH_MODE=jwks\nJWKS_URL=https://x/j\n');
      expect(findingFor(findings, 'needs JWT_AUDIENCE').level,
          DiagnosisLevel.error);
    });

    test('comments and blank lines are ignored', () async {
      final findings = await withEnv('''
# a comment
MONGO_URI=mongodb://x

MONGO_DB=app
AUTH_MODE=hs256
JWT_SECRET=${'x' * 40}
''');
      expect(hasError(findings), isFalse);
    });

    test('a missing .env is a warning, since hosts set vars themselves',
        () async {
      scaffold();
      final findings = await diagnose(root: root.path);
      expect(
          findingFor(findings, '.env not found').level, DiagnosisLevel.warning);
    });
  });

  group('reachability', () {
    test('confirms a healthy backend', () async {
      scaffold();
      final findings = await diagnose(
        root: root.path,
        apiUrl: 'https://api.test',
        fetch: (url) async {
          expect(url, 'https://api.test/health');
          return '{"status":"ok"}';
        },
      );
      expect(findingFor(findings, 'reachable').level, DiagnosisLevel.ok);
    });

    test('strips a trailing slash before probing', () async {
      scaffold();
      var probed = '';
      await diagnose(
        root: root.path,
        apiUrl: 'https://api.test/',
        fetch: (url) async {
          probed = url;
          return '{"status":"ok"}';
        },
      );
      expect(probed, 'https://api.test/health');
    });

    test('reports an unreachable backend with a fix', () async {
      scaffold();
      final findings = await diagnose(
        root: root.path,
        apiUrl: 'https://api.test',
        fetch: (_) async => throw const SocketException('refused'),
      );
      final finding = findingFor(findings, 'Could not reach');
      expect(finding.level, DiagnosisLevel.error);
      expect(finding.fix, contains('trailing slash'));
    });

    test('flags a response that is not the health payload', () async {
      scaffold();
      final findings = await diagnose(
        root: root.path,
        apiUrl: 'https://api.test',
        fetch: (_) async => '<html>not found</html>',
      );
      expect(findingFor(findings, 'not with the expected').level,
          DiagnosisLevel.warning);
    });
  });

  test('exit code is non-zero only when something is broken', () {
    final clean = [const Diagnosis(DiagnosisLevel.ok, 'fine')];
    final warned = [const Diagnosis(DiagnosisLevel.warning, 'careful')];
    final broken = [const Diagnosis(DiagnosisLevel.error, 'broken')];

    expect(reportDiagnosis(clean, StringBuffer()), 0);
    expect(reportDiagnosis(warned, StringBuffer()), 0);
    expect(reportDiagnosis(broken, StringBuffer()), 1);
  });
}

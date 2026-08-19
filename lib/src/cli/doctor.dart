import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../errors.dart';
import '../schema/schema.dart';
import '../schema/schema_parser.dart';
import 'generate_dart_schema.dart';
import 'templates/backend_core.dart';

/// How serious a finding is.
enum DiagnosisLevel { ok, warning, error }

/// One check and what it found.
class Diagnosis {
  const Diagnosis(this.level, this.title, {this.detail, this.fix});

  final DiagnosisLevel level;
  final String title;
  final String? detail;

  /// The command or edit that resolves it.
  final String? fix;

  String get icon => switch (level) {
        DiagnosisLevel.ok => '✓',
        DiagnosisLevel.warning => '!',
        DiagnosisLevel.error => '✗',
      };
}

/// Checks a project for the things that actually go wrong: a schema that
/// drifted from the deployed backend, a half-configured `.env`, an
/// unreachable API.
///
/// Pure apart from reading files and an optional health request, so it is
/// covered by tests rather than only by trying it.
Future<List<Diagnosis>> diagnose({
  required String root,
  String schemaFile = 'mongobase.yaml',
  String? apiUrl,
  Future<String?> Function(String url)? fetch,
}) async {
  final findings = <Diagnosis>[];

  final schemaPath = p.join(root, schemaFile);
  final schemaSource = File(schemaPath);
  if (!schemaSource.existsSync()) {
    return [
      Diagnosis(
        DiagnosisLevel.error,
        'No schema at $schemaFile',
        fix: 'dart run mongobase:setup --init',
      ),
    ];
  }

  final MongobaseSchema schema;
  try {
    schema = parseSchemaYaml(schemaSource.readAsStringSync());
  } on MongobaseException catch (error) {
    return [
      Diagnosis(DiagnosisLevel.error, 'Schema does not parse',
          detail: error.message, fix: error.hint),
    ];
  }
  findings.add(Diagnosis(
    DiagnosisLevel.ok,
    'Schema parses (${schema.collections.length} collection(s): '
    '${schema.collections.keys.join(', ')})',
  ));

  // --- generated Dart ------------------------------------------------------
  final generated = File(p.join(root, 'lib', 'mongobase_schema.g.dart'));
  if (!generated.existsSync()) {
    findings.add(const Diagnosis(
      DiagnosisLevel.error,
      'lib/mongobase_schema.g.dart is missing',
      fix: 'dart run mongobase:setup',
    ));
  } else if (generated.readAsStringSync().trim() !=
      generateDartSchema(schema).trim()) {
    findings.add(const Diagnosis(
      DiagnosisLevel.error,
      'lib/mongobase_schema.g.dart is out of date',
      detail: 'It no longer matches mongobase.yaml, so your models and the '
          'runtime schema disagree.',
      fix: 'dart run mongobase:setup --force',
    ));
  } else {
    findings.add(const Diagnosis(
        DiagnosisLevel.ok, 'Generated Dart schema matches the YAML'));
  }

  // --- generated backend ---------------------------------------------------
  final core = File(p.join(root, 'backend', 'src', 'core.ts'));
  if (!core.existsSync()) {
    findings.add(const Diagnosis(
      DiagnosisLevel.error,
      'backend/src/core.ts is missing',
      fix: 'dart run mongobase:setup',
    ));
  } else {
    final source = core.readAsStringSync();
    final expected = buildCollectionsTs(schema);
    // This is the drift that silently breaks apps: the client knows about a
    // collection or field the deployed backend has never heard of.
    if (!source.contains(expected)) {
      findings.add(const Diagnosis(
        DiagnosisLevel.error,
        'The backend was generated from a different schema',
        detail: 'Writes to new collections or fields will be refused until '
            'the deployed backend is regenerated and redeployed.',
        fix: 'dart run mongobase:setup --force, then redeploy backend/',
      ));
    } else {
      findings.add(const Diagnosis(
          DiagnosisLevel.ok, 'Backend schema matches the YAML'));
    }
  }

  findings.addAll(_checkEnv(root, storageDeclared: !schema.storage.isEmpty));

  // --- reachability --------------------------------------------------------
  if (apiUrl != null) {
    findings.add(await _checkApi(apiUrl, fetch));
  }

  return findings;
}

List<Diagnosis> _checkEnv(String root, {required bool storageDeclared}) {
  final env = File(p.join(root, 'backend', '.env'));
  if (!env.existsSync()) {
    return [
      const Diagnosis(
        DiagnosisLevel.warning,
        'backend/.env not found',
        detail: 'Fine if you set the variables in your host dashboard '
            'instead.',
        fix: 'cd backend && cp .env.example .env',
      ),
    ];
  }

  final values = <String, String>{};
  for (final line in env.readAsLinesSync()) {
    final trimmed = line.trim();
    if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
    final index = trimmed.indexOf('=');
    if (index <= 0) continue;
    values[trimmed.substring(0, index).trim()] =
        trimmed.substring(index + 1).trim();
  }

  final findings = <Diagnosis>[];
  for (final key in ['MONGO_URI', 'MONGO_DB']) {
    if ((values[key] ?? '').isEmpty) {
      findings.add(Diagnosis(DiagnosisLevel.error, '$key is not set in .env'));
    }
  }

  final mode = values['AUTH_MODE'] ?? '';
  if (mode.isEmpty) {
    findings.add(const Diagnosis(
      DiagnosisLevel.error,
      'AUTH_MODE is not set',
      detail: 'The backend refuses to start without it.',
      fix: 'Set AUTH_MODE to jwks, hs256 or dev in backend/.env',
    ));
  } else if (!const {'dev', 'hs256', 'jwks'}.contains(mode)) {
    findings.add(Diagnosis(DiagnosisLevel.error, 'AUTH_MODE="$mode" is invalid',
        fix: 'Use jwks, hs256 or dev.'));
  } else if (mode == 'dev') {
    findings.add(const Diagnosis(
      DiagnosisLevel.warning,
      'AUTH_MODE=dev',
      detail: 'The /token endpoint will sign a JWT for any email address. '
          'Fine while building, never with real users.',
      fix: 'Switch to jwks (or hs256) before launch.',
    ));
  } else {
    findings.add(Diagnosis(DiagnosisLevel.ok, 'AUTH_MODE=$mode'));
  }

  if (mode == 'dev' || mode == 'hs256') {
    final secret = values['JWT_SECRET'] ?? '';
    if (secret.length < 32) {
      findings.add(Diagnosis(
        DiagnosisLevel.error,
        'JWT_SECRET is too short (${secret.length} chars)',
        fix: 'Use at least 32 characters.',
      ));
    }
  }
  if (storageDeclared) {
    final missing = ['S3_BUCKET', 'S3_ACCESS_KEY_ID', 'S3_SECRET_ACCESS_KEY']
        .where((key) => (values[key] ?? '').isEmpty)
        .toList();
    if (missing.isEmpty) {
      findings.add(const Diagnosis(DiagnosisLevel.ok, 'Storage is configured'));
    } else {
      findings.add(Diagnosis(
        DiagnosisLevel.error,
        'Storage buckets are declared but ${missing.join(', ')} '
        '${missing.length == 1 ? 'is' : 'are'} not set',
        detail: 'The /storage routes will answer 501 until they are.',
        fix: 'Set them in backend/.env, or remove the `storage:` section.',
      ));
    }
    // R2, MinIO, B2 and Spaces all need an explicit endpoint; only AWS does
    // not, and AWS needs a real region rather than "auto".
    final endpoint = values['S3_ENDPOINT'] ?? '';
    final region = values['S3_REGION'] ?? '';
    if (endpoint.isEmpty && (region.isEmpty || region == 'auto')) {
      findings.add(const Diagnosis(
        DiagnosisLevel.warning,
        'S3_REGION is "auto" with no S3_ENDPOINT',
        detail: 'Plain AWS needs a real region (eu-west-1, us-east-1, …). '
            'Set S3_ENDPOINT instead if you are on R2, MinIO or Spaces.',
      ));
    }
  }

  if (mode == 'jwks') {
    if ((values['JWKS_URL'] ?? '').isEmpty) {
      findings.add(const Diagnosis(
          DiagnosisLevel.error, 'AUTH_MODE=jwks needs JWKS_URL'));
    }
    if ((values['JWT_AUDIENCE'] ?? '').isEmpty) {
      findings.add(const Diagnosis(
        DiagnosisLevel.error,
        'AUTH_MODE=jwks needs JWT_AUDIENCE',
        detail: 'Without it, tokens your provider issued for other '
            'applications would be accepted.',
      ));
    }
  }
  return findings;
}

Future<Diagnosis> _checkApi(
    String apiUrl, Future<String?> Function(String url)? fetch) async {
  final url = '${apiUrl.replaceAll(RegExp(r'/+$'), '')}/health';
  final get = fetch ?? _httpGet;
  try {
    final body = await get(url);
    if (body == null) {
      return Diagnosis(DiagnosisLevel.error, 'Backend did not respond at $url',
          fix: 'Check the URL and that the deployment is running.');
    }
    // Something answered. Decoding separately keeps "wrong host" distinct
    // from "nothing there" — they need different fixes.
    Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException {
      decoded = null;
    }
    if (decoded is Map && decoded['status'] == 'ok') {
      return Diagnosis(DiagnosisLevel.ok, 'Backend is reachable at $apiUrl');
    }
    return Diagnosis(
      DiagnosisLevel.warning,
      'Something answered at $url but not with the expected health payload',
      detail: body.length > 120 ? '${body.substring(0, 120)}…' : body,
      fix: 'Check that apiUrl points at the mongobase backend itself.',
    );
  } on Object catch (error) {
    return Diagnosis(DiagnosisLevel.error, 'Could not reach $url',
        detail: '$error',
        fix: 'Check the URL, and that it has no trailing slash.');
  }
}

Future<String?> _httpGet(String url) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
  try {
    final request = await client.getUrl(Uri.parse(url));
    final response = await request.close();
    if (response.statusCode != 200) return null;
    return response.transform(utf8.decoder).join();
  } finally {
    client.close(force: true);
  }
}

/// Renders findings for the terminal. Returns the process exit code.
int reportDiagnosis(List<Diagnosis> findings, StringSink out) {
  out.writeln('mongobase doctor\n');
  for (final finding in findings) {
    out.writeln('${finding.icon} ${finding.title}');
    if (finding.detail != null) out.writeln('    ${finding.detail}');
    if (finding.fix != null) out.writeln('    → ${finding.fix}');
  }

  final errors = findings.where((f) => f.level == DiagnosisLevel.error).length;
  final warnings =
      findings.where((f) => f.level == DiagnosisLevel.warning).length;
  out.writeln();
  if (errors == 0 && warnings == 0) {
    out.writeln('Everything checks out.');
  } else {
    out.writeln('$errors error(s), $warnings warning(s).');
  }
  return errors == 0 ? 0 : 1;
}

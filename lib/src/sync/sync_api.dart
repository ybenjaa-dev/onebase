import 'dart:convert';

import 'package:http/http.dart' as http;

import '../auth/token_provider.dart';
import '../errors.dart';
import '../store/local_store.dart';

/// One collection's slice of a pull response.
class PullResult {
  const PullResult({
    required this.documents,
    required this.cursor,
    required this.hasMore,
  });

  final List<Map<String, Object?>> documents;

  /// Watermark to send on the next pull. Null when nothing changed.
  final String? cursor;

  /// True when the server had more than one page of changes.
  final bool hasMore;
}

/// The result of pushing the outbox.
class PushResult {
  const PushResult({required this.applied, required this.skipped});

  final int applied;

  /// Ops the backend refused (not owned, unknown collection, malformed).
  /// They are dropped from the outbox: retrying would never succeed.
  final List<Map<String, Object?>> skipped;
}

/// HTTP client for the generated backend. Three routes, nothing else.
class SyncApi {
  SyncApi({
    required this.baseUrl,
    required this.tokenProvider,
    http.Client? httpClient,
  }) : _http = httpClient ?? http.Client();

  /// Root URL of the deployed backend, e.g. `https://api.example.com`.
  final String baseUrl;
  final TokenProvider tokenProvider;
  final http.Client _http;

  Future<Map<String, Object?>> _post(String path, Object body) async {
    final token = await tokenProvider.getToken();
    if (token == null || token.isEmpty) {
      throw const InvalidTokenException(
        'No auth token available.',
        hint: 'Sign in first; onebase keeps working offline until then.',
      );
    }

    final http.Response response;
    try {
      response = await _http.post(
        Uri.parse('$baseUrl$path'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $token',
        },
        body: jsonEncode(body),
      );
    } on Object catch (error) {
      throw UploadException(
        'Could not reach the backend ($baseUrl$path): $error',
        hint: 'Local data keeps working; sync retries automatically.',
      );
    }

    if (response.statusCode == 401 || response.statusCode == 403) {
      throw UploadException(
        'Backend rejected the token (HTTP ${response.statusCode}).',
        hint:
            'The backend must verify the same JWTs your app sends. Check '
            'AUTH_MODE / JWT_SECRET / JWKS_URL on the deployment.',
        statusCode: response.statusCode,
      );
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw UploadException(
        'Backend returned HTTP ${response.statusCode}: '
        '${_snippet(response.body)}',
        hint:
            'Transient failures retry automatically; check the backend '
            'logs if this persists.',
        statusCode: response.statusCode,
      );
    }

    try {
      return (jsonDecode(response.body) as Map).cast<String, Object?>();
    } on Object {
      throw const UploadException('Backend returned a non-JSON response.');
    }
  }

  /// Uploads queued local writes.
  Future<PushResult> push(List<OutboxOp> ops) async {
    final grouped = <String, List<Map<String, Object?>>>{};
    for (final op in ops) {
      grouped.putIfAbsent(op.transactionId, () => []).add(op.toJson());
    }
    final body = {
      'transactions': [
        for (final MapEntry(:key, :value) in grouped.entries)
          {'id': key, 'ops': value},
      ],
    };
    final json = await _post('/push', body);
    return PushResult(
      applied: (json['applied'] as num?)?.toInt() ?? 0,
      skipped: [
        for (final entry in (json['skipped'] as List? ?? const []))
          (entry as Map).cast<String, Object?>(),
      ],
    );
  }

  /// Downloads documents changed since [since] for [collection].
  Future<PullResult> pull(String collection, String? since) async {
    final json = await _post('/pull', {
      'collection': collection,
      if (since != null) 'since': since,
    });
    return PullResult(
      documents: [
        for (final entry in (json['documents'] as List? ?? const []))
          (entry as Map).cast<String, Object?>(),
      ],
      cursor: json['cursor'] as String?,
      hasMore: json['has_more'] == true,
    );
  }

  /// Runs a query server-side (online mode). Returns raw documents.
  Future<List<Map<String, Object?>>> query(Map<String, Object?> body) async {
    final json = await _post('/query', body);
    return [
      for (final entry in (json['documents'] as List? ?? const []))
        (entry as Map).cast<String, Object?>(),
    ];
  }

  /// Counts matching documents without transferring them.
  Future<int> queryCount(Map<String, Object?> body) async {
    final json = await _post('/query', {...body, 'count': true});
    return (json['count'] as num?)?.toInt() ?? 0;
  }

  /// Fetches one document by id, or null.
  Future<Map<String, Object?>?> queryById(String collection, String id) async {
    final json = await _post('/query', {'collection': collection, 'id': id});
    final documents = json['documents'] as List? ?? const [];
    if (documents.isEmpty) return null;
    return (documents.first as Map).cast<String, Object?>();
  }

  /// Opens the realtime change stream. See [RealtimeClient].
  Future<http.StreamedResponse> openStream(List<String> collections) async {
    final token = await tokenProvider.getToken();
    if (token == null || token.isEmpty) {
      throw const InvalidTokenException(
        'No auth token available for the realtime stream.',
        hint: 'Sign in first; onebase keeps working offline until then.',
      );
    }
    final uri = Uri.parse('$baseUrl/stream').replace(
      queryParameters: {
        if (collections.isNotEmpty) 'collections': collections.join(','),
      },
    );
    final request = http.Request('GET', uri)
      ..headers['Authorization'] = 'Bearer $token'
      ..headers['Accept'] = 'text/event-stream'
      ..headers['Cache-Control'] = 'no-cache';
    return _http.send(request);
  }

  /// POSTs to a storage route and returns the decoded body.
  Future<Map<String, Object?>> storage(
    String route,
    Map<String, Object?> body,
  ) => _post('/storage/$route', body);

  /// Uploads bytes straight to the object store with a presigned URL.
  ///
  /// This request carries no credentials of ours — the signature in the URL is
  /// the authorization, and the headers must match what the backend signed.
  Future<void> putSigned(
    String url,
    List<int> bytes,
    Map<String, String> headers,
  ) async {
    final http.Response response;
    try {
      response = await _http.put(Uri.parse(url), headers: headers, body: bytes);
    } on Object catch (error) {
      throw StorageException(
        'Could not reach the storage endpoint: $error',
        hint: 'Uploads need a connection; they are not queued for later.',
      );
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StorageException(
        'The object store rejected the upload '
        '(HTTP ${response.statusCode}): ${_snippet(response.body)}',
        hint:
            'Check the bucket credentials and CORS rules on your storage '
            'provider.',
      );
    }
  }

  void close() => _http.close();

  static String _snippet(String body) =>
      body.length <= 200 ? body : '${body.substring(0, 200)}…';
}

import '../errors.dart';

/// Parsed pieces of a MongoDB connection string that the setup flows need.
class MongoUriInfo {
  const MongoUriInfo({
    required this.uri,
    required this.database,
    required this.isSrv,
  });

  /// The connection string as provided (credentials untouched).
  final String uri;

  /// Database name from the URI path, or null when absent.
  final String? database;

  final bool isSrv;

  /// The same connection string pointing at [db] instead — used to give the
  /// PowerSync service its own storage database on the same cluster.
  String withDatabase(String db) {
    final queryStart = uri.indexOf('?');
    final base = queryStart == -1 ? uri : uri.substring(0, queryStart);
    final query = queryStart == -1 ? '' : uri.substring(queryStart);

    final schemeEnd = base.indexOf('://') + 3;
    final pathStart = base.indexOf('/', schemeEnd);
    final host = pathStart == -1 ? base : base.substring(0, pathStart);
    return '$host/$db$query';
  }
}

/// Validates the shape of a MongoDB connection string. Connectivity itself is
/// verified later by the PowerSync deploy and the backend.
MongoUriInfo parseMongoUri(String raw) {
  final uri = raw.trim();
  final isSrv = uri.startsWith('mongodb+srv://');
  if (!isSrv && !uri.startsWith('mongodb://')) {
    throw const ConfigurationException(
      'That does not look like a MongoDB connection string.',
      hint: 'Expected mongodb+srv://user:pass@cluster.mongodb.net/mydb '
          '(Atlas → Database → Connect → Drivers).',
    );
  }

  final parsed = Uri.tryParse(uri);
  if (parsed == null || parsed.host.isEmpty) {
    throw const ConfigurationException(
      'Could not parse the MongoDB connection string.',
      hint: 'If the password contains special characters, URL-encode it '
          '(e.g. @ becomes %40).',
    );
  }

  final segments =
      parsed.pathSegments.where((segment) => segment.isNotEmpty).toList();
  final database = segments.isEmpty ? null : segments.first;

  return MongoUriInfo(uri: uri, database: database, isSrv: isSrv);
}

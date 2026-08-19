/// Base class for all errors thrown by mongobase.
///
/// Every exception carries a [message] describing what went wrong and,
/// where possible, a [hint] describing how to fix it.
sealed class MongobaseException implements Exception {
  const MongobaseException(this.message, {this.hint});

  /// What went wrong.
  final String message;

  /// How to fix it, when a likely fix is known.
  final String? hint;

  @override
  String toString() =>
      'MongobaseException: $message${hint == null ? '' : '\n  hint: $hint'}';
}

/// Thrown when [Mongobase.instance] is accessed before [Mongobase.init].
final class NotInitializedException extends MongobaseException {
  const NotInitializedException()
      : super(
          'Mongobase has not been initialized.',
          hint: 'Call `await Mongobase.init(MongobaseConfig(...))` before '
              'accessing collections — typically in main() before runApp().',
        );
}

/// Thrown when [MongobaseConfig] contains invalid or missing values.
final class ConfigurationException extends MongobaseException {
  const ConfigurationException(super.message, {super.hint});
}

/// Thrown when accessing a collection that is not declared in the schema.
final class UnknownCollectionException extends MongobaseException {
  UnknownCollectionException(String collection, Iterable<String> known)
      : super(
          'Unknown collection "$collection".',
          hint:
              'Declared collections: ${known.isEmpty ? '(none)' : known.join(', ')}. '
              'Add "$collection" to mongobase.yaml and re-run '
              '`dart run mongobase:setup`.',
        );
}

/// Thrown when a query or write references a field that is not in the schema.
final class UnknownFieldException extends MongobaseException {
  UnknownFieldException(String field, String collection, Iterable<String> known)
      : super(
          'Unknown field "$field" on collection "$collection".',
          hint: 'Declared fields: ${known.join(', ')}. '
              'Add it to mongobase.yaml and re-run '
              '`dart run mongobase:setup`, or fix the field name.',
        );
}

/// Thrown when a field name or dot-path is not a valid identifier.
final class InvalidFieldNameException extends MongobaseException {
  InvalidFieldNameException(String field)
      : super(
          'Invalid field name "$field".',
          hint: 'Field names must match [a-zA-Z_][a-zA-Z0-9_]* and may use '
              'dots for nested json fields (e.g. "address.city").',
        );
}

/// Thrown when the auth token is missing, malformed, or expired.
final class InvalidTokenException extends MongobaseException {
  const InvalidTokenException(super.message, {super.hint});
}

/// Thrown when uploading local writes to the backend endpoint fails.
///
/// The sync engine retries automatically, so a single occurrence is
/// usually transient. Persistent failures indicate a misconfigured
/// [MongobaseConfig.uploadUrl] or a broken backend deployment.
final class UploadException extends MongobaseException {
  const UploadException(super.message, {super.hint, this.statusCode});

  /// HTTP status returned by the upload endpoint, if a response was received.
  final int? statusCode;
}

/// Thrown when a query is structurally invalid (e.g. empty `whereIn` list).
final class QueryException extends MongobaseException {
  const QueryException(super.message, {super.hint});
}

/// Thrown when parsing `mongobase.yaml` fails.
final class SchemaParseException extends MongobaseException {
  const SchemaParseException(super.message, {super.hint});
}

/// Thrown when a file operation is rejected: a bad path, a bucket that is not
/// declared, a file too large, or storage that is not configured.
class StorageException extends MongobaseException {
  const StorageException(super.message, {super.hint});
}

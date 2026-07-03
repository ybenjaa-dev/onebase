/// Base class for all errors thrown by mongo_easy.
///
/// Every exception carries a [message] describing what went wrong and,
/// where possible, a [hint] describing how to fix it.
sealed class MongoEasyException implements Exception {
  const MongoEasyException(this.message, {this.hint});

  /// What went wrong.
  final String message;

  /// How to fix it, when a likely fix is known.
  final String? hint;

  @override
  String toString() =>
      'MongoEasyException: $message${hint == null ? '' : '\n  hint: $hint'}';
}

/// Thrown when [MongoEasy.instance] is accessed before [MongoEasy.init].
final class NotInitializedException extends MongoEasyException {
  const NotInitializedException()
      : super(
          'MongoEasy has not been initialized.',
          hint: 'Call `await MongoEasy.init(MongoEasyConfig(...))` before '
              'accessing collections — typically in main() before runApp().',
        );
}

/// Thrown when [MongoEasyConfig] contains invalid or missing values.
final class ConfigurationException extends MongoEasyException {
  const ConfigurationException(super.message, {super.hint});
}

/// Thrown when accessing a collection that is not declared in the schema.
final class UnknownCollectionException extends MongoEasyException {
  UnknownCollectionException(String collection, Iterable<String> known)
      : super(
          'Unknown collection "$collection".',
          hint:
              'Declared collections: ${known.isEmpty ? '(none)' : known.join(', ')}. '
              'Add "$collection" to mongo_easy.yaml and re-run '
              '`dart run mongo_easy:setup`.',
        );
}

/// Thrown when a query or write references a field that is not in the schema.
final class UnknownFieldException extends MongoEasyException {
  UnknownFieldException(String field, String collection, Iterable<String> known)
      : super(
          'Unknown field "$field" on collection "$collection".',
          hint: 'Declared fields: ${known.join(', ')}. '
              'Add it to mongo_easy.yaml and re-run '
              '`dart run mongo_easy:setup`, or fix the field name.',
        );
}

/// Thrown when a field name or dot-path is not a valid identifier.
final class InvalidFieldNameException extends MongoEasyException {
  InvalidFieldNameException(String field)
      : super(
          'Invalid field name "$field".',
          hint: 'Field names must match [a-zA-Z_][a-zA-Z0-9_]* and may use '
              'dots for nested json fields (e.g. "address.city").',
        );
}

/// Thrown when the auth token is missing, malformed, or expired.
final class InvalidTokenException extends MongoEasyException {
  const InvalidTokenException(super.message, {super.hint});
}

/// Thrown when uploading local writes to the backend endpoint fails.
///
/// PowerSync retries the upload automatically, so a single occurrence is
/// usually transient. Persistent failures indicate a misconfigured
/// [MongoEasyConfig.uploadUrl] or a broken backend deployment.
final class UploadException extends MongoEasyException {
  const UploadException(super.message, {super.hint, this.statusCode});

  /// HTTP status returned by the upload endpoint, if a response was received.
  final int? statusCode;
}

/// Thrown when a query is structurally invalid (e.g. empty `whereIn` list).
final class QueryException extends MongoEasyException {
  const QueryException(super.message, {super.hint});
}

/// Thrown when parsing `mongo_easy.yaml` fails.
final class SchemaParseException extends MongoEasyException {
  const SchemaParseException(super.message, {super.hint});
}

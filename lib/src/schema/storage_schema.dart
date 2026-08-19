import '../errors.dart';

/// Who may read and write the files in a bucket.
enum StorageAccess {
  /// Each user sees only their own files. Keys are namespaced by the user id,
  /// so one user cannot even name another user's file.
  private('private'),

  /// Any signed-in user may read; only the uploader may overwrite or delete.
  shared('shared');

  const StorageAccess(this.yamlName);

  final String yamlName;

  static StorageAccess parse(String value) {
    for (final access in values) {
      if (access.yamlName == value) return access;
    }
    throw SchemaParseException(
      'Unknown storage access "$value".',
      hint: 'Valid values: ${values.map((a) => a.yamlName).join(', ')}.',
    );
  }
}

/// One bucket ("folder") of files, declared in `onebase.yaml`.
class StorageBucketSchema {
  StorageBucketSchema(
    this.name, {
    this.access = StorageAccess.private,
    this.maxSizeBytes,
    this.contentTypes = const [],
  }) {
    if (!RegExp(r'^[a-z0-9][a-z0-9_-]*$').hasMatch(name)) {
      throw SchemaParseException(
        'Storage bucket "$name" has an invalid name.',
        hint: 'Use lowercase letters, digits, underscores and dashes.',
      );
    }
    if (maxSizeBytes != null && maxSizeBytes! <= 0) {
      throw SchemaParseException(
        'max_size of storage bucket "$name" must be positive.',
      );
    }
  }

  final String name;
  final StorageAccess access;

  /// Largest upload the backend will sign for. Null means no limit beyond
  /// whatever your S3 provider enforces.
  final int? maxSizeBytes;

  /// Content types the backend will sign for, e.g. `['image/png']`. A trailing
  /// `/*` wildcard is allowed (`image/*`). Empty means anything.
  final List<String> contentTypes;

  bool get isPrivate => access == StorageAccess.private;

  /// True when [contentType] is allowed by [contentTypes].
  bool allowsContentType(String contentType) {
    if (contentTypes.isEmpty) return true;
    final value = contentType.toLowerCase();
    for (final allowed in contentTypes) {
      final pattern = allowed.toLowerCase();
      if (pattern.endsWith('/*')) {
        if (value.startsWith(pattern.substring(0, pattern.length - 1))) {
          return true;
        }
      } else if (value == pattern) {
        return true;
      }
    }
    return false;
  }
}

/// Every storage bucket the app uses. Empty when the app stores no files.
class StorageSchema {
  StorageSchema(List<StorageBucketSchema> buckets)
    : buckets = {for (final bucket in buckets) bucket.name: bucket} {
    if (buckets.length != this.buckets.length) {
      throw const SchemaParseException('Duplicate storage bucket names.');
    }
  }

  static final empty = StorageSchema(const []);

  final Map<String, StorageBucketSchema> buckets;

  bool get isEmpty => buckets.isEmpty;

  StorageBucketSchema bucket(String name) {
    final bucket = buckets[name];
    if (bucket == null) {
      throw SchemaParseException(
        'Unknown storage bucket "$name".',
        hint: buckets.isEmpty
            ? 'Declare one under `storage:` in onebase.yaml.'
            : 'Declared buckets: ${buckets.keys.join(', ')}.',
      );
    }
    return bucket;
  }
}

/// Validates a caller-supplied file path.
///
/// Paths become object keys, so anything that could escape the user's prefix
/// — `..`, absolute paths, backslashes, control characters — is rejected here
/// rather than being cleaned up and hoped for.
String validateStoragePath(String path) {
  if (path.isEmpty) {
    throw const StorageException('File path must not be empty.');
  }
  if (path.length > 1024) {
    throw const StorageException('File path must be 1024 characters or fewer.');
  }
  if (path.startsWith('/') || path.contains('\\')) {
    throw StorageException(
      'File path "$path" must be relative and use forward slashes.',
    );
  }
  final segments = path.split('/');
  for (final segment in segments) {
    if (segment.isEmpty) {
      throw StorageException('File path "$path" has an empty segment.');
    }
    if (segment == '.' || segment == '..') {
      throw StorageException(
        'File path "$path" must not contain "." or ".." segments.',
      );
    }
  }
  if (RegExp(r'[\x00-\x1f\x7f]').hasMatch(path)) {
    throw StorageException('File path "$path" contains control characters.');
  }
  return path;
}

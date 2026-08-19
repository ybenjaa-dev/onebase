import 'dart:typed_data';

import '../errors.dart';
import '../schema/schema.dart';
import '../schema/storage_schema.dart';
import '../sync/sync_api.dart';

/// One stored file, as the backend knows it.
class StorageFile {
  const StorageFile({
    required this.bucket,
    required this.path,
    this.size,
    this.contentType,
    this.updatedAt,
    this.owner,
  });

  final String bucket;
  final String path;
  final int? size;
  final String? contentType;
  final DateTime? updatedAt;

  /// The user who uploaded it. In a private bucket this is always you.
  final String? owner;

  @override
  String toString() => 'StorageFile($bucket/$path, $size bytes)';
}

/// File storage, Firebase-style.
///
/// ```dart
/// final ref = Onebase.storage.ref('avatars/me.png');
/// await ref.putData(bytes, contentType: 'image/png');
/// final url = await ref.getDownloadUrl();
/// ```
///
/// Bytes go straight from the device to your object store using a short-lived
/// URL the backend signs — they never pass through your server, so a large
/// upload costs it nothing.
///
/// Uploads need a connection. Unlike document writes they are not queued for
/// later, because holding file bytes in the local database would bloat it.
class OnebaseStorage {
  const OnebaseStorage(this._api, this._schema);

  final SyncApi _api;
  final OnebaseSchema _schema;

  /// A handle on `bucket/path`, e.g. `ref('avatars/me.png')`.
  ///
  /// The first segment is the bucket, which must be declared under `storage:`
  /// in `onebase.yaml`.
  StorageRef ref(String reference) {
    final slash = reference.indexOf('/');
    if (slash <= 0 || slash == reference.length - 1) {
      throw StorageException(
        'Storage reference "$reference" must be "<bucket>/<path>".',
        hint: _schema.storage.isEmpty
            ? 'Declare a bucket under `storage:` in onebase.yaml first.'
            : 'Declared buckets: ${_schema.storage.buckets.keys.join(', ')}.',
      );
    }
    return bucket(
      reference.substring(0, slash),
    ).file(reference.substring(slash + 1));
  }

  /// A handle on a whole bucket, for listing.
  StorageBucketRef bucket(String name) =>
      StorageBucketRef(_api, _schema.storage.bucket(name));
}

/// A bucket you can list.
class StorageBucketRef {
  const StorageBucketRef(this._api, this.schema);

  final SyncApi _api;
  final StorageBucketSchema schema;

  String get name => schema.name;

  /// A handle on one file in this bucket.
  StorageRef file(String path) =>
      StorageRef(_api, schema, validateStoragePath(path));

  /// Files in this bucket, newest first. A private bucket lists only yours.
  Future<List<StorageFile>> list({String? prefix}) async {
    final response = await _api.storage('list', {
      'bucket': name,
      'prefix': ?prefix,
    });
    return [
      for (final entry in (response['files'] as List? ?? const []))
        _fileFrom((entry as Map).cast<String, Object?>(), name),
    ];
  }
}

/// A handle on one file.
class StorageRef {
  const StorageRef(this._api, this.schema, this.path);

  final SyncApi _api;
  final StorageBucketSchema schema;
  final String path;

  String get bucket => schema.name;

  /// `bucket/path`, the form [OnebaseStorage.ref] accepts.
  String get reference => '$bucket/$path';

  /// Uploads [bytes] and returns the stored file.
  ///
  /// [contentType] defaults to a guess from the file extension. The backend
  /// signs the exact type and length, so the object store itself rejects an
  /// upload that does not match — the bucket's limits are enforced, not just
  /// advertised.
  ///
  /// For a `File`, pass `await file.readAsBytes()`; keeping `dart:io` out of
  /// this package is what lets it run on the web too.
  Future<StorageFile> putData(Uint8List bytes, {String? contentType}) async {
    final type = contentType ?? guessContentType(path);

    // Checked here as well as on the server so the failure is immediate and
    // legible, instead of a rejected upload after the bytes went out.
    if (!schema.allowsContentType(type)) {
      throw StorageException(
        'Bucket "$bucket" does not accept $type.',
        hint: 'Allowed: ${schema.contentTypes.join(', ')}.',
      );
    }
    final limit = schema.maxSizeBytes;
    if (limit != null && bytes.length > limit) {
      throw StorageException(
        'File is ${bytes.length} bytes; bucket "$bucket" allows $limit.',
      );
    }

    final signed = await _api.storage('upload-url', {
      'bucket': bucket,
      'path': path,
      'contentType': type,
      'size': bytes.length,
    });

    await _api.putSigned(
      signed['url']! as String,
      bytes,
      (signed['headers']! as Map).map(
        (key, value) => MapEntry(key.toString(), value.toString()),
      ),
    );

    // Recorded only once the bytes have landed, so a listing never shows a
    // file that failed to upload.
    await _api.storage('complete', {
      'bucket': bucket,
      'path': path,
      'contentType': type,
      'size': bytes.length,
    });

    return StorageFile(
      bucket: bucket,
      path: path,
      size: bytes.length,
      contentType: type,
      updatedAt: DateTime.now(),
    );
  }

  /// A URL for reading the file, valid for about an hour.
  ///
  /// Hand it to `Image.network`, a video player, or a browser. It carries its
  /// own authorization, so it works without your app's token — treat it as a
  /// secret and do not persist it.
  Future<String> getDownloadUrl() async {
    final response = await _api.storage('download-url', {
      'bucket': bucket,
      'path': path,
    });
    return response['url']! as String;
  }

  /// Deletes the file. Succeeds even if it was already gone.
  Future<void> delete() async {
    await _api.storage('delete', {'bucket': bucket, 'path': path});
  }

  @override
  String toString() => 'StorageRef($reference)';
}

StorageFile _fileFrom(Map<String, Object?> json, String bucket) {
  final updatedAt = json['updated_at'];
  return StorageFile(
    bucket: bucket,
    path: json['path']! as String,
    size: (json['size'] as num?)?.toInt(),
    contentType: json['content_type'] as String?,
    updatedAt: updatedAt is String ? DateTime.tryParse(updatedAt) : null,
    owner: json['owner'] as String?,
  );
}

/// Best-effort content type from a file extension.
///
/// Only the types a mobile app actually uploads; anything else falls back to
/// `application/octet-stream`, which every object store accepts.
String guessContentType(String path) {
  final dot = path.lastIndexOf('.');
  if (dot < 0) return 'application/octet-stream';
  return switch (path.substring(dot + 1).toLowerCase()) {
    'png' => 'image/png',
    'jpg' || 'jpeg' => 'image/jpeg',
    'gif' => 'image/gif',
    'webp' => 'image/webp',
    'heic' => 'image/heic',
    'svg' => 'image/svg+xml',
    'mp4' => 'video/mp4',
    'mov' => 'video/quicktime',
    'webm' => 'video/webm',
    'mp3' => 'audio/mpeg',
    'm4a' => 'audio/mp4',
    'wav' => 'audio/wav',
    'pdf' => 'application/pdf',
    'json' => 'application/json',
    'txt' => 'text/plain',
    'csv' => 'text/csv',
    'zip' => 'application/zip',
    _ => 'application/octet-stream',
  };
}

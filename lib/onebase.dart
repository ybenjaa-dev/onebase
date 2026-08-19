/// Firebase-like developer experience for MongoDB in Flutter.
///
/// Offline-first reactive collections backed by a local SQLite replica and one
/// tiny generated backend — no third-party sync service. Start with
/// [Onebase.init], then use [Onebase.collection].
library;

export 'src/auth/jwt_utils.dart' show JwtClaims, decodeJwt;
export 'src/auth/token_provider.dart';
export 'src/client/batch.dart' show WriteBatch;
export 'src/client/collection.dart';
export 'src/client/config.dart';
export 'src/client/onebase.dart';
export 'src/client/typed_collection.dart';
export 'src/errors.dart';
export 'src/query/cursor.dart' show Page, QueryCursor;
export 'src/query/pager.dart' show QueryPager;
export 'src/query/paging.dart' show defaultPageSize;
export 'src/query/query_builder.dart';
export 'src/schema/schema.dart';
export 'src/schema/storage_schema.dart'
    show StorageAccess, StorageBucketSchema, StorageSchema;
export 'src/storage/storage.dart'
    show OnebaseStorage, StorageBucketRef, StorageFile, StorageRef;
export 'src/sync/sync_engine.dart' show SyncSkippedWrites;
export 'src/sync/sync_status.dart';

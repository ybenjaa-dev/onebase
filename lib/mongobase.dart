/// Firebase-like developer experience for MongoDB in Flutter.
///
/// Offline-first reactive collections backed by a local SQLite replica and one
/// tiny generated backend — no third-party sync service. Start with
/// [Mongobase.init], then use [Mongobase.collection].
library;

export 'src/auth/jwt_utils.dart' show JwtClaims, decodeJwt;
export 'src/auth/token_provider.dart';
export 'src/client/collection.dart';
export 'src/client/config.dart';
export 'src/client/mongobase.dart';
export 'src/client/typed_collection.dart';
export 'src/errors.dart';
export 'src/query/query_builder.dart';
export 'src/schema/schema.dart';
export 'src/sync/sync_engine.dart' show SyncSkippedWrites;
export 'src/sync/sync_status.dart';

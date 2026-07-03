/// Firebase-like developer experience for MongoDB Atlas in Flutter.
///
/// Offline-first reactive collections synced through PowerSync — no backend
/// code required. Start with [MongoEasy.init], then use
/// [MongoEasy.collection].
library;

export 'package:powersync/powersync.dart' show SyncStatus;

export 'src/auth/jwt_utils.dart' show JwtClaims, decodeJwt;
export 'src/auth/token_provider.dart';
export 'src/client/collection.dart';
export 'src/client/config.dart';
export 'src/client/mongo_easy.dart';
export 'src/client/typed_collection.dart';
export 'src/errors.dart';
export 'src/query/query_builder.dart';
export 'src/schema/schema.dart';

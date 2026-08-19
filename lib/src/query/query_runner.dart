import '../schema/schema.dart';
import 'query_spec.dart';

/// Executes a [QuerySpec] against whatever holds the data.
///
/// Two implementations: the local SQLite replica (offline mode) and the
/// backend over HTTP (online mode). `MongoCollection` and `MongoQuery` are
/// written against this interface, so switching modes changes no app code.
abstract interface class QueryRunner {
  Future<List<Map<String, Object?>>> find(
      MongoCollectionSchema schema, QuerySpec spec);

  Future<int> count(MongoCollectionSchema schema, QuerySpec spec);

  /// A stream that re-emits whenever the result set changes.
  Stream<List<Map<String, Object?>>> watch(
      MongoCollectionSchema schema, QuerySpec spec);

  Future<Map<String, Object?>?> findById(
      MongoCollectionSchema schema, String id);
}

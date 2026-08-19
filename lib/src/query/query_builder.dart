import '../errors.dart';
import '../schema/schema.dart';
import 'filter.dart';
import 'local_query_runner.dart';
import 'query_runner.dart';
import 'query_spec.dart';

/// An immutable, chainable query — Firestore-style.
///
/// ```dart
/// final overdue = await Onebase.collection('todos')
///     .where('done', isEqualTo: false)
///     .where('due_at', isLessThan: DateTime.now())
///     .orderBy('due_at')
///     .limit(20)
///     .find();
/// ```
///
/// The same query runs against the local SQLite replica (offline mode) or the
/// backend (online mode) — nothing here changes between them.
class MongoQuery {
  MongoQuery(this._runner, this._schema) : _spec = const QuerySpec();

  MongoQuery._(this._runner, this._schema, this._spec);

  final QueryRunner _runner;
  final MongoCollectionSchema _schema;
  final QuerySpec _spec;

  /// The query as data. Useful for logging and tests.
  QuerySpec get spec => _spec;

  MongoQuery _copy(QuerySpec spec) => MongoQuery._(_runner, _schema, spec);

  /// Adds a condition. Provide exactly one operator argument.
  ///
  /// Supports nested json fields with dot-paths: `where('address.city',
  /// isEqualTo: 'Rabat')`.
  MongoQuery where(
    String field, {
    Object? isEqualTo,
    Object? isNotEqualTo,
    Object? isGreaterThan,
    Object? isGreaterThanOrEqualTo,
    Object? isLessThan,
    Object? isLessThanOrEqualTo,
    List<Object>? whereIn,
    bool? isNull,
  }) {
    // Fail fast at the call site: validates syntax, existence and json roots.
    resolveField(field, _schema);
    final filters = [
      if (isEqualTo != null) Filter.equals(field, isEqualTo),
      if (isNotEqualTo != null) Filter.notEquals(field, isNotEqualTo),
      if (isGreaterThan != null) Filter.greaterThan(field, isGreaterThan),
      if (isGreaterThanOrEqualTo != null)
        Filter.greaterThanOrEqual(field, isGreaterThanOrEqualTo),
      if (isLessThan != null) Filter.lessThan(field, isLessThan),
      if (isLessThanOrEqualTo != null)
        Filter.lessThanOrEqual(field, isLessThanOrEqualTo),
      if (whereIn != null) Filter.inList(field, whereIn),
      if (isNull != null) Filter.isNull(field, isNull: isNull),
    ];
    if (filters.length != 1) {
      throw QueryException(
        'where("$field") needs exactly one operator, got ${filters.length}.',
        hint: 'Chain multiple .where() calls to combine conditions (AND).',
      );
    }
    return _copy(_spec.copyWith(filters: [..._spec.filters, filters.single]));
  }

  MongoQuery orderBy(String field, {bool descending = false}) {
    resolveField(field, _schema);
    return _copy(_spec.copyWith(order: [..._spec.order, (field, descending)]));
  }

  MongoQuery limit(int count) {
    if (count <= 0) throw QueryException('limit($count) must be positive.');
    return _copy(_spec.copyWith(limit: count));
  }

  MongoQuery offset(int count) {
    if (count < 0) throw QueryException('offset($count) must not be negative.');
    return _copy(_spec.copyWith(offset: count));
  }

  /// Compiles the query to SQL. Exposed for testing.
  SqlFragment compile({bool count = false}) =>
      LocalQueryRunner.compile(_schema, _spec, count: count);

  /// Runs the query once and returns matching documents.
  Future<List<Map<String, Object?>>> find() => _runner.find(_schema, _spec);

  /// Returns the first matching document, or `null`.
  Future<Map<String, Object?>?> findOne() async {
    final results = await limit(1).find();
    return results.isEmpty ? null : results.first;
  }

  /// Number of matching documents.
  Future<int> count() => _runner.count(_schema, _spec);

  /// A reactive stream of results — like Firestore snapshots. Emits the
  /// current results immediately, then again on every change.
  Stream<List<Map<String, Object?>>> watch() => _runner.watch(_schema, _spec);
}

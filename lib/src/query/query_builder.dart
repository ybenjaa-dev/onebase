import '../client/sql_executor.dart';
import '../errors.dart';
import '../schema/schema.dart';
import '../schema/value_codec.dart';
import 'filter.dart';

/// An immutable, chainable query — Firestore-style, compiled to SQLite.
///
/// ```dart
/// final overdue = await MongoEasy.collection('todos')
///     .where('done', isEqualTo: false)
///     .where('due_at', isLessThan: DateTime.now())
///     .orderBy('due_at')
///     .limit(20)
///     .find();
/// ```
class MongoQuery {
  MongoQuery(this._executor, this._schema)
      : _filters = const [],
        _order = const [],
        _limit = null,
        _offset = null;

  MongoQuery._(this._executor, this._schema, this._filters, this._order,
      this._limit, this._offset);

  final SqlExecutor _executor;
  final MongoCollectionSchema _schema;
  final List<Filter> _filters;
  final List<(String, bool descending)> _order;
  final int? _limit;
  final int? _offset;

  MongoQuery _copy({
    List<Filter>? filters,
    List<(String, bool)>? order,
    int? limit,
    int? offset,
  }) {
    return MongoQuery._(_executor, _schema, filters ?? _filters,
        order ?? _order, limit ?? _limit, offset ?? _offset);
  }

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
    return _copy(filters: [..._filters, filters.single]);
  }

  MongoQuery orderBy(String field, {bool descending = false}) {
    resolveField(field, _schema);
    return _copy(order: [..._order, (field, descending)]);
  }

  MongoQuery limit(int count) {
    if (count <= 0) {
      throw QueryException('limit($count) must be positive.');
    }
    return _copy(limit: count);
  }

  MongoQuery offset(int count) {
    if (count < 0) {
      throw QueryException('offset($count) must not be negative.');
    }
    return _copy(offset: count);
  }

  /// Compiles the query. Exposed for testing.
  SqlFragment compile({bool count = false}) {
    final parameters = <Object?>[];
    final buffer =
        StringBuffer(count ? 'SELECT COUNT(*) AS c FROM ' : 'SELECT * FROM ');
    buffer.write('"${_schema.name}"');

    if (_filters.isNotEmpty) {
      final conditions = <String>[];
      for (final filter in _filters) {
        final fragment = filter.compile(_schema);
        conditions.add(fragment.sql);
        parameters.addAll(fragment.parameters);
      }
      buffer
        ..write(' WHERE ')
        ..write(conditions.join(' AND '));
    }

    if (!count && _order.isNotEmpty) {
      final terms = _order.map((entry) {
        final (field, descending) = entry;
        final column = resolveField(field, _schema);
        return '${column.sql}${descending ? ' DESC' : ' ASC'}';
      });
      buffer
        ..write(' ORDER BY ')
        ..write(terms.join(', '));
    }

    if (!count && _limit != null) {
      buffer.write(' LIMIT ?');
      parameters.add(_limit);
    }
    if (!count && _offset != null) {
      if (_limit == null) {
        // SQLite requires LIMIT before OFFSET.
        buffer.write(' LIMIT -1');
      }
      buffer.write(' OFFSET ?');
      parameters.add(_offset);
    }

    return SqlFragment(buffer.toString(), parameters);
  }

  /// Runs the query once and returns matching documents.
  Future<List<Map<String, Object?>>> find() async {
    final query = compile();
    final rows = await _executor.getAll(query.sql, query.parameters);
    return [for (final row in rows) _decodeRow(row)];
  }

  /// Returns the first matching document, or `null`.
  Future<Map<String, Object?>?> findOne() async {
    final results = await limit(1).find();
    return results.isEmpty ? null : results.first;
  }

  /// Number of matching documents.
  Future<int> count() async {
    final query = compile(count: true);
    final row = await _executor.getOptional(query.sql, query.parameters);
    return (row?['c'] as int?) ?? 0;
  }

  /// A reactive stream of results — like Firestore snapshots. Emits the
  /// current results immediately, then again on every local or synced change.
  Stream<List<Map<String, Object?>>> watch() {
    final query = compile();
    return _executor
        .watch(query.sql, parameters: query.parameters)
        .map((rows) => [for (final row in rows) _decodeRow(row)]);
  }

  Map<String, Object?> _decodeRow(Map<String, Object?> row) =>
      ValueCodec.decodeRow(row, _schema);
}

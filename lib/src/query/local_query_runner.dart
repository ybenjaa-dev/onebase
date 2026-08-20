import '../client/sql_executor.dart';
import '../errors.dart';
import '../schema/schema.dart';
import '../schema/value_codec.dart';
import 'cursor.dart';
import 'filter.dart';
import 'paging.dart';
import 'query_runner.dart';
import 'query_spec.dart';

/// Runs queries against the local SQLite replica.
///
/// Every value is parameterized and every identifier is validated against the
/// schema, so a query can never be injected through a field name.
class LocalQueryRunner implements QueryRunner {
  const LocalQueryRunner(this._executor);

  final SqlExecutor _executor;

  /// Compiles [spec] to SQL. Exposed for testing.
  static SqlFragment compile(
    MongoCollectionSchema schema,
    QuerySpec spec, {
    bool count = false,
  }) {
    final parameters = <Object?>[];
    final buffer = StringBuffer(
      count ? 'SELECT COUNT(*) AS c FROM ' : 'SELECT * FROM ',
    )..write('"${schema.name}"');

    final conditions = <String>[];
    for (final filter in spec.filters) {
      final fragment = filter.compile(schema);
      conditions.add(fragment.sql);
      parameters.addAll(fragment.parameters);
    }

    final cursor = spec.startAfter;
    if (cursor != null) {
      final keyset = _keysetCondition(schema, spec, cursor);
      conditions.add(keyset.sql);
      parameters.addAll(keyset.parameters);
    }

    if (conditions.isNotEmpty) {
      buffer
        ..write(' WHERE ')
        ..write(conditions.join(' AND '));
    }

    // Always ordered, even when the caller did not ask: paging compares
    // against a key order, and without an ORDER BY the rows arrive in whatever
    // order the plan happens to produce. Results are then also stable between
    // identical queries, which they otherwise are not.
    if (!count) {
      final terms = spec.effectiveOrder.map((entry) {
        final (field, descending) = entry;
        return '${resolveField(field, schema).sql}'
            '${descending ? ' DESC' : ' ASC'}';
      });
      buffer
        ..write(' ORDER BY ')
        ..write(terms.join(', '));
    }

    if (!count && spec.limit != null) {
      buffer.write(' LIMIT ?');
      parameters.add(spec.limit);
    }
    if (!count && spec.offset != null) {
      // SQLite requires LIMIT before OFFSET.
      if (spec.limit == null) buffer.write(' LIMIT -1');
      buffer.write(' OFFSET ?');
      parameters.add(spec.offset);
    }

    return SqlFragment(buffer.toString(), parameters);
  }

  /// Builds the "everything after this row" predicate.
  ///
  /// For a sort on (a, b) it expands lexicographically:
  ///
  ///     a > ?  OR  (a = ? AND b > ?)  OR  (a = ? AND b = ? AND id > ?)
  ///
  /// which is exactly the set of rows the sort places after the cursor. An
  /// index on the sort columns can seek straight to it, so the cost does not
  /// grow with how far the reader has scrolled.
  static SqlFragment _keysetCondition(
    MongoCollectionSchema schema,
    QuerySpec spec,
    QueryCursor cursor,
  ) {
    final order = spec.effectiveOrder;
    if (cursor.values.length != spec.order.length) {
      throw QueryException(
        'This cursor does not match the query it was used with.',
        hint: 'A cursor is only valid for the same orderBy it came from.',
      );
    }
    // effectiveOrder appends `id` only when the caller did not sort by it, so
    // the trailing key comes from the cursor's id in that case and from its
    // ordinary values when they already include it.
    final values = [
      for (var i = 0; i < order.length; i++)
        i < cursor.values.length ? cursor.values[i] : cursor.id,
    ];

    Object? encode(String field, Object? value) {
      if (field == 'id') return value;
      return ValueCodec.encode(
        value,
        schema.fieldType(field),
        field: field,
        collection: schema.name,
      );
    }

    final branches = <String>[];
    final parameters = <Object?>[];
    for (var i = 0; i < order.length; i++) {
      final terms = <String>[];
      for (var j = 0; j < i; j++) {
        final (field, _) = order[j];
        terms.add('${resolveField(field, schema).sql} = ?');
        parameters.add(encode(field, values[j]));
      }
      final (field, descending) = order[i];
      terms.add(
        '${resolveField(field, schema).sql} ${descending ? '<' : '>'} ?',
      );
      parameters.add(encode(field, values[i]));
      branches.add(
        terms.length == 1 ? terms.single : '(${terms.join(' AND ')})',
      );
    }

    return SqlFragment('(${branches.join(' OR ')})', parameters);
  }

  @override
  Future<List<Map<String, Object?>>> find(
    MongoCollectionSchema schema,
    QuerySpec spec,
  ) async {
    final query = compile(schema, spec);
    final rows = await _executor.getAll(query.sql, query.parameters);
    return [for (final row in rows) ValueCodec.decodeRow(row, schema)];
  }

  @override
  Future<int> count(MongoCollectionSchema schema, QuerySpec spec) async {
    final query = compile(schema, spec, count: true);
    final row = await _executor.getOptional(query.sql, query.parameters);
    return (row?['c'] as int?) ?? 0;
  }

  @override
  Future<Page<Map<String, Object?>>> page(
    MongoCollectionSchema schema,
    QuerySpec spec,
  ) async {
    final rows = await find(schema, pageSpec(spec));
    return buildPage(schema, spec, rows);
  }

  @override
  Stream<List<Map<String, Object?>>> watch(
    MongoCollectionSchema schema,
    QuerySpec spec,
  ) {
    final query = compile(schema, spec);
    return _executor
        .watch(query.sql, parameters: query.parameters)
        .map(
          (rows) => [for (final row in rows) ValueCodec.decodeRow(row, schema)],
        );
  }

  @override
  Future<Map<String, Object?>?> findById(
    MongoCollectionSchema schema,
    String id,
  ) async {
    final row = await _executor.getOptional(
      'SELECT * FROM "${schema.name}" WHERE id = ?',
      [id],
    );
    return row == null ? null : ValueCodec.decodeRow(row, schema);
  }
}

import '../client/sql_executor.dart';
import '../schema/schema.dart';
import '../schema/value_codec.dart';
import 'filter.dart';
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
    final buffer =
        StringBuffer(count ? 'SELECT COUNT(*) AS c FROM ' : 'SELECT * FROM ')
          ..write('"${schema.name}"');

    if (spec.filters.isNotEmpty) {
      final conditions = <String>[];
      for (final filter in spec.filters) {
        final fragment = filter.compile(schema);
        conditions.add(fragment.sql);
        parameters.addAll(fragment.parameters);
      }
      buffer
        ..write(' WHERE ')
        ..write(conditions.join(' AND '));
    }

    if (!count && spec.order.isNotEmpty) {
      final terms = spec.order.map((entry) {
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

  @override
  Future<List<Map<String, Object?>>> find(
      MongoCollectionSchema schema, QuerySpec spec) async {
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
  Stream<List<Map<String, Object?>>> watch(
      MongoCollectionSchema schema, QuerySpec spec) {
    final query = compile(schema, spec);
    return _executor.watch(query.sql, parameters: query.parameters).map(
        (rows) => [for (final row in rows) ValueCodec.decodeRow(row, schema)]);
  }

  @override
  Future<Map<String, Object?>?> findById(
      MongoCollectionSchema schema, String id) async {
    final row = await _executor
        .getOptional('SELECT * FROM "${schema.name}" WHERE id = ?', [id]);
    return row == null ? null : ValueCodec.decodeRow(row, schema);
  }
}

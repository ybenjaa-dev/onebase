import 'package:sqlite_async/sqlite_async.dart';

import '../client/sql_executor.dart';

/// [SqlExecutor] backed by the local SQLite replica.
///
/// `watch` uses sqlite_async's table-change detection: the query's source
/// tables are discovered with `EXPLAIN QUERY PLAN`, so a stream re-emits
/// whenever a local write or a synced change touches them.
class SqliteExecutor implements SqlExecutor {
  SqliteExecutor(this._db);

  final SqliteConnection _db;

  @override
  Future<List<Map<String, Object?>>> getAll(String sql,
      [List<Object?> parameters = const []]) async {
    final rows = await _db.getAll(sql, parameters);
    return [for (final row in rows) Map<String, Object?>.of(row)];
  }

  @override
  Future<Map<String, Object?>?> getOptional(String sql,
      [List<Object?> parameters = const []]) async {
    final row = await _db.getOptional(sql, parameters);
    return row == null ? null : Map<String, Object?>.of(row);
  }

  @override
  Future<void> execute(String sql,
      [List<Object?> parameters = const []]) async {
    await _db.execute(sql, parameters);
  }

  @override
  Stream<List<Map<String, Object?>>> watch(String sql,
      {List<Object?> parameters = const []}) {
    return _db
        .watch(sql, parameters: parameters)
        .map((rows) => [for (final row in rows) Map<String, Object?>.of(row)]);
  }
}

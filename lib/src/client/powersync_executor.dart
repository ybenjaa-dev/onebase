import 'package:powersync/powersync.dart';

import 'sql_executor.dart';

/// [SqlExecutor] backed by a [PowerSyncDatabase].
class PowerSyncExecutor implements SqlExecutor {
  PowerSyncExecutor(this._db);

  final PowerSyncDatabase _db;

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
  Future<void> execute(String sql, [List<Object?> parameters = const []]) {
    return _db.execute(sql, parameters);
  }

  @override
  Stream<List<Map<String, Object?>>> watch(String sql,
      {List<Object?> parameters = const []}) {
    return _db
        .watch(sql, parameters: parameters)
        .map((rows) => [for (final row in rows) Map<String, Object?>.of(row)]);
  }
}

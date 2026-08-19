/// Minimal SQL surface mongo_easy needs from the local database.
///
/// Implemented by the SQLite adapter in production and by fakes in tests.
abstract interface class SqlExecutor {
  Future<List<Map<String, Object?>>> getAll(String sql,
      [List<Object?> parameters]);

  Future<Map<String, Object?>?> getOptional(String sql,
      [List<Object?> parameters]);

  Future<void> execute(String sql, [List<Object?> parameters]);

  Stream<List<Map<String, Object?>>> watch(String sql,
      {List<Object?> parameters});
}

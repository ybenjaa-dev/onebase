import 'dart:async';

import 'package:mongo_easy/src/client/sql_executor.dart';

class RecordedCall {
  RecordedCall(this.sql, this.parameters);

  final String sql;
  final List<Object?> parameters;
}

class FakeExecutor implements SqlExecutor {
  final List<RecordedCall> calls = [];
  List<Map<String, Object?>> rows = [];

  RecordedCall get lastCall => calls.last;

  @override
  Future<List<Map<String, Object?>>> getAll(String sql,
      [List<Object?> parameters = const []]) async {
    calls.add(RecordedCall(sql, parameters));
    return rows;
  }

  @override
  Future<Map<String, Object?>?> getOptional(String sql,
      [List<Object?> parameters = const []]) async {
    calls.add(RecordedCall(sql, parameters));
    return rows.isEmpty ? null : rows.first;
  }

  @override
  Future<void> execute(String sql,
      [List<Object?> parameters = const []]) async {
    calls.add(RecordedCall(sql, parameters));
  }

  @override
  Stream<List<Map<String, Object?>>> watch(String sql,
      {List<Object?> parameters = const []}) {
    calls.add(RecordedCall(sql, parameters));
    return Stream.value(rows);
  }
}

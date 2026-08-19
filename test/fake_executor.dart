import 'dart:async';

import 'package:onebase/src/client/document_writer.dart';
import 'package:onebase/src/client/sql_executor.dart';

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
  Future<List<Map<String, Object?>>> getAll(
    String sql, [
    List<Object?> parameters = const [],
  ]) async {
    calls.add(RecordedCall(sql, parameters));
    return rows;
  }

  @override
  Future<Map<String, Object?>?> getOptional(
    String sql, [
    List<Object?> parameters = const [],
  ]) async {
    calls.add(RecordedCall(sql, parameters));
    return rows.isEmpty ? null : rows.first;
  }

  @override
  Future<void> execute(
    String sql, [
    List<Object?> parameters = const [],
  ]) async {
    calls.add(RecordedCall(sql, parameters));
  }

  @override
  Stream<List<Map<String, Object?>>> watch(
    String sql, {
    List<Object?> parameters = const [],
  }) {
    calls.add(RecordedCall(sql, parameters));
    return Stream.value(rows);
  }
}

class RecordedWrite {
  RecordedWrite(
    this.op,
    this.collection,
    this.id,
    this.data, [
    this.transactionId,
  ]);

  final String op;
  final String collection;
  final String id;
  final Map<String, Object?>? data;
  final String? transactionId;
}

class FakeWriter implements DocumentWriter {
  final List<RecordedWrite> writes = [];

  RecordedWrite get lastWrite => writes.last;

  @override
  Future<void> insert(
    String collection,
    String id,
    Map<String, Object?> encoded, {
    String? transactionId,
  }) async {
    writes.add(RecordedWrite('put', collection, id, encoded, transactionId));
  }

  @override
  Future<void> update(
    String collection,
    String id,
    Map<String, Object?> encoded, {
    String? transactionId,
  }) async {
    writes.add(RecordedWrite('patch', collection, id, encoded, transactionId));
  }

  @override
  Future<void> delete(
    String collection,
    String id, {
    String? transactionId,
  }) async {
    writes.add(RecordedWrite('delete', collection, id, null, transactionId));
  }
}

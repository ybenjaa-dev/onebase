import 'package:uuid/uuid.dart';

import '../client/document_writer.dart';
import 'local_store.dart';

/// Writes to the local replica and queues the change for upload.
///
/// Writes sharing a `transactionId` are uploaded as one group and applied by
/// the backend inside a single MongoDB transaction.
class LocalWriter implements DocumentWriter {
  LocalWriter(this._store, {Uuid? uuid}) : _uuid = uuid ?? const Uuid();

  final LocalStore _store;
  final Uuid _uuid;

  @override
  Future<void> insert(
    String collection,
    String id,
    Map<String, Object?> encoded, {
    String? transactionId,
  }) => _store.insert(
    collection,
    id,
    encoded,
    transactionId: transactionId ?? _uuid.v4(),
  );

  @override
  Future<void> update(
    String collection,
    String id,
    Map<String, Object?> encoded, {
    String? transactionId,
  }) => _store.update(
    collection,
    id,
    encoded,
    transactionId: transactionId ?? _uuid.v4(),
  );

  @override
  Future<void> delete(String collection, String id, {String? transactionId}) =>
      _store.delete(collection, id, transactionId: transactionId ?? _uuid.v4());
}

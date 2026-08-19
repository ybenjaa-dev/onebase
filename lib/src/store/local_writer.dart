import 'package:uuid/uuid.dart';

import '../client/document_writer.dart';
import 'local_store.dart';

/// Writes to the local replica and queues the change for upload.
///
/// Each call is its own transaction group today; `LocalStore` already carries
/// the grouping so batched writes can share one server-side transaction.
class LocalWriter implements DocumentWriter {
  LocalWriter(this._store, {Uuid? uuid}) : _uuid = uuid ?? const Uuid();

  final LocalStore _store;
  final Uuid _uuid;

  @override
  Future<void> insert(
    String collection,
    String id,
    Map<String, Object?> encoded,
  ) => _store.insert(collection, id, encoded, transactionId: _uuid.v4());

  @override
  Future<void> update(
    String collection,
    String id,
    Map<String, Object?> encoded,
  ) => _store.update(collection, id, encoded, transactionId: _uuid.v4());

  @override
  Future<void> delete(String collection, String id) =>
      _store.delete(collection, id, transactionId: _uuid.v4());
}

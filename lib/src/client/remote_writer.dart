import 'package:uuid/uuid.dart';

import '../errors.dart';
import '../store/local_store.dart';
import '../sync/sync_api.dart';
import 'document_writer.dart';

/// Sends writes straight to the backend — online mode.
///
/// There is no queue: a failed write throws so your UI can show the error and
/// offer a retry, rather than silently pretending it succeeded. Use offline
/// mode if you want writes to survive a dropped connection.
class RemoteWriter implements DocumentWriter {
  RemoteWriter(this._api, {Uuid? uuid}) : _uuid = uuid ?? const Uuid();

  final SyncApi _api;
  final Uuid _uuid;

  @override
  Future<void> insert(
    String collection,
    String id,
    Map<String, Object?> encoded,
  ) => _send('put', collection, id, encoded);

  @override
  Future<void> update(
    String collection,
    String id,
    Map<String, Object?> encoded,
  ) => _send('patch', collection, id, encoded);

  @override
  Future<void> delete(String collection, String id) =>
      _send('delete', collection, id, null);

  Future<void> _send(
    String op,
    String collection,
    String id,
    Map<String, Object?>? data,
  ) async {
    final result = await _api.push([
      OutboxOp(
        seq: 0,
        transactionId: _uuid.v4(),
        op: op,
        collection: collection,
        documentId: id,
        data: data,
      ),
    ]);

    if (result.skipped.isNotEmpty) {
      final reason = result.skipped.first['reason'] ?? 'refused by the backend';
      throw UploadException(
        'The backend refused this $op on "$collection": $reason',
        hint:
            'This is a permanent refusal, not a network problem — the '
            'document is probably owned by another user, or the collection '
            'is missing from the deployed schema.',
      );
    }
  }
}

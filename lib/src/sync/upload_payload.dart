import 'package:powersync/powersync.dart';

/// JSON contract between the client and the generated upload endpoint.
///
/// ```json
/// {
///   "transaction_id": 12,
///   "ops": [
///     {"op": "put", "collection": "todos", "id": "abc", "data": {...}},
///     {"op": "patch", "collection": "todos", "id": "abc", "data": {...}},
///     {"op": "delete", "collection": "todos", "id": "abc"}
///   ]
/// }
/// ```
///
/// The generated backend templates decode exactly this shape — keep them in
/// sync when changing it.
Map<String, Object?> buildUploadPayload(CrudTransaction transaction) {
  return {
    'transaction_id': transaction.transactionId,
    'ops': [
      for (final entry in transaction.crud)
        {
          'op': switch (entry.op) {
            UpdateType.put => 'put',
            UpdateType.patch => 'patch',
            UpdateType.delete => 'delete',
          },
          'collection': entry.table,
          'id': entry.id,
          if (entry.opData != null) 'data': entry.opData,
        },
    ],
  };
}

import 'package:flutter_test/flutter_test.dart';
import 'package:mongo_easy/src/sync/upload_payload.dart';
import 'package:powersync/powersync.dart';

void main() {
  test('builds the JSON contract the backend templates expect', () {
    final transaction = CrudTransaction(
      transactionId: 7,
      crud: [
        CrudEntry(1, UpdateType.put, 'todos', 'id-1', 7,
            {'title': 'milk', 'done': 0}),
        CrudEntry(2, UpdateType.patch, 'todos', 'id-1', 7, {'done': 1}),
        CrudEntry(3, UpdateType.delete, 'todos', 'id-2', 7, null),
      ],
      complete: ({String? writeCheckpoint}) async {},
    );

    expect(buildUploadPayload(transaction), {
      'transaction_id': 7,
      'ops': [
        {
          'op': 'put',
          'collection': 'todos',
          'id': 'id-1',
          'data': {'title': 'milk', 'done': 0},
        },
        {
          'op': 'patch',
          'collection': 'todos',
          'id': 'id-1',
          'data': {'done': 1},
        },
        {'op': 'delete', 'collection': 'todos', 'id': 'id-2'},
      ],
    });
  });
}

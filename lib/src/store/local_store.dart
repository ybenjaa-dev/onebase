import 'dart:convert';

import 'package:sqlite_async/sqlite_async.dart';
import 'package:uuid/uuid.dart';

import '../schema/schema.dart';

/// Table holding local writes that have not reached the backend yet.
const outboxTable = '_onebase_outbox';

/// Table holding sync bookkeeping (per-collection cursors).
const metaTable = '_onebase_meta';

/// Column stamped by the backend with the server-side modification time.
/// Present on every synced row; used as the pull watermark.
const updatedAtColumn = '_updated_at';

/// A pending local write, as queued in the outbox.
class OutboxOp {
  const OutboxOp({
    required this.seq,
    required this.transactionId,
    required this.op,
    required this.collection,
    required this.documentId,
    this.data,
  });

  final int seq;

  /// Groups ops written together so the backend can apply them atomically.
  final String transactionId;

  /// `put`, `patch`, `inc` or `delete`.
  final String op;
  final String collection;
  final String documentId;

  /// Encoded field values; null for deletes.
  final Map<String, Object?>? data;

  Map<String, Object?> toJson() => {
    'op': op,
    'collection': collection,
    'id': documentId,
    if (data != null) 'data': data,
  };

  static OutboxOp fromRow(Map<String, Object?> row) => OutboxOp(
    seq: row['seq']! as int,
    transactionId: row['tx_id']! as String,
    op: row['op']! as String,
    collection: row['collection']! as String,
    documentId: row['doc_id']! as String,
    data: row['data'] == null
        ? null
        : (jsonDecode(row['data']! as String) as Map).cast<String, Object?>(),
  );
}

/// The local SQLite replica: every collection as a real table, plus the
/// outbox and sync cursors.
///
/// This is what makes reads instant and writes work offline. The sync engine
/// on top of it talks only to the generated backend.
class LocalStore {
  LocalStore(this.db, this.schema);

  final SqliteConnection db;
  final OnebaseSchema schema;
  final Uuid _uuid = const Uuid();

  /// Creates the tables for [schema] if they do not exist yet.
  ///
  /// Adding a field to `onebase.yaml` adds a column on the next launch;
  /// existing rows keep their data. Removing a field leaves the column in
  /// place (harmless) so a downgrade cannot lose data.
  Future<void> migrate() async {
    await db.writeTransaction((tx) async {
      await tx.execute('''
CREATE TABLE IF NOT EXISTS $outboxTable (
  seq INTEGER PRIMARY KEY AUTOINCREMENT,
  tx_id TEXT NOT NULL,
  op TEXT NOT NULL,
  collection TEXT NOT NULL,
  doc_id TEXT NOT NULL,
  data TEXT
)''');
      await tx.execute('''
CREATE TABLE IF NOT EXISTS $metaTable (
  key TEXT PRIMARY KEY NOT NULL,
  value TEXT
)''');

      for (final collection in schema.collections.values) {
        if (collection.sync.isRemoteOnly) continue;
        await tx.execute(
          'CREATE TABLE IF NOT EXISTS "${collection.name}" ('
          'id TEXT PRIMARY KEY NOT NULL, '
          '"$updatedAtColumn" TEXT)',
        );

        final existing = <String>{
          for (final row in await tx.getAll(
            'PRAGMA table_info("${collection.name}")',
          ))
            row['name']! as String,
        };
        for (final MapEntry(key: field, value: type)
            in collection.fields.entries) {
          if (existing.contains(field)) continue;
          await tx.execute(
            'ALTER TABLE "${collection.name}" '
            'ADD COLUMN "$field" ${_affinity(type)}',
          );
        }
      }
    });
  }

  static String _affinity(MongoFieldType type) => switch (type) {
    MongoFieldType.int || MongoFieldType.bool => 'INTEGER',
    MongoFieldType.double => 'REAL',
    MongoFieldType.text ||
    MongoFieldType.datetime ||
    MongoFieldType.json => 'TEXT',
  };

  // ---------------------------------------------------------------- writes

  /// Inserts [encoded] locally and queues it for upload, atomically.
  Future<void> insert(
    String collection,
    String id,
    Map<String, Object?> encoded, {
    required String transactionId,
  }) async {
    await db.writeTransaction((tx) async {
      await _applyPut(tx, collection, id, encoded);
      await _enqueue(tx, transactionId, 'put', collection, id, encoded);
    });
  }

  /// Applies a partial update locally and queues it, atomically.
  Future<void> update(
    String collection,
    String id,
    Map<String, Object?> encoded, {
    required String transactionId,
  }) async {
    await db.writeTransaction((tx) async {
      await _applyPatch(tx, collection, id, encoded);
      await _enqueue(tx, transactionId, 'patch', collection, id, encoded);
    });
  }

  /// Adds [deltas] to numeric fields, locally and in the outbox, atomically.
  ///
  /// Unlike [update], this is safe to apply more than once from more than
  /// one device: two pending increments to the same field add up instead of
  /// one overwriting the other, and replaying one on top of a fresher server
  /// snapshot (see [applyPull]) still lands the right total rather than
  /// clobbering whatever the snapshot just brought down.
  Future<void> increment(
    String collection,
    String id,
    Map<String, num> deltas, {
    required String transactionId,
  }) async {
    await db.writeTransaction((tx) async {
      await _applyIncrement(tx, collection, id, deltas);
      await _enqueue(
        tx,
        transactionId,
        'inc',
        collection,
        id,
        deltas.cast<String, Object?>(),
      );
    });
  }

  /// Deletes locally and queues it, atomically.
  Future<void> delete(
    String collection,
    String id, {
    required String transactionId,
  }) async {
    await db.writeTransaction((tx) async {
      await tx.execute('DELETE FROM "$collection" WHERE id = ?', [id]);
      await _enqueue(tx, transactionId, 'delete', collection, id, null);
    });
  }

  Future<void> _enqueue(
    SqliteWriteContext tx,
    String transactionId,
    String op,
    String collection,
    String id,
    Map<String, Object?>? data,
  ) {
    return tx.execute(
      'INSERT INTO $outboxTable (tx_id, op, collection, doc_id, data) '
      'VALUES (?, ?, ?, ?, ?)',
      [
        transactionId,
        op,
        collection,
        id,
        data == null ? null : jsonEncode(data),
      ],
    );
  }

  static Future<void> _applyPut(
    SqliteWriteContext tx,
    String collection,
    String id,
    Map<String, Object?> encoded,
  ) {
    final columns = ['id', ...encoded.keys.map((k) => '"$k"')];
    final values = <Object?>[id, ...encoded.values];
    final placeholders = List.filled(columns.length, '?').join(', ');
    return tx.execute(
      'INSERT OR REPLACE INTO "$collection" (${columns.join(', ')}) '
      'VALUES ($placeholders)',
      values,
    );
  }

  static Future<void> _applyPatch(
    SqliteWriteContext tx,
    String collection,
    String id,
    Map<String, Object?> encoded,
  ) async {
    if (encoded.isEmpty) return;
    final assignments = encoded.keys.map((k) => '"$k" = ?').join(', ');
    await tx.execute('UPDATE "$collection" SET $assignments WHERE id = ?', [
      ...encoded.values,
      id,
    ]);
  }

  /// `COALESCE(...,0)` mirrors MongoDB's own `$inc`: a field that has never
  /// been set is treated as starting from zero rather than staying null.
  static Future<void> _applyIncrement(
    SqliteWriteContext tx,
    String collection,
    String id,
    Map<String, num> deltas,
  ) async {
    if (deltas.isEmpty) return;
    final assignments = deltas.keys
        .map((k) => '"$k" = COALESCE("$k", 0) + ?')
        .join(', ');
    await tx.execute('UPDATE "$collection" SET $assignments WHERE id = ?', [
      ...deltas.values,
      id,
    ]);
  }

  // ------------------------------------------------------------- outbox

  /// Pending ops in the order they were made.
  Future<List<OutboxOp>> pendingOps({int limit = 500}) async {
    final rows = await db.getAll(
      'SELECT * FROM $outboxTable ORDER BY seq ASC LIMIT ?',
      [limit],
    );
    return [for (final row in rows) OutboxOp.fromRow(row)];
  }

  Future<int> pendingCount() async {
    final row = await db.getOptional('SELECT COUNT(*) AS c FROM $outboxTable');
    return (row?['c'] as int?) ?? 0;
  }

  /// Removes ops the backend has confirmed.
  Future<void> clearOps(Iterable<int> sequences) async {
    if (sequences.isEmpty) return;
    final placeholders = List.filled(sequences.length, '?').join(', ');
    await db.execute(
      'DELETE FROM $outboxTable WHERE seq IN ($placeholders)',
      sequences.toList(),
    );
  }

  // --------------------------------------------------------------- cursors

  /// The pull watermark for [collection] — the newest `_updated_at` applied.
  Future<String?> cursor(String collection) async {
    final row = await db.getOptional(
      'SELECT value FROM $metaTable WHERE key = ?',
      ['cursor:$collection'],
    );
    return row?['value'] as String?;
  }

  Future<void> setCursor(String collection, String value) async {
    await db.execute(
      'INSERT OR REPLACE INTO $metaTable (key, value) VALUES (?, ?)',
      ['cursor:$collection', value],
    );
  }

  // ------------------------------------------------------------ pull apply

  /// Applies a batch of server documents for [collection].
  ///
  /// Rows flagged `_deleted` are removed. The whole batch plus the new cursor
  /// land in one transaction, so a reader never sees half a sync. Pending
  /// local writes are replayed on top afterwards, keeping optimistic UI state
  /// visible until the backend confirms it.
  Future<void> applyPull(
    String collection,
    List<Map<String, Object?>> documents,
    String? nextCursor, {
    Set<String>? replayOnly,
  }) async {
    if (documents.isEmpty && nextCursor == null) return;
    await db.writeTransaction((tx) async {
      for (final document in documents) {
        final id = document['id'] ?? document['_id'];
        if (id is! String) continue;
        if (document['_deleted'] == true || document['_deleted'] == 1) {
          await tx.execute('DELETE FROM "$collection" WHERE id = ?', [id]);
          continue;
        }
        final encoded = <String, Object?>{
          for (final MapEntry(:key, :value) in document.entries)
            if (key != 'id' && key != '_id' && key != '_deleted') key: value,
        };
        await _applyPut(tx, collection, id, encoded);
      }

      if (nextCursor != null) {
        await tx.execute(
          'INSERT OR REPLACE INTO $metaTable (key, value) VALUES (?, ?)',
          ['cursor:$collection', nextCursor],
        );
      }

      // Re-apply anything still queued so the server snapshot does not
      // visually undo a write the user just made.
      //
      // Scoped where possible: a realtime event touches one document, and
      // replaying the whole queue for each of them would turn a busy
      // collection into quadratic work. An empty queue — the steady state —
      // costs one cheap lookup.
      final List<Map<String, Object?>> pending;
      if (replayOnly != null) {
        if (replayOnly.isEmpty) return;
        final placeholders = List.filled(replayOnly.length, '?').join(', ');
        pending = await tx.getAll(
          'SELECT * FROM $outboxTable WHERE collection = ? '
          'AND doc_id IN ($placeholders) ORDER BY seq ASC',
          [collection, ...replayOnly],
        );
      } else {
        pending = await tx.getAll(
          'SELECT * FROM $outboxTable WHERE collection = ? ORDER BY seq ASC',
          [collection],
        );
      }
      for (final row in pending) {
        final op = OutboxOp.fromRow(row);
        switch (op.op) {
          case 'put':
            await _applyPut(tx, collection, op.documentId, op.data ?? const {});
          case 'patch':
            await _applyPatch(
              tx,
              collection,
              op.documentId,
              op.data ?? const {},
            );
          case 'inc':
            await _applyIncrement(
              tx,
              collection,
              op.documentId,
              (op.data ?? const {}).cast<String, num>(),
            );
          case 'delete':
            await tx.execute('DELETE FROM "$collection" WHERE id = ?', [
              op.documentId,
            ]);
        }
      }
    });
  }

  // -------------------------------------------------------------- backup

  /// Every locally held row, keyed by collection name.
  ///
  /// This is the escape hatch for offline-first: the device is the source of
  /// truth, so if the backend ever disappears for good, this snapshot is
  /// what is left to hand back to the user. It includes edits still waiting
  /// in the outbox — they are already applied to these tables optimistically
  /// — and every value is a plain String/int/double/null, so the result is
  /// `jsonEncode`-able as-is. Nothing here talks to the network.
  Future<Map<String, List<Map<String, Object?>>>> exportAll() async {
    final result = <String, List<Map<String, Object?>>>{};
    for (final collection in schema.collections.values) {
      if (collection.sync.isRemoteOnly) continue;
      final rows = await db.getAll('SELECT * FROM "${collection.name}"');
      result[collection.name] = [
        for (final row in rows) Map<String, Object?>.of(row),
      ];
    }
    return result;
  }

  /// Restores rows produced by [exportAll], e.g. after a reinstall or when
  /// pointing an existing user at a new backend.
  ///
  /// A collection name the current schema no longer declares is skipped
  /// rather than thrown on, so an export taken from an older version of the
  /// app still restores what it can. When [reupload] is true every row is
  /// also queued in the outbox, so the next sync sends it to whichever
  /// backend this client is now configured against; pass false to restore
  /// silently against the backend the data already came from.
  Future<void> importAll(
    Map<String, List<Map<String, Object?>>> data, {
    required bool reupload,
  }) async {
    await db.writeTransaction((tx) async {
      for (final MapEntry(key: name, value: rows) in data.entries) {
        final collection = schema.collections[name];
        if (collection == null || collection.sync.isRemoteOnly) continue;
        for (final row in rows) {
          final id = row['id'];
          if (id is! String) continue;
          final encoded = <String, Object?>{
            for (final MapEntry(:key, :value) in row.entries)
              if (key != 'id' && key != updatedAtColumn) key: value,
          };
          await _applyPut(tx, name, id, encoded);
          if (reupload) {
            await _enqueue(tx, _uuid.v4(), 'put', name, id, encoded);
          }
        }
      }
    });
  }

  /// Wipes every synced table, the outbox and all cursors — used on sign-out
  /// so the next user cannot see cached documents.
  Future<void> clear() async {
    await db.writeTransaction((tx) async {
      for (final collection in schema.collections.values) {
        if (collection.sync.isRemoteOnly) continue;
        await tx.execute('DELETE FROM "${collection.name}"');
      }
      await tx.execute('DELETE FROM $outboxTable');
      await tx.execute('DELETE FROM $metaTable');
    });
  }
}

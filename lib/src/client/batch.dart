import 'package:uuid/uuid.dart';

import '../errors.dart';
import '../schema/schema.dart';
import '../schema/value_codec.dart';
import 'document_writer.dart';

/// Several writes that land together, or not at all.
///
/// The backend applies every operation in a batch inside one MongoDB
/// transaction, so a half-applied batch is not a state your data can reach —
/// the case that otherwise leaves an order without its line items, or a
/// balance debited without the matching credit.
///
/// ```dart
/// await Onebase.instance.batch()
///   ..insert('orders', {'total': 42})
///   ..update('inventory', stockId, {'count': 9})
///   ..commit();
/// ```
///
/// Nothing is written until [commit]. Offline, the whole batch is queued and
/// uploaded as one unit, so it stays atomic even if the app is killed before
/// it syncs.
class WriteBatch {
  WriteBatch(this._writer, this._schema, {String? ownerId, Uuid? uuid})
    : _ownerId = ownerId,
      _uuid = uuid ?? const Uuid(),
      _transactionId = (uuid ?? const Uuid()).v4();

  final DocumentWriter _writer;
  final OnebaseSchema _schema;

  /// The signed-in user, filled into owner fields the way single writes do.
  final String? _ownerId;
  final Uuid _uuid;
  final String _transactionId;

  final List<Future<void> Function()> _operations = [];
  bool _committed = false;

  /// Number of operations queued so far.
  int get length => _operations.length;

  bool get isEmpty => _operations.isEmpty;

  /// Queues an insert and returns the id the document will have.
  ///
  /// The id is generated now rather than at commit, so you can reference it
  /// from later operations in the same batch.
  String insert(
    String collection,
    Map<String, Object?> document, {
    String? id,
  }) {
    _ensureOpen();
    final schema = _schema.collection(collection);
    final data = Map<String, Object?>.of(document);

    final owner = schema.ownerField;
    if (owner != null && data[owner] == null) {
      final ownerId = _ownerId;
      if (ownerId == null) {
        throw const InvalidTokenException(
          'Cannot auto-fill the owner field: no user is signed in.',
          hint:
              'Sign in before writing, or set the owner field explicitly in '
              'the document.',
        );
      }
      data[owner] = ownerId;
    }

    final documentId = id ?? _uuid.v4();
    final encoded = _encode(schema, data);
    _operations.add(
      () => _writer.insert(
        collection,
        documentId,
        encoded,
        transactionId: _transactionId,
      ),
    );
    return documentId;
  }

  /// Queues a partial update.
  void update(String collection, String id, Map<String, Object?> changes) {
    _ensureOpen();
    if (changes.isEmpty) {
      throw const QueryException('update() received no changes.');
    }
    final schema = _schema.collection(collection);
    final encoded = _encode(schema, changes);
    _operations.add(
      () => _writer.update(
        collection,
        id,
        encoded,
        transactionId: _transactionId,
      ),
    );
  }

  /// Queues a delete.
  void delete(String collection, String id) {
    _ensureOpen();
    // Validates the collection now rather than at commit, so a typo surfaces
    // where it was written.
    _schema.collection(collection);
    _operations.add(
      () => _writer.delete(collection, id, transactionId: _transactionId),
    );
  }

  /// Applies every queued operation as one unit.
  ///
  /// A batch can only be committed once.
  Future<void> commit() async {
    _ensureOpen();
    _committed = true;
    for (final operation in _operations) {
      await operation();
    }
  }

  Map<String, Object?> _encode(
    MongoCollectionSchema schema,
    Map<String, Object?> document,
  ) => {
    for (final MapEntry(:key, :value) in document.entries)
      key: ValueCodec.encode(
        value,
        schema.fieldType(key),
        field: key,
        collection: schema.name,
      ),
  };

  void _ensureOpen() {
    if (_committed) {
      throw const ConfigurationException(
        'This batch has already been committed.',
        hint: 'Start a new batch for further writes.',
      );
    }
  }
}

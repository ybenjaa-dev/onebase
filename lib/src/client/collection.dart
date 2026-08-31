import '../errors.dart';
import '../query/query_builder.dart';
import '../query/query_runner.dart';
import '../schema/schema.dart';
import '../schema/value_codec.dart';
import 'document_writer.dart';
import 'typed_collection.dart';

/// A Firestore-style handle on one MongoDB collection.
///
/// In offline mode all reads hit the local SQLite replica (instant, works
/// offline) and writes are applied locally first and uploaded in the
/// background. In online mode both go straight to your backend. The API is
/// identical either way.
class MongoCollection {
  MongoCollection(
    this._runner,
    this._writer,
    this._schema, {
    required Future<String> Function() currentUserId,
    required String Function() newId,
  }) : _currentUserId = currentUserId,
       _newId = newId;

  final QueryRunner _runner;
  final DocumentWriter _writer;
  final MongoCollectionSchema _schema;
  final Future<String> Function() _currentUserId;
  final String Function() _newId;

  String get name => _schema.name;

  MongoQuery get _query => MongoQuery(_runner, _schema);

  /// Inserts [document] and returns its generated id.
  ///
  /// When the collection declares an `owner_field` and the document does not
  /// set it, it is filled with the signed-in user's id automatically.
  Future<String> insert(Map<String, Object?> document) async {
    final data = Map<String, Object?>.of(document);
    final owner = _schema.ownerField;
    if (owner != null && data[owner] == null) {
      data[owner] = await _currentUserId();
    }

    final id = _newId();
    await _writer.insert(_schema.name, id, _encode(data));
    return id;
  }

  /// Applies a partial update to the document with [id]. Only the provided
  /// fields change — like MongoDB `$set`.
  Future<void> update(String id, Map<String, Object?> changes) async {
    if (changes.isEmpty) {
      throw const QueryException('update() received no changes.');
    }
    await _writer.update(_schema.name, id, _encode(changes));
  }

  /// Adds [deltas] to numeric fields on the document with [id] — atomic on
  /// the server via MongoDB's `$inc`.
  ///
  /// Unlike [update], this is safe for two devices to do at once: both
  /// deltas land, in whichever order they arrive, because addition
  /// commutes. `update(id, {'count': 5})` cannot do this — it always means
  /// "set it to 5," so the second device to write always erases the first.
  /// Use `increment` for balances, stock counts, or anything else where the
  /// change matters more than the value one device happened to see last.
  ///
  /// Every key must be a declared `int` or `double` field.
  Future<void> increment(String id, Map<String, num> deltas) async {
    if (deltas.isEmpty) {
      throw const QueryException('increment() received no deltas.');
    }
    await _writer.increment(_schema.name, id, _encodeDeltas(deltas));
  }

  Map<String, num> _encodeDeltas(Map<String, num> deltas) {
    final encoded = <String, num>{};
    for (final MapEntry(:key, :value) in deltas.entries) {
      final type = _schema.fieldType(key);
      if (type != MongoFieldType.int && type != MongoFieldType.double) {
        throw QueryException(
          'increment() field "$key" on "${_schema.name}" is not numeric.',
          hint:
              'Only int and double fields can be incremented — "$key" is '
              '${type.name}.',
        );
      }
      encoded[key] =
          ValueCodec.encode(value, type, field: key, collection: _schema.name)
              as num;
    }
    return encoded;
  }

  Map<String, Object?> _encode(Map<String, Object?> document) {
    return {
      for (final MapEntry(:key, :value) in document.entries)
        key: ValueCodec.encode(
          value,
          _schema.fieldType(key),
          field: key,
          collection: _schema.name,
        ),
    };
  }

  /// Deletes the document with [id]. No-op when it does not exist.
  Future<void> delete(String id) => _writer.delete(_schema.name, id);

  /// Fetches one document by [id], or `null`.
  Future<Map<String, Object?>?> findById(String id) =>
      _runner.findById(_schema, id);

  /// All documents in the collection (synced for this user).
  Future<List<Map<String, Object?>>> find() => _query.find();

  /// First matching document, or `null`.
  Future<Map<String, Object?>?> findOne() => _query.findOne();

  /// Number of documents.
  Future<int> count() => _query.count();

  /// Reactive stream of all documents — emits on every change.
  Stream<List<Map<String, Object?>>> watch() => _query.watch();

  /// Starts a filtered query. See [MongoQuery.where].
  MongoQuery where(
    String field, {
    Object? isEqualTo,
    Object? isNotEqualTo,
    Object? isGreaterThan,
    Object? isGreaterThanOrEqualTo,
    Object? isLessThan,
    Object? isLessThanOrEqualTo,
    List<Object>? whereIn,
    bool? isNull,
  }) {
    return _query.where(
      field,
      isEqualTo: isEqualTo,
      isNotEqualTo: isNotEqualTo,
      isGreaterThan: isGreaterThan,
      isGreaterThanOrEqualTo: isGreaterThanOrEqualTo,
      isLessThan: isLessThan,
      isLessThanOrEqualTo: isLessThanOrEqualTo,
      whereIn: whereIn,
      isNull: isNull,
    );
  }

  /// Starts an ordered query. See [MongoQuery.orderBy].
  MongoQuery orderBy(String field, {bool descending = false}) =>
      _query.orderBy(field, descending: descending);

  /// Limits the number of results. See [MongoQuery.limit].
  MongoQuery limit(int count) => _query.limit(count);

  /// A typed view over this collection using your model's `fromJson`/`toJson`.
  ///
  /// ```dart
  /// final todos = Onebase.collection('todos').withConverter<Todo>(
  ///   fromJson: Todo.fromJson,
  ///   toJson: (todo) => todo.toJson(),
  /// );
  /// final Stream<List<Todo>> live = todos.watch();
  /// ```
  TypedCollection<T> withConverter<T>({
    required T Function(Map<String, Object?> json) fromJson,
    required Map<String, Object?> Function(T value) toJson,
  }) {
    return TypedCollection<T>(this, fromJson: fromJson, toJson: toJson);
  }
}

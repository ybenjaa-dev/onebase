import '../errors.dart';
import '../query/query_builder.dart';
import '../schema/schema.dart';
import '../schema/value_codec.dart';
import 'sql_executor.dart';
import 'typed_collection.dart';

/// A Firestore-style handle on one MongoDB collection.
///
/// All reads hit the local SQLite replica (instant, works offline); all
/// writes are applied locally first and uploaded in the background.
class MongoCollection {
  MongoCollection(
    this._executor,
    this._schema, {
    required Future<String> Function() currentUserId,
    required String Function() newId,
  })  : _currentUserId = currentUserId,
        _newId = newId;

  final SqlExecutor _executor;
  final MongoCollectionSchema _schema;
  final Future<String> Function() _currentUserId;
  final String Function() _newId;

  String get name => _schema.name;

  MongoQuery get _query => MongoQuery(_executor, _schema);

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
    final columns = <String>['id'];
    final values = <Object?>[id];
    for (final MapEntry(:key, :value) in data.entries) {
      final type = _schema.fieldType(key);
      columns.add('"$key"');
      values.add(
          ValueCodec.encode(value, type, field: key, collection: _schema.name));
    }

    final placeholders = List.filled(columns.length, '?').join(', ');
    await _executor.execute(
      'INSERT INTO "${_schema.name}" (${columns.join(', ')}) '
      'VALUES ($placeholders)',
      values,
    );
    return id;
  }

  /// Applies a partial update to the document with [id]. Only the provided
  /// fields change — like MongoDB `$set`.
  Future<void> update(String id, Map<String, Object?> changes) async {
    if (changes.isEmpty) {
      throw const QueryException('update() received no changes.');
    }
    final assignments = <String>[];
    final values = <Object?>[];
    for (final MapEntry(:key, :value) in changes.entries) {
      final type = _schema.fieldType(key);
      assignments.add('"$key" = ?');
      values.add(
          ValueCodec.encode(value, type, field: key, collection: _schema.name));
    }
    values.add(id);
    await _executor.execute(
      'UPDATE "${_schema.name}" SET ${assignments.join(', ')} WHERE id = ?',
      values,
    );
  }

  /// Deletes the document with [id]. No-op when it does not exist.
  Future<void> delete(String id) {
    return _executor
        .execute('DELETE FROM "${_schema.name}" WHERE id = ?', [id]);
  }

  /// Fetches one document by [id], or `null`.
  Future<Map<String, Object?>?> findById(String id) async {
    final row = await _executor
        .getOptional('SELECT * FROM "${_schema.name}" WHERE id = ?', [id]);
    return row == null ? null : ValueCodec.decodeRow(row, _schema);
  }

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
  /// final todos = MongoEasy.collection('todos').withConverter<Todo>(
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

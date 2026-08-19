import 'dart:async';

import '../schema/schema.dart';
import '../schema/value_codec.dart';
import '../sync/sync_api.dart';
import 'query_runner.dart';
import 'query_spec.dart';
import 'query_wire.dart';

/// Runs queries against the backend — online mode, no local replica.
///
/// `watch` re-runs the query when the realtime channel says the collection
/// changed, or on [pollInterval] when realtime is unavailable. Either way it
/// only emits when the result set actually differs, so a rebuild never fires
/// for nothing.
class RemoteQueryRunner implements QueryRunner {
  RemoteQueryRunner(
    this._api, {
    Stream<String>? changes,
    this.pollInterval = const Duration(seconds: 5),
  }) : _changes = changes;

  final SyncApi _api;

  /// Emits the name of a collection whenever the backend reports a change.
  final Stream<String>? _changes;

  /// Fallback cadence when no realtime channel is connected.
  final Duration pollInterval;

  @override
  Future<List<Map<String, Object?>>> find(
    MongoCollectionSchema schema,
    QuerySpec spec,
  ) async {
    final documents = await _api.query(encodeQuery(schema, spec));
    return [for (final document in documents) _decode(document, schema)];
  }

  @override
  Future<int> count(MongoCollectionSchema schema, QuerySpec spec) =>
      _api.queryCount(encodeQuery(schema, spec));

  @override
  Future<Map<String, Object?>?> findById(
    MongoCollectionSchema schema,
    String id,
  ) async {
    final document = await _api.queryById(schema.name, id);
    return document == null ? null : _decode(document, schema);
  }

  @override
  Stream<List<Map<String, Object?>>> watch(
    MongoCollectionSchema schema,
    QuerySpec spec,
  ) {
    final controller = StreamController<List<Map<String, Object?>>>();
    StreamSubscription<String>? changeSubscription;
    Timer? timer;
    var closed = false;
    var running = false;
    String? previous;

    Future<void> refresh() async {
      if (closed || running) return;
      running = true;
      try {
        final results = await find(schema, spec);
        // Emit only on a real change; the fingerprint is cheap next to a
        // widget rebuild.
        final fingerprint = results.toString();
        if (fingerprint != previous) {
          previous = fingerprint;
          if (!controller.isClosed) controller.add(results);
        }
      } on Object catch (error, stackTrace) {
        if (!controller.isClosed) controller.addError(error, stackTrace);
      } finally {
        running = false;
      }
    }

    controller
      ..onListen = () {
        unawaited(refresh());
        final changes = _changes;
        if (changes != null) {
          changeSubscription = changes
              .where((collection) => collection == schema.name)
              .listen((_) => unawaited(refresh()));
        }
        // Kept even with realtime connected: it is the safety net for a
        // dropped stream, and the only mechanism when the host cannot hold
        // long-lived connections.
        timer = Timer.periodic(pollInterval, (_) => unawaited(refresh()));
      }
      ..onCancel = () async {
        closed = true;
        timer?.cancel();
        await changeSubscription?.cancel();
      };

    return controller.stream;
  }

  Map<String, Object?> _decode(
    Map<String, Object?> document,
    MongoCollectionSchema schema,
  ) => ValueCodec.decodeRow(document, schema);
}

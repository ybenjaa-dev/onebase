import 'dart:async';

import '../errors.dart';
import '../schema/schema.dart';
import '../store/local_store.dart';
import 'sync_api.dart';
import 'sync_status.dart';

/// Drives the local replica towards the backend: push queued writes, pull
/// changes, repeat.
///
/// Push always runs before pull so a local write is never briefly overwritten
/// by a stale server snapshot. Failures never throw into app code — they land
/// in [status] and the loop retries with exponential backoff.
class SyncEngine {
  SyncEngine({
    required LocalStore store,
    required SyncApi api,
    required OnebaseSchema schema,
    Duration interval = const Duration(seconds: 5),
    Duration maxBackoff = const Duration(minutes: 5),
  })  : _store = store,
        _api = api,
        _schema = schema,
        _interval = interval,
        _maxBackoff = maxBackoff;

  final LocalStore _store;
  final SyncApi _api;
  final OnebaseSchema _schema;
  final Duration _interval;
  final Duration _maxBackoff;

  final _statusController = StreamController<SyncStatus>.broadcast();
  final _firstSync = Completer<void>();

  SyncStatus _status = const SyncStatus();
  Timer? _timer;
  bool _running = false;
  bool _syncing = false;
  int _failures = 0;

  /// Current snapshot.
  SyncStatus get status => _status;

  /// Live status updates — drive a sync indicator from this.
  Stream<SyncStatus> get statusStream => _statusController.stream;

  /// Completes after the first successful sync. Useful to gate a splash
  /// screen; on later launches local data is already there, so prefer
  /// rendering immediately and letting the stream update.
  Future<void> get firstSync => _firstSync.future;

  /// Starts the loop and kicks off an immediate sync.
  void start() {
    if (_running) return;
    _running = true;
    _schedule(Duration.zero);
  }

  /// Stops the loop. Local reads and writes keep working.
  void stop() {
    _running = false;
    _timer?.cancel();
    _timer = null;
  }

  /// Runs one sync round trip now, regardless of the schedule.
  ///
  /// Returns true when it completed without error. Never throws.
  Future<bool> syncNow() async {
    if (_syncing) return _status.connected;
    _syncing = true;
    try {
      _emit(_status.copyWith(uploading: true, clearError: true));
      await _push();

      _emit(_status.copyWith(uploading: false, downloading: true));
      await _pull();

      _failures = 0;
      _emit(_status.copyWith(
        connected: true,
        downloading: false,
        uploading: false,
        pendingWrites: await _store.pendingCount(),
        lastSyncedAt: DateTime.now(),
        clearError: true,
      ));
      if (!_firstSync.isCompleted) _firstSync.complete();
      return true;
    } on Object catch (error) {
      _failures++;
      _emit(_status.copyWith(
        connected: false,
        downloading: false,
        uploading: false,
        pendingWrites: await _pendingCountSafe(),
        offlineReason: error is InvalidTokenException
            ? SyncOffline.signedOut
            : SyncOffline.unreachable,
        error: error,
      ));
      return false;
    } finally {
      _syncing = false;
      if (_running) _schedule(_nextDelay());
    }
  }

  Future<void> _push() async {
    while (true) {
      final ops = await _store.pendingOps();
      if (ops.isEmpty) return;

      final result = await _api.push(ops);
      // Skipped ops are permanent refusals (not owned, unknown collection,
      // malformed). Keeping them would wedge the queue forever, so they are
      // dropped along with the applied ones and surfaced in the status.
      await _store.clearOps(ops.map((op) => op.seq));
      if (result.skipped.isNotEmpty) {
        _emit(_status.copyWith(error: SyncSkippedWrites(result.skipped)));
      }
      if (ops.length < 500) return;
    }
  }

  Future<void> _pull() async {
    for (final collection in _schema.collections.keys) {
      var cursor = await _store.cursor(collection);
      // Drain pages so a long offline period catches up in one sync.
      for (var page = 0; page < 50; page++) {
        final result = await _api.pull(collection, cursor);
        if (result.documents.isEmpty && result.cursor == null) break;
        await _store.applyPull(collection, result.documents, result.cursor);
        cursor = result.cursor ?? cursor;
        if (!result.hasMore) break;
      }
    }
  }

  Future<int> _pendingCountSafe() async {
    try {
      return await _store.pendingCount();
    } on Object {
      return _status.pendingWrites;
    }
  }

  /// Exponential backoff, capped, so a dead backend is not hammered.
  Duration _nextDelay() {
    if (_failures == 0) return _interval;
    final scaled = _interval * (1 << (_failures - 1).clamp(0, 10));
    return scaled > _maxBackoff ? _maxBackoff : scaled;
  }

  void _schedule(Duration delay) {
    _timer?.cancel();
    _timer = Timer(delay, () {
      if (_running) unawaited(syncNow());
    });
  }

  void _emit(SyncStatus status) {
    _status = status;
    if (!_statusController.isClosed) _statusController.add(status);
  }

  Future<void> close() async {
    stop();
    await _statusController.close();
    _api.close();
  }
}

/// Reported through [SyncStatus.error] when the backend refused some writes.
///
/// These are permanent refusals — the ops are dropped from the queue rather
/// than retried forever. Each entry carries the collection, id and reason.
class SyncSkippedWrites implements Exception {
  const SyncSkippedWrites(this.ops);

  final List<Map<String, Object?>> ops;

  @override
  String toString() =>
      'The backend refused ${ops.length} write(s) and they were discarded: '
      '$ops';
}

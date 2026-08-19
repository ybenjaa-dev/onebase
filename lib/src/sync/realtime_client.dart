import 'dart:async';
import 'dart:convert';

import 'sync_api.dart';

/// One change the backend pushed to this device.
class RealtimeEvent {
  const RealtimeEvent(this.collection, this.document);

  final String collection;

  /// The full document, or `{id, _deleted: true}` when it was removed.
  final Map<String, Object?> document;

  bool get isDelete => document['_deleted'] == true;
}

/// Server-Sent Events channel carrying MongoDB change-stream events.
///
/// This is what makes realtime mode realtime: the backend watches MongoDB and
/// pushes committed changes down as they happen, instead of the client asking
/// every few seconds.
///
/// The connection is expected to drop — hosts time long requests out, phones
/// change networks. Reconnection is automatic with exponential backoff, and
/// the periodic sync remains the safety net that guarantees nothing is missed
/// while the stream is down.
class RealtimeClient {
  RealtimeClient({
    required SyncApi api,
    required List<String> collections,
    Duration retryDelay = const Duration(seconds: 2),
    Duration maxRetryDelay = const Duration(minutes: 2),
  })  : _api = api,
        _collections = collections,
        _retryDelay = retryDelay,
        _maxRetryDelay = maxRetryDelay;

  final SyncApi _api;
  final List<String> _collections;
  final Duration _retryDelay;
  final Duration _maxRetryDelay;

  final _events = StreamController<RealtimeEvent>.broadcast();
  final _connected = StreamController<bool>.broadcast();

  StreamSubscription<String>? _lines;
  Timer? _retry;
  bool _running = false;
  bool _isConnected = false;
  int _failures = 0;

  /// Changes pushed by the backend.
  Stream<RealtimeEvent> get events => _events.stream;

  /// Whether the stream is currently established.
  bool get isConnected => _isConnected;

  /// Connection state changes — drive a "live" indicator from this.
  Stream<bool> get connectionState => _connected.stream;

  void start() {
    if (_running) return;
    _running = true;
    unawaited(_connect());
  }

  Future<void> stop() async {
    _running = false;
    _retry?.cancel();
    _retry = null;
    await _lines?.cancel();
    _lines = null;
    _setConnected(false);
  }

  Future<void> _connect() async {
    if (!_running) return;
    try {
      final response = await _api.openStream(_collections);
      if (response.statusCode != 200) {
        throw StateError('stream returned HTTP ${response.statusCode}');
      }

      _failures = 0;
      _setConnected(true);

      // SSE frames are separated by blank lines; we only need `data:`.
      final buffer = StringBuffer();
      _lines = response.stream
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(
        (line) {
          if (line.isEmpty) {
            _emitFrame(buffer.toString());
            buffer.clear();
            return;
          }
          if (line.startsWith('data:')) {
            buffer.write(line.substring(5).trim());
          }
        },
        onDone: _scheduleReconnect,
        onError: (Object _) => _scheduleReconnect(),
        cancelOnError: true,
      );
    } on Object {
      _scheduleReconnect();
    }
  }

  void _emitFrame(String payload) {
    if (payload.isEmpty) return;
    try {
      final json = jsonDecode(payload);
      if (json is! Map) return;
      final collection = json['collection'];
      final document = json['document'];
      if (collection is! String || document is! Map) return;
      if (!_events.isClosed) {
        _events.add(
          RealtimeEvent(collection, document.cast<String, Object?>()),
        );
      }
    } on FormatException {
      // A keepalive or a partially flushed frame — the next one will be whole.
    }
  }

  void _scheduleReconnect() {
    _setConnected(false);
    _lines?.cancel();
    _lines = null;
    if (!_running) return;

    _failures++;
    final scaled = _retryDelay * (1 << (_failures - 1).clamp(0, 8));
    final delay = scaled > _maxRetryDelay ? _maxRetryDelay : scaled;
    _retry?.cancel();
    _retry = Timer(delay, () => unawaited(_connect()));
  }

  void _setConnected(bool value) {
    if (_isConnected == value) return;
    _isConnected = value;
    if (!_connected.isClosed) _connected.add(value);
  }

  Future<void> close() async {
    await stop();
    await _events.close();
    await _connected.close();
  }
}

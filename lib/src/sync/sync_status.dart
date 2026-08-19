/// Why the client is not currently talking to the backend.
enum SyncOffline {
  /// Signed out — [SyncEngine] stays idle until a token appears.
  signedOut,

  /// The last attempt failed (no network, backend down, 5xx).
  unreachable,

  /// Sync has not been started yet.
  notStarted,
}

/// A snapshot of the sync engine's state.
///
/// Mirrors what an app needs to render an honest status indicator: whether
/// data is flowing, whether local writes are still waiting, and what went
/// wrong if anything did.
class SyncStatus {
  const SyncStatus({
    this.connected = false,
    this.downloading = false,
    this.uploading = false,
    this.pendingWrites = 0,
    this.lastSyncedAt,
    this.offlineReason = SyncOffline.notStarted,
    this.error,
  });

  /// True when the last sync round trip succeeded.
  final bool connected;

  /// A pull is in flight.
  final bool downloading;

  /// A push is in flight.
  final bool uploading;

  /// Local writes not yet confirmed by the backend.
  final int pendingWrites;

  /// When the last successful sync completed.
  final DateTime? lastSyncedAt;

  /// Why [connected] is false. Meaningless while [connected].
  final SyncOffline offlineReason;

  /// The last error, kept so the UI can show a reason and a retry.
  final Object? error;

  /// True once a first successful sync has happened.
  bool get hasSynced => lastSyncedAt != null;

  /// True when everything local has reached the server.
  bool get isUpToDate => connected && pendingWrites == 0;

  SyncStatus copyWith({
    bool? connected,
    bool? downloading,
    bool? uploading,
    int? pendingWrites,
    DateTime? lastSyncedAt,
    SyncOffline? offlineReason,
    Object? error,
    bool clearError = false,
  }) {
    return SyncStatus(
      connected: connected ?? this.connected,
      downloading: downloading ?? this.downloading,
      uploading: uploading ?? this.uploading,
      pendingWrites: pendingWrites ?? this.pendingWrites,
      lastSyncedAt: lastSyncedAt ?? this.lastSyncedAt,
      offlineReason: offlineReason ?? this.offlineReason,
      error: clearError ? null : (error ?? this.error),
    );
  }

  @override
  String toString() => 'SyncStatus(connected: $connected, '
      'downloading: $downloading, uploading: $uploading, '
      'pendingWrites: $pendingWrites, lastSyncedAt: $lastSyncedAt, '
      'offlineReason: $offlineReason, error: $error)';
}

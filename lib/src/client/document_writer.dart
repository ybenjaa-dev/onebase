/// Where a collection's writes go.
///
/// Offline mode writes to the local replica and queues for upload; online
/// mode will post straight to the backend. Keeping this behind an interface
/// is what lets both modes share the same collection API.
abstract interface class DocumentWriter {
  /// Values are already encoded for storage by `ValueCodec`.
  Future<void> insert(
      String collection, String id, Map<String, Object?> encoded);

  Future<void> update(
      String collection, String id, Map<String, Object?> encoded);

  Future<void> delete(String collection, String id);
}

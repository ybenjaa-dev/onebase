/// Where a collection's writes go.
///
/// Offline mode writes to the local replica and queues for upload; online mode
/// posts straight to the backend. Keeping this behind an interface is what lets
/// both modes share the same collection API.
///
/// [transactionId] groups writes that must land together. Passing the same id
/// for several writes makes the backend apply them in one MongoDB transaction —
/// all of them or none. Omit it and each write is its own transaction.
abstract interface class DocumentWriter {
  /// Values are already encoded for storage by `ValueCodec`.
  Future<void> insert(
    String collection,
    String id,
    Map<String, Object?> encoded, {
    String? transactionId,
  });

  Future<void> update(
    String collection,
    String id,
    Map<String, Object?> encoded, {
    String? transactionId,
  });

  /// Adds [deltas] to numeric fields — atomic on the server (`$inc`), so
  /// concurrent increments from different devices always both land, in
  /// either order, instead of one overwriting the other the way [update]
  /// would.
  Future<void> increment(
    String collection,
    String id,
    Map<String, num> deltas, {
    String? transactionId,
  });

  Future<void> delete(String collection, String id, {String? transactionId});
}

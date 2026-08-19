import 'cursor.dart';
import 'filter.dart';

/// A query as data: what to match, how to order, how much to take.
///
/// Built by `MongoQuery` and handed to whichever runner is active — the local
/// SQLite replica in offline mode, or the backend in online mode. Keeping the
/// query as data is what lets both modes share one API.
class QuerySpec {
  const QuerySpec({
    this.filters = const [],
    this.order = const [],
    this.limit,
    this.offset,
    this.startAfter,
  });

  final List<Filter> filters;
  final List<(String field, bool descending)> order;
  final int? limit;
  final int? offset;

  /// Keyset position to resume from. Set by `startAfter`, and preferred over
  /// [offset] because it does not degrade as the reader scrolls.
  final QueryCursor? startAfter;

  /// The sort actually executed: whatever was requested, then `id`.
  ///
  /// Two rows sharing a sort value would otherwise come back in an arbitrary
  /// and unstable order, which breaks paging — the boundary row could repeat
  /// or vanish between pages.
  List<(String field, bool descending)> get effectiveOrder => [
    ...order,
    if (!order.any((entry) => entry.$1 == 'id'))
      ('id', order.isNotEmpty && order.last.$2),
  ];

  QuerySpec copyWith({
    List<Filter>? filters,
    List<(String, bool)>? order,
    int? limit,
    int? offset,
    QueryCursor? startAfter,
  }) {
    return QuerySpec(
      filters: filters ?? this.filters,
      order: order ?? this.order,
      limit: limit ?? this.limit,
      offset: offset ?? this.offset,
      startAfter: startAfter ?? this.startAfter,
    );
  }
}

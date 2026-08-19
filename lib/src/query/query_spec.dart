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
  });

  final List<Filter> filters;
  final List<(String field, bool descending)> order;
  final int? limit;
  final int? offset;

  QuerySpec copyWith({
    List<Filter>? filters,
    List<(String, bool)>? order,
    int? limit,
    int? offset,
  }) {
    return QuerySpec(
      filters: filters ?? this.filters,
      order: order ?? this.order,
      limit: limit ?? this.limit,
      offset: offset ?? this.offset,
    );
  }
}

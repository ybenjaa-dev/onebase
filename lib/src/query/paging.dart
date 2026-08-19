import '../schema/schema.dart';
import 'cursor.dart';
import 'query_spec.dart';

/// Default rows per page when a query does not set a limit.
const defaultPageSize = 50;

/// Turns raw rows into a [Page].
///
/// Both runners fetch one row more than asked for: if it comes back, there is
/// another page. That costs a single extra row and avoids a second round trip
/// or a `count` to answer "is there more?".
Page<Map<String, Object?>> buildPage(
  MongoCollectionSchema schema,
  QuerySpec spec,
  List<Map<String, Object?>> rows,
) {
  final size = spec.limit ?? defaultPageSize;
  final hasMore = rows.length > size;
  final items = hasMore ? rows.sublist(0, size) : rows;

  QueryCursor? cursor;
  if (items.isNotEmpty) {
    final last = items.last;
    cursor = QueryCursor([
      for (final (field, _) in spec.order) last[field],
    ], last['id']! as String);
  }

  return Page(items: items, cursor: cursor, hasMore: hasMore);
}

/// The spec to actually execute for a page: one extra row, so the caller can
/// tell whether another page exists.
QuerySpec pageSpec(QuerySpec spec) =>
    spec.copyWith(limit: (spec.limit ?? defaultPageSize) + 1);

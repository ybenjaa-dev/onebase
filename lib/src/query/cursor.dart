import 'dart:convert';

import '../errors.dart';

/// An opaque marker for "continue after this row".
///
/// It carries the sort-key values of the last row a page returned, plus its
/// id. That is what makes paging keyset-based rather than offset-based: the
/// next page is found by seeking straight to the values, so page 500 costs the
/// same as page 1. Offset paging has to walk and discard everything before it,
/// which is what makes deep scrolling slow on a large collection.
///
/// It also means inserts and deletes during scrolling cannot shift the window
/// under the reader — the classic offset bug where a new row at the top makes
/// the next page repeat an item.
class QueryCursor {
  const QueryCursor(this.values, this.id);

  /// One value per `orderBy` field, in order.
  final List<Object?> values;

  /// The last row's id, used as the final tiebreaker so rows sharing a sort
  /// value still have a total order.
  final String id;

  /// Encodes to a string safe to hand to a client or put in a URL.
  String encode() =>
      base64Url.encode(utf8.encode(jsonEncode({'v': values, 'i': id})));

  static QueryCursor decode(String encoded) {
    try {
      final json =
          jsonDecode(
                utf8.decode(base64Url.decode(base64Url.normalize(encoded))),
              )
              as Map<String, Object?>;
      return QueryCursor(
        (json['v'] as List).cast<Object?>(),
        json['i']! as String,
      );
    } on Object {
      throw QueryException(
        'Invalid page cursor.',
        hint:
            'Pass back the cursor from the previous page unchanged, or omit '
            'it to start from the beginning.',
      );
    }
  }

  @override
  String toString() => 'QueryCursor($values, $id)';
}

/// One page of results.
class Page<T> {
  const Page({
    required this.items,
    required this.cursor,
    required this.hasMore,
  });

  final List<T> items;

  /// Pass to `startAfter` to fetch the next page. Null when [items] is empty.
  final QueryCursor? cursor;

  /// Whether the backend had more rows after this page.
  final bool hasMore;

  bool get isEmpty => items.isEmpty;
  bool get isNotEmpty => items.isNotEmpty;

  /// Converts the items while keeping the paging state.
  Page<R> map<R>(R Function(T item) convert) => Page<R>(
    items: [for (final item in items) convert(item)],
    cursor: cursor,
    hasMore: hasMore,
  );
}

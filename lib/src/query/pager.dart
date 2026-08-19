import 'dart:async';

import 'cursor.dart';

/// Accumulates pages for an infinite-scrolling list.
///
/// Holds everything loaded so far, knows whether more exists, and refuses to
/// run two loads at once — the mistake that makes a scroll listener fire the
/// same page three times and show duplicates.
///
/// ```dart
/// final pager = OnebaseDb.todos.orderBy('created_at').pager(pageSize: 20);
/// await pager.loadMore();
///
/// ListView.builder(
///   itemCount: pager.items.length + (pager.hasMore ? 1 : 0),
///   itemBuilder: (context, index) {
///     if (index >= pager.items.length) {
///       pager.loadMore();            // safe to call repeatedly
///       return const CircularProgressIndicator();
///     }
///     return TodoTile(pager.items[index]);
///   },
/// );
/// ```
///
/// Listen to [changes] to rebuild, or wrap it in whatever state management you
/// use — it is a plain object with no Flutter dependency.
class QueryPager<T> {
  QueryPager({required Future<Page<T>> Function(QueryCursor? after) fetch})
    : _fetch = fetch;

  final Future<Page<T>> Function(QueryCursor? after) _fetch;
  final _controller = StreamController<QueryPager<T>>.broadcast();

  final List<T> _items = [];
  QueryCursor? _cursor;
  bool _hasMore = true;
  bool _loading = false;
  Object? _error;

  /// Everything loaded so far, in order.
  List<T> get items => List.unmodifiable(_items);

  /// False once the backend reported no further rows.
  bool get hasMore => _hasMore;

  /// True while a page is in flight.
  bool get isLoading => _loading;

  /// The last failure, if the most recent load failed. Cleared on success.
  Object? get error => _error;

  /// True before the first page has loaded.
  bool get isInitialLoad => _items.isEmpty && _loading;

  /// Emits after every state change, so a widget can rebuild.
  Stream<QueryPager<T>> get changes => _controller.stream;

  /// Loads the next page. A no-op while one is already loading or once the end
  /// is reached, so a scroll listener can call it as often as it likes.
  ///
  /// Never throws — a failure lands in [error] and leaves what is already
  /// loaded on screen.
  Future<void> loadMore() async {
    if (_loading || !_hasMore) return;
    _loading = true;
    _emit();

    try {
      final page = await _fetch(_cursor);
      _items.addAll(page.items);
      _cursor = page.cursor ?? _cursor;
      _hasMore = page.hasMore;
      _error = null;
    } on Object catch (error) {
      _error = error;
    } finally {
      _loading = false;
      _emit();
    }
  }

  /// Retries the page that failed, keeping what is already loaded.
  Future<void> retry() {
    if (_error == null) return Future.value();
    _error = null;
    return loadMore();
  }

  /// Drops everything and loads the first page again — for pull-to-refresh.
  Future<void> refresh() async {
    _items.clear();
    _cursor = null;
    _hasMore = true;
    _error = null;
    _emit();
    await loadMore();
  }

  void _emit() {
    if (!_controller.isClosed) _controller.add(this);
  }

  /// Releases the change stream. Call from your widget's dispose.
  Future<void> dispose() => _controller.close();
}

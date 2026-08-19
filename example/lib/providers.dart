import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:onebase/onebase.dart';

import 'onebase_schema.g.dart';
import 'services/auth_service.dart';

/// Overridden in main() with the loaded instance.
final authServiceProvider =
    Provider<AuthService>((ref) => throw UnimplementedError());

class AuthNotifier extends Notifier<AsyncValue<String?>> {
  @override
  AsyncValue<String?> build() =>
      AsyncValue.data(ref.read(authServiceProvider).email);

  Future<void> signIn(String email) async {
    final auth = ref.read(authServiceProvider);
    state = const AsyncValue.loading();
    try {
      await auth.signIn(email);
      await Onebase.instance.refreshToken();
      state = AsyncValue.data(auth.email);
    } on Object catch (error, stackTrace) {
      state = AsyncValue.error(error, stackTrace);
    }
  }

  Future<void> signOut() async {
    final auth = ref.read(authServiceProvider);
    await Onebase.instance.clearLocalData();
    await auth.signOut();
    await Onebase.instance.refreshToken();
    state = const AsyncValue.data(null);
  }
}

final authProvider =
    NotifierProvider<AuthNotifier, AsyncValue<String?>>(AuthNotifier.new);

// No hand-written model, no converter wiring — OnebaseDb.todos is
// generated from onebase.yaml and already returns Todo.
final todosCollectionProvider =
    Provider<TypedCollection<Todo>>((ref) => OnebaseDb.todos);

final todosProvider = StreamProvider.autoDispose<List<Todo>>((ref) {
  return ref
      .watch(todosCollectionProvider)
      .orderBy('created_at', descending: true)
      .watch();
});

final syncStatusProvider =
    StreamProvider<SyncStatus>((ref) => Onebase.instance.statusStream);

/// Whether the realtime channel is live, for the "live" badge.
final realtimeProvider =
    StreamProvider<bool>((ref) => Onebase.instance.realtimeState);

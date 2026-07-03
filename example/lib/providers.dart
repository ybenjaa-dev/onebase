import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:mongo_easy/mongo_easy.dart';

import 'models/todo.dart';
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
      await MongoEasy.instance.refreshToken();
      state = AsyncValue.data(auth.email);
    } on Object catch (error, stackTrace) {
      state = AsyncValue.error(error, stackTrace);
    }
  }

  Future<void> signOut() async {
    final auth = ref.read(authServiceProvider);
    await MongoEasy.instance.clearLocalData();
    await auth.signOut();
    await MongoEasy.instance.refreshToken();
    state = const AsyncValue.data(null);
  }
}

final authProvider =
    NotifierProvider<AuthNotifier, AsyncValue<String?>>(AuthNotifier.new);

final todosCollectionProvider = Provider<TypedCollection<Todo>>((ref) {
  return MongoEasy.collection('todos').withConverter<Todo>(
    fromJson: Todo.fromJson,
    toJson: (todo) => todo.toJson(),
  );
});

final todosProvider = StreamProvider.autoDispose<List<Todo>>((ref) {
  return ref
      .watch(todosCollectionProvider)
      .orderBy('created_at', descending: true)
      .watch();
});

final syncStatusProvider =
    StreamProvider<SyncStatus>((ref) => MongoEasy.instance.statusStream);

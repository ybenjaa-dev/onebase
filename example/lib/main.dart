import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:mongo_easy/mongo_easy.dart';

import 'config.dart';
import 'mongo_easy_schema.g.dart';
import 'providers.dart';
import 'screens/login_screen.dart';
import 'screens/todos_screen.dart';
import 'services/auth_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final auth = AuthService();
  await auth.load();

  await MongoEasy.init(MongoEasyConfig(
    apiUrl: AppConfig.apiUrl,
    tokenProvider: TokenProvider(() async => auth.token),
    schema: mongoEasySchema,
    // Offline-first with a live connection: writes work with no network, and
    // another device's changes land here the moment they happen. Flip to
    // MongoEasyMode.online for a thin client with no local database.
    mode: AppConfig.online ? MongoEasyMode.online : MongoEasyMode.offline,
    realtime: true,
  ));

  runApp(ProviderScope(
    overrides: [authServiceProvider.overrideWithValue(auth)],
    child: const TodoApp(),
  ));
}

class TodoApp extends ConsumerWidget {
  const TodoApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final signedInEmail = ref.watch(authProvider).value;

    return MaterialApp(
      title: 'mongo_easy Todos',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: const Color(0xFF00684A), // MongoDB green
        brightness: Brightness.light,
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: const Color(0xFF00ED64),
        brightness: Brightness.dark,
      ),
      home: AnimatedSwitcher(
        duration: const Duration(milliseconds: 250),
        switchInCurve: Curves.easeOut,
        switchOutCurve: Curves.easeIn,
        child:
            signedInEmail == null ? const LoginScreen() : const TodosScreen(),
      ),
    );
  }
}

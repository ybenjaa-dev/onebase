import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../config.dart';
import '../providers.dart';

class LoginScreen extends HookConsumerWidget {
  const LoginScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final emailController = useTextEditingController();
    final formKey = useRef(GlobalKey<FormState>());
    final auth = ref.watch(authProvider);
    final isLoading = auth.isLoading;

    ref.listen(authProvider, (_, next) {
      if (next.hasError) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Sign-in failed: ${next.error}'),
          behavior: SnackBarBehavior.floating,
        ));
      }
    });

    Future<void> submit() async {
      if (!formKey.value.currentState!.validate()) return;
      await ref
          .read(authProvider.notifier)
          .signIn(emailController.text.trim().toLowerCase());
    }

    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(32),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Form(
              key: formKey.value,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Icon(Icons.sync_rounded,
                      size: 64, color: Theme.of(context).colorScheme.primary),
                  const SizedBox(height: 16),
                  Text(
                    'mongobase Todos',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.headlineMedium,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Offline-first todos synced to MongoDB Atlas.\n'
                    'Dev login — any email works.',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 32),
                  if (!AppConfig.isConfigured)
                    Card(
                      color: Theme.of(context).colorScheme.errorContainer,
                      child: const Padding(
                        padding: EdgeInsets.all(12),
                        child: Text(
                          'lib/config.dart still has placeholder URLs. Run '
                          '`dart run mongobase:setup`, deploy the backend, '
                          'then fill in AppConfig.',
                        ),
                      ),
                    ),
                  const SizedBox(height: 8),
                  TextFormField(
                    controller: emailController,
                    enabled: !isLoading,
                    autofocus: true,
                    keyboardType: TextInputType.emailAddress,
                    textInputAction: TextInputAction.done,
                    onFieldSubmitted: (_) => submit(),
                    decoration: const InputDecoration(
                      labelText: 'Email',
                      hintText: 'you@example.com',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.alternate_email),
                    ),
                    validator: (value) {
                      final email = value?.trim() ?? '';
                      if (email.isEmpty) return 'Enter an email';
                      if (!email.contains('@')) return 'Not a valid email';
                      return null;
                    },
                  ),
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: isLoading ? null : submit,
                    child: isLoading
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('Sign in'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

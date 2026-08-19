import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:onebase/onebase.dart';

import '../onebase_schema.g.dart';
import '../providers.dart';

class TodosScreen extends ConsumerWidget {
  const TodosScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final todos = ref.watch(todosProvider);
    final email = ref.watch(authProvider).value;

    return Scaffold(
      appBar: AppBar(
        title: const Text('My todos'),
        actions: [
          IconButton(
            tooltip: 'Sign out ($email)',
            icon: const Icon(Icons.logout),
            onPressed: () => ref.read(authProvider.notifier).signOut(),
          ),
        ],
        bottom: const PreferredSize(
          preferredSize: Size.fromHeight(28),
          child: _SyncBanner(),
        ),
      ),
      body: todos.when(
        loading: () => const _TodoListSkeleton(),
        error: (error, _) => _ErrorState(
          error: error,
          onRetry: () => ref.invalidate(todosProvider),
        ),
        data: (items) => items.isEmpty
            ? const _EmptyState()
            : ListView.builder(
                padding: const EdgeInsets.only(bottom: 96),
                itemCount: items.length,
                itemBuilder: (context, index) {
                  final todo = items[index];
                  return _TodoTile(key: ValueKey(todo.id), todo: todo);
                },
              ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _showAddSheet(context, ref),
        icon: const Icon(Icons.add),
        label: const Text('Add todo'),
      ),
    );
  }

  Future<void> _showAddSheet(BuildContext context, WidgetRef ref) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(sheetContext).bottom,
        ),
        child: const _AddTodoForm(),
      ),
    );
  }
}

class _AddTodoForm extends HookConsumerWidget {
  const _AddTodoForm();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = useTextEditingController();
    final isSaving = useState(false);

    Future<void> save() async {
      final title = controller.text.trim();
      if (title.isEmpty) return;
      isSaving.value = true;
      try {
        // Offline-first: resolves immediately, syncs in the background.
        // The model and its id are generated — nothing hand-written.
        await OnebaseDb.todos.insert(
          Todo(title: title, done: false, createdAt: DateTime.now()),
        );
        if (!context.mounted) return;
        Navigator.of(context).pop();
      } on OnebaseException catch (error) {
        if (!context.mounted) return;
        isSaving.value = false;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(error.message),
          behavior: SnackBarBehavior.floating,
        ));
      }
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: controller,
              autofocus: true,
              enabled: !isSaving.value,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => save(),
              decoration: const InputDecoration(
                labelText: 'What needs doing?',
                border: OutlineInputBorder(),
              ),
            ),
          ),
          const SizedBox(width: 12),
          FilledButton(
            onPressed: isSaving.value ? null : save,
            child: const Text('Add'),
          ),
        ],
      ),
    );
  }
}

class _TodoTile extends ConsumerWidget {
  const _TodoTile({super.key, required this.todo});

  final Todo todo;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final collection = ref.watch(todosCollectionProvider);

    return Dismissible(
      key: ValueKey('dismiss-${todo.id}'),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 24),
        color: Theme.of(context).colorScheme.errorContainer,
        child: Icon(Icons.delete_outline,
            color: Theme.of(context).colorScheme.onErrorContainer),
      ),
      onDismissed: (_) async {
        await collection.delete(todo.id);
        if (!context.mounted) return;
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(
            content: Text('Deleted "${todo.title}"'),
            behavior: SnackBarBehavior.floating,
          ));
      },
      child: CheckboxListTile(
        value: todo.done,
        onChanged: (checked) =>
            collection.update(todo.id, {'done': checked ?? false}),
        title: Text(
          todo.title,
          style: todo.done
              ? TextStyle(
                  decoration: TextDecoration.lineThrough,
                  color: Theme.of(context).colorScheme.outline,
                )
              : null,
        ),
        secondary: Icon(
          todo.done ? Icons.task_alt : Icons.radio_button_unchecked,
          color: todo.done
              ? Theme.of(context).colorScheme.primary
              : Theme.of(context).colorScheme.outline,
        ),
        controlAffinity: ListTileControlAffinity.trailing,
      ),
    );
  }
}

/// Live connectivity strip: green when synced, amber while syncing, grey
/// offline. Driven by Onebase.instance.statusStream.
class _SyncBanner extends ConsumerWidget {
  const _SyncBanner();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(syncStatusProvider).value;
    final scheme = Theme.of(context).colorScheme;

    final isLive = ref.watch(realtimeProvider).value ?? false;

    final (label, color, icon) = switch (status) {
      null => ('Connecting…', scheme.outline, Icons.cloud_queue),
      SyncStatus(connected: false, pendingWrites: final pending)
          when pending > 0 =>
        (
          'Offline — $pending change(s) waiting to upload',
          scheme.outline,
          Icons.cloud_off,
        ),
      SyncStatus(connected: false) => (
          'Offline — changes are saved locally',
          scheme.outline,
          Icons.cloud_off,
        ),
      SyncStatus(uploading: true) || SyncStatus(downloading: true) => (
          'Syncing…',
          scheme.tertiary,
          Icons.cloud_sync
        ),
      // Realtime connected means another device's edit shows up here at
      // once, rather than on the next poll.
      _ when isLive => ('Live', scheme.primary, Icons.bolt),
      _ => ('Synced', scheme.primary, Icons.cloud_done),
    };

    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      height: 28,
      color: color.withValues(alpha: 0.12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 6),
          Text(label,
              style: Theme.of(context)
                  .textTheme
                  .labelSmall
                  ?.copyWith(color: color)),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.checklist_rounded,
              size: 72, color: Theme.of(context).colorScheme.outlineVariant),
          const SizedBox(height: 16),
          Text('No todos yet', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            'Add one below — it syncs to MongoDB automatically,\n'
            'even if you are offline right now.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.error, required this.onRetry});

  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.error_outline,
                size: 48, color: Theme.of(context).colorScheme.error),
            const SizedBox(height: 12),
            Text('Something went wrong',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              error is OnebaseException
                  ? (error as OnebaseException).message
                  : '$error',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }
}

class _TodoListSkeleton extends StatelessWidget {
  const _TodoListSkeleton();

  @override
  Widget build(BuildContext context) {
    final base = Theme.of(context).colorScheme.surfaceContainerHighest;
    return ListView.builder(
      itemCount: 6,
      itemBuilder: (context, index) => ListTile(
        leading: CircleAvatar(radius: 12, backgroundColor: base),
        title: Align(
          alignment: Alignment.centerLeft,
          child: Container(
            height: 14,
            width: 120.0 + (index % 3) * 60,
            decoration: BoxDecoration(
              color: base,
              borderRadius: BorderRadius.circular(4),
            ),
          ),
        ),
      ),
    );
  }
}

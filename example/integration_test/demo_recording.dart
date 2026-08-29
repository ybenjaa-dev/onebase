// Drives the example app through the launch-demo flow so the simulator can be
// screen-recorded. Timings are deliberate and match tool/record_demo.sh, which
// stops and restarts the backend while this runs.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:onebase_example/main.dart' as app;

Future<void> hold(WidgetTester tester, int seconds) async {
  final end = DateTime.now().add(Duration(seconds: seconds));
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> addTodo(WidgetTester tester, String title) async {
  await tester.tap(find.widgetWithText(FloatingActionButton, 'Add todo'));
  await hold(tester, 1);
  await tester.enterText(find.byType(TextField).last, title);
  await hold(tester, 1);
  await tester.testTextInput.receiveAction(TextInputAction.done);
  await hold(tester, 3);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('launch demo', (tester) async {
    app.main();
    await hold(tester, 4);

    await tester.enterText(find.byType(TextFormField), 'demo@onebase.dev');
    await hold(tester, 2);
    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await hold(tester, 6);

    await addTodo(tester, 'Ship onebase to r/FlutterDev');
    await hold(tester, 6); // backend goes down here

    await addTodo(tester, 'Written with no network');
    await addTodo(tester, 'Still instant, still local');
    await hold(tester, 8); // backend comes back here

    // Stay alive well past the reconnect so the outbox drains on camera.
    await hold(tester, 45);
  }, timeout: const Timeout(Duration(minutes: 4)));
}

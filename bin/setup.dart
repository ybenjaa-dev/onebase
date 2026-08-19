import 'dart:io';

import 'package:mongobase/src/cli/wizard.dart';

Future<void> main(List<String> arguments) async {
  exitCode = await runSetup(arguments);
}

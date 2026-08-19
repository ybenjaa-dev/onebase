import 'dart:io';

import 'package:onebase/src/cli/wizard.dart';

Future<void> main(List<String> arguments) async {
  exitCode = await runSetup(arguments);
}

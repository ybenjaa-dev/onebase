import 'dart:io';

import 'package:mongo_easy/src/cli/wizard.dart';

Future<void> main(List<String> arguments) async {
  exitCode = await runSetup(arguments);
}

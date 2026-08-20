import 'dart:io';

import 'package:path/path.dart' as p;

/// Runs the SDK formatter over [source].
///
/// The generator emits structure, not layout, so everything it writes goes
/// through `dart format` — a regenerated file then matches byte for byte what
/// the project's own format check accepts. The scratch file lives under [root]
/// so the formatter resolves that package's language version rather than the
/// SDK default. Best effort: without a usable `dart` the source is returned
/// unchanged.
String formatDartSource(String source, {required String root}) {
  final scratch = Directory(p.join(root, '.dart_tool', 'onebase'));
  final file = File(p.join(scratch.path, 'format_scratch.dart'));
  try {
    scratch.createSync(recursive: true);
    file.writeAsStringSync(source);
    final result = Process.runSync(_dartExecutable, [
      'format',
      '--summary=none',
      file.path,
    ]);
    if (result.exitCode != 0) return source;
    return file.readAsStringSync();
  } on ProcessException {
    return source;
  } on FileSystemException {
    return source;
  } finally {
    if (file.existsSync()) file.deleteSync();
  }
}

/// The `dart` beside the running executable, so the formatter is found even
/// when it is not on PATH.
String get _dartExecutable {
  final sibling = p.join(p.dirname(Platform.resolvedExecutable), 'dart');
  return File(sibling).existsSync() ? sibling : 'dart';
}

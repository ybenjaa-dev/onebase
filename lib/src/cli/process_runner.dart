import 'dart:convert';
import 'dart:io';

/// Result of an external command.
class ProcessResult2 {
  const ProcessResult2(this.exitCode, this.stdout, this.stderr);

  final int exitCode;
  final String stdout;
  final String stderr;

  bool get ok => exitCode == 0;

  /// Combined output, for error reporting.
  String get output =>
      [stdout.trim(), stderr.trim()].where((s) => s.isNotEmpty).join('\n');
}

/// Runs external CLIs (`npx powersync`, `npx vercel`, `mongosh`). Abstracted
/// so the orchestration logic is testable with a fake.
abstract interface class ProcessRunner {
  Future<ProcessResult2> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    String? stdinText,
  });

  /// Whether [executable] exists on PATH.
  Future<bool> exists(String executable);
}

class SystemProcessRunner implements ProcessRunner {
  const SystemProcessRunner();

  @override
  Future<ProcessResult2> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    String? stdinText,
  }) async {
    final process = await Process.start(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      environment: environment,
      runInShell: true,
    );
    if (stdinText != null) {
      process.stdin.write(stdinText);
    }
    await process.stdin.close();
    final out = process.stdout.transform(utf8.decoder).join();
    final err = process.stderr.transform(utf8.decoder).join();
    final code = await process.exitCode;
    return ProcessResult2(code, await out, await err);
  }

  @override
  Future<bool> exists(String executable) async {
    final result =
        await run(Platform.isWindows ? 'where' : 'which', [executable]);
    return result.ok;
  }
}

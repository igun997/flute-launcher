import '../tools/tool_support.dart';

class ExecResult {
  const ExecResult({
    required this.stdout,
    required this.stderr,
    required this.exitCode,
    this.timedOut = false,
  });

  final String stdout;
  final String stderr;
  final int exitCode;
  final bool timedOut;
}

/// Failure in a sandbox provider. Surfaced to the model as a tool error.
class SandboxException extends ToolError {
  const SandboxException(super.message);
}

abstract class SandboxSession {
  String get label;

  Future<ExecResult> runPython(String code, {required Duration timeout});

  Future<ExecResult> runShell(String command, {required Duration timeout});

  Future<void> writeFile(String path, List<int> bytes);

  Future<List<int>> readFile(String path);

  /// Files the last run created that should be shown without being asked for. Only the local
  /// runtime knows any (what the program wrote to `/out`); remote sandboxes return none.
  Future<List<String>> newFiles();

  /// Releases the sandbox. Safe to call more than once.
  Future<void> close();
}

abstract class SandboxProvider {
  String get id;

  String get label;

  /// Remote providers run on a cloud machine. The local runtime has no shell.
  bool get isRemote;

  /// Opens a session. [existingId] reuses a user-selected sandbox instead of
  /// creating an ephemeral one.
  Future<SandboxSession> open({String? existingId});
}

class SandboxProviderStatus {
  const SandboxProviderStatus({
    required this.id,
    required this.label,
    required this.needsKey,
    required this.hasKey,
  });

  final String id;
  final String label;
  final bool needsKey;
  final bool hasKey;

  bool get usable => !needsKey || hasKey;
}

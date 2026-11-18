import 'dart:convert';

import '../tools/agent_tool.dart';
import '../tools/tool_support.dart';
import 'sandbox_manager.dart';
import 'sandbox_provider.dart';

const _maxOutputChars = 8000;
const _maxTextFileBytes = 200 * 1024;
const _defaultTimeoutS = 60;
const _maxTimeoutS = 300;
const _maxDescribeChars = 600;

/// The sandbox tools: Python, shell, and file access in an isolated machine.
class SandboxTools implements ToolSource {
  SandboxTools(SandboxManager manager)
    : _tools = [
        _PythonTool(manager),
        _ShellTool(manager),
        _WriteFileTool(manager),
        _ReadFileTool(manager),
      ];

  final List<AgentTool> _tools;

  @override
  List<AgentTool> get tools => _tools;

  @override
  Stream<void> get changes => const Stream<void>.empty();
}

abstract class _SandboxTool extends BuiltinTool {
  _SandboxTool(this.manager) : super(subject: 'Sandbox');

  final SandboxManager manager;

  @override
  String get source => 'sandbox';

  @override
  ToolRisk get risk => ToolRisk.write;

  /// Runs [action] in the shared session. The run ends afterwards, even on failure, so the
  /// manager can apply its keep-warm policy.
  Future<T> inSession<T>(Future<T> Function(SandboxSession session) action) async {
    try {
      final session = await manager.session();
      return await action(session);
    } finally {
      manager.endRun();
    }
  }
}

class _PythonTool extends _SandboxTool {
  _PythonTool(super.manager);

  @override
  String get name => 'sandbox_python';

  @override
  String get description =>
      'Run Python 3 code in an isolated sandbox. Returns stdout, stderr and the exit code. '
      'Files written with sandbox_write_file are visible to later runs on remote sandboxes.';

  @override
  Map<String, dynamic> get parameters => objectSchema({
    'code': stringProp('Python source to run.'),
    'timeout_s': intProp('Time limit in seconds. Default $_defaultTimeoutS, maximum $_maxTimeoutS.'),
  }, required: ['code']);

  @override
  String describeCall(Map<String, dynamic> args) =>
      'Run Python in the sandbox:\n${_preview(args['code'])}';

  @override
  Future<ToolResult> perform(Map<String, dynamic> args) async {
    final code = args['code'];
    if (code is! String || code.trim().isEmpty) throw const ToolError('code is required.');
    final timeout = _timeout(args);
    final watch = Stopwatch()..start();
    final result = await inSession((s) => s.runPython(code, timeout: timeout));
    return ToolResult(
      _formatExec(result, watch.elapsed),
      isError: result.exitCode != 0,
    );
  }
}

class _ShellTool extends _SandboxTool {
  _ShellTool(super.manager);

  @override
  String get name => 'sandbox_shell';

  @override
  String get description =>
      'Run a shell command in a remote sandbox. Returns stdout, stderr and the exit code. '
      'Not available with the local Python runtime.';

  @override
  Map<String, dynamic> get parameters => objectSchema({
    'command': stringProp('Shell command to run.'),
    'timeout_s': intProp('Time limit in seconds. Default $_defaultTimeoutS, maximum $_maxTimeoutS.'),
  }, required: ['command']);

  @override
  String describeCall(Map<String, dynamic> args) =>
      'Run a shell command in the sandbox:\n${_preview(args['command'])}';

  @override
  Future<ToolResult> perform(Map<String, dynamic> args) async {
    final command = args['command'];
    if (command is! String || command.trim().isEmpty) {
      throw const ToolError('command is required.');
    }
    final timeout = _timeout(args);
    final watch = Stopwatch()..start();
    final result = await inSession((s) => s.runShell(command, timeout: timeout));
    return ToolResult(
      _formatExec(result, watch.elapsed),
      isError: result.exitCode != 0,
    );
  }
}

class _WriteFileTool extends _SandboxTool {
  _WriteFileTool(super.manager);

  @override
  String get name => 'sandbox_write_file';

  @override
  String get description => 'Write a UTF-8 text file in the sandbox, replacing any existing file.';

  @override
  Map<String, dynamic> get parameters => objectSchema({
    'path': stringProp('File path in the sandbox.'),
    'content': stringProp('Full text content of the file.'),
  }, required: ['path', 'content']);

  @override
  String describeCall(Map<String, dynamic> args) =>
      'Write sandbox file ${_preview(args['path'])}';

  @override
  Future<ToolResult> perform(Map<String, dynamic> args) async {
    final path = requireArg(args, 'path');
    final content = args['content'];
    if (content is! String) throw const ToolError('content is required.');
    final bytes = utf8.encode(content);
    await inSession((s) => s.writeFile(path, bytes));
    return ToolResult('Wrote ${bytes.length} bytes to $path.');
  }
}

class _ReadFileTool extends _SandboxTool {
  _ReadFileTool(super.manager);

  @override
  String get name => 'sandbox_read_file';

  @override
  String get description =>
      'Read a file from the sandbox. Text files up to 200 KB are returned as text; '
      'binary files are reported without content.';

  @override
  Map<String, dynamic> get parameters => objectSchema({
    'path': stringProp('File path in the sandbox.'),
  }, required: ['path']);

  @override
  String describeCall(Map<String, dynamic> args) =>
      'Read sandbox file ${_preview(args['path'])}';

  @override
  Future<ToolResult> perform(Map<String, dynamic> args) async {
    final path = requireArg(args, 'path');
    final bytes = await inSession((s) => s.readFile(path));
    final String text;
    try {
      text = utf8.decode(bytes);
    } on FormatException {
      return ToolResult('$path is a binary file (${bytes.length} bytes). Its content is not shown.');
    }
    if (bytes.length > _maxTextFileBytes) {
      throw ToolError(
        '$path is ${bytes.length} bytes. The limit for reading text is $_maxTextFileBytes bytes.',
      );
    }
    return ToolResult(text.isEmpty ? '$path is empty.' : text);
  }
}

Duration _timeout(Map<String, dynamic> args) {
  final seconds = argInt(args, 'timeout_s') ?? _defaultTimeoutS;
  final bounded = seconds < 1 ? 1 : (seconds > _maxTimeoutS ? _maxTimeoutS : seconds);
  return Duration(seconds: bounded);
}

String _formatExec(ExecResult result, Duration elapsed) {
  final status = result.timedOut ? ' (timed out)' : '';
  final buffer = StringBuffer(
    'exit code ${result.exitCode}$status after ${elapsed.inMilliseconds} ms',
  );
  if (result.stdout.isEmpty && result.stderr.isEmpty) {
    buffer.write('\n(no output)');
  }
  if (result.stdout.isNotEmpty) {
    buffer.write('\nstdout:\n${_tail(result.stdout)}');
  }
  if (result.stderr.isNotEmpty) {
    buffer.write('\nstderr:\n${_tail(result.stderr)}');
  }
  return buffer.toString();
}

/// The last [_maxOutputChars] characters of [text], with a note when earlier output was cut.
String _tail(String text) {
  if (text.length <= _maxOutputChars) return text;
  final cut = text.length - _maxOutputChars;
  return '[$cut characters cut]\n${text.substring(cut)}';
}

String _preview(Object? value) {
  final text = value is String ? value : '';
  return text.length <= _maxDescribeChars
      ? text
      : '${text.substring(0, _maxDescribeChars)}...';
}

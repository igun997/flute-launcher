import 'dart:convert';
import 'dart:io';

import '../tools/agent_tool.dart';
import '../tools/tool_support.dart';
import 'sandbox_manager.dart';
import 'sandbox_outputs.dart';
import 'sandbox_provider.dart';

const _maxOutputChars = 8000;
const _maxTextFileBytes = 200 * 1024;
const _defaultTimeoutS = 60;
const _maxTimeoutS = 300;
const _maxDescribeChars = 600;

/// The sandbox tools: Python, shell, and file access in an isolated machine.
class SandboxTools implements ToolSource {
  SandboxTools(SandboxManager manager, {SandboxOutputs? outputs})
    : _tools = [
        _PythonTool(manager, outputs ?? SandboxOutputs()),
        _ShellTool(manager, outputs ?? SandboxOutputs()),
        _WriteFileTool(manager),
        _ReadFileTool(manager),
        _TranscribeTool(manager),
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

  /// Files to show the user after a run, read while the session is still open (the sandbox is shut
  /// down when the call ends). [wanted] are paths the model asked for; the local runtime adds
  /// whatever the program wrote to `/out`.
  Future<({List<ToolFile> files, List<String> notes})> present(
    SandboxSession session,
    SandboxOutputs outputs,
    List<String> wanted,
  ) async {
    final paths = <String>{...wanted, ...await session.newFiles()}.toList();
    final files = <ToolFile>[];
    final notes = <String>[];
    for (final path in paths) {
      if (files.length >= SandboxOutputs.maxFilesPerRun) {
        notes.add('Only the first ${SandboxOutputs.maxFilesPerRun} files are shown.');
        break;
      }
      try {
        final bytes = await session.readFile(path);
        files.add(await outputs.save(path, bytes));
      } on ToolError catch (e) {
        notes.add('$path could not be shown: ${e.message}');
      } on FileSystemException catch (e) {
        notes.add('$path could not be shown: ${e.message}');
      }
    }
    return (files: files, notes: notes);
  }

  /// "Shown to the user: ..." for the model, or '' when nothing was shown.
  String shownSummary(List<ToolFile> files, List<String> notes) {
    final lines = <String>[
      if (files.isNotEmpty)
        'Shown to the user in the chat (they can open, share or save): '
            '${files.map((f) => '${f.name} (${f.mime}, ${f.bytes} bytes)').join(', ')}.',
      ...notes,
    ];
    return lines.isEmpty ? '' : '\n${lines.join('\n')}';
  }

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
  _PythonTool(super.manager, this.outputs);

  final SandboxOutputs outputs;

  @override
  String get name => 'sandbox_python';

  @override
  String get description =>
      'Run Python 3 code in an isolated sandbox. Returns stdout, stderr and the exit code. '
      'The sandbox can reach the public internet: remote sandboxes have full network and pip; the local '
      'sandbox (standard library only, no pip) can fetch http(s) URLs with urllib.request, for example '
      'urllib.request.urlopen(url).read(), but cannot reach localhost or home-network addresses. '
      'To show a picture, chart or file to the user, write it to disk and the chat displays it with '
      'open, share and save actions: in the local sandbox write under /out (everything written there '
      'is shown automatically; standard library only, so build PNGs with zlib/struct or write SVG, CSV, '
      'HTML, JSON); on a remote sandbox save the file anywhere (for example matplotlib savefig) and list '
      'its path in show_files. Files written with sandbox_write_file are visible to later runs on remote sandboxes.';

  @override
  Map<String, dynamic> get parameters => objectSchema({
    'code': stringProp('Python source to run.'),
    'timeout_s': intProp('Time limit in seconds. Default $_defaultTimeoutS, maximum $_maxTimeoutS.'),
    'show_files': _showFilesProp,
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
    final wanted = _showFiles(args);
    final run = await inSession((s) async {
      final result = await s.runPython(code, timeout: timeout);
      return (result: result, shown: await present(s, outputs, wanted));
    });
    return ToolResult(
      _formatExec(run.result, watch.elapsed) + shownSummary(run.shown.files, run.shown.notes),
      isError: run.result.exitCode != 0,
      files: run.shown.files,
    );
  }
}

class _ShellTool extends _SandboxTool {
  _ShellTool(super.manager, this.outputs);

  final SandboxOutputs outputs;

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
    'show_files': _showFilesProp,
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
    final wanted = _showFiles(args);
    final run = await inSession((s) async {
      final result = await s.runShell(command, timeout: timeout);
      return (result: result, shown: await present(s, outputs, wanted));
    });
    return ToolResult(
      _formatExec(run.result, watch.elapsed) + shownSummary(run.shown.files, run.shown.notes),
      isError: run.result.exitCode != 0,
      files: run.shown.files,
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

/// The Python run inside the sandbox for [_TranscribeTool]. Values are JSON-encoded, which is also
/// valid Python string syntax, so a path or language can never break out of the script.
String transcribeScript({required String audioPath, String? language, String model = 'base'}) {
  final lang = (language == null || language.isEmpty) ? 'None' : jsonEncode(language);
  return '''
from faster_whisper import WhisperModel
m = WhisperModel(${jsonEncode(model)}, device="cpu", compute_type="int8")
segments, info = m.transcribe(${jsonEncode(audioPath)}, language=$lang)
print("".join(s.text for s in segments).strip())
''';
}

/// Speech to text inside a remote sandbox (faster-whisper on CPU). The cheaper route is
/// `audio_transcribe`, which asks the model provider; this one needs no provider support.
class _TranscribeTool extends _SandboxTool {
  _TranscribeTool(super.manager);

  static const _maxAudioBytes = 25 * 1024 * 1024;

  @override
  String get name => 'sandbox_transcribe_audio';

  @override
  String get description =>
      'Transcribe an audio file from the phone to text inside a remote sandbox with Whisper. '
      'Slow on the first run (it installs faster-whisper and downloads a model) and uses sandbox time. '
      'Prefer audio_transcribe when it is available. Remote sandboxes only.';

  @override
  Map<String, dynamic> get parameters => objectSchema({
    'path': stringProp('Path of the audio file on the phone.'),
    'language': stringProp('Language code such as en or id. Detected when omitted.'),
    'model': stringProp('Whisper size: tiny, base (default) or small.'),
  }, required: ['path']);

  @override
  String describeCall(Map<String, dynamic> args) =>
      'Transcribe ${_preview(args['path'])} in a sandbox';

  @override
  Future<ToolResult> perform(Map<String, dynamic> args) async {
    final path = requireArg(args, 'path');
    final model = argString(args, 'model') ?? 'base';
    if (!const {'tiny', 'base', 'small'}.contains(model)) {
      throw const ToolError('model must be tiny, base or small.');
    }
    final file = File(path);
    if (!await file.exists()) throw ToolError('No file at $path.');
    if (await file.length() > _maxAudioBytes) {
      throw const ToolError('The audio file is larger than 25 MB.');
    }
    final bytes = await file.readAsBytes();
    final dot = path.lastIndexOf('.');
    final extension = dot < 0 ? 'bin' : path.substring(dot + 1).replaceAll(RegExp(r'[^A-Za-z0-9]'), '');
    final remote = '/tmp/flute-audio.$extension';
    final watch = Stopwatch()..start();
    return inSession((session) async {
      await session.writeFile(remote, bytes);
      final install = await session.runShell(
        'python3 -m pip install -q faster-whisper 2>&1 | tail -3',
        timeout: const Duration(seconds: _maxTimeoutS),
      );
      if (install.exitCode != 0) {
        return ToolResult('Could not install the transcription package.\n${_tail(install.stdout + install.stderr)}', isError: true);
      }
      final result = await session.runPython(
        transcribeScript(audioPath: remote, language: argString(args, 'language'), model: model),
        timeout: const Duration(seconds: _maxTimeoutS),
      );
      if (result.exitCode != 0) {
        return ToolResult(_formatExec(result, watch.elapsed), isError: true);
      }
      final text = result.stdout.trim();
      return ToolResult(text.isEmpty ? '(no speech found)' : text);
    });
  }
}

const _showFilesProp = {
  'type': 'array',
  'items': {'type': 'string'},
  'description': 'Paths of files made by this run to show to the user (pictures, charts, CSV, PDF). '
      'Up to 8, 20 MB each.',
};

List<String> _showFiles(Map<String, dynamic> args) {
  final raw = args['show_files'];
  if (raw is! List) return const [];
  return [
    for (final item in raw)
      if (item is String && item.trim().isNotEmpty) item.trim(),
  ];
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

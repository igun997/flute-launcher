import '../llm/llm_types.dart';

/// Whether a tool only looks at things or changes them. Writes always ask the user first.
enum ToolRisk { read, write }

class ToolResult {
  const ToolResult(this.text, {this.isError = false});
  const ToolResult.error(this.text) : isError = true;

  /// What the model reads back. Keep it compact: it costs tokens.
  final String text;
  final bool isError;
}

/// One thing the agent can do: a built-in (calendar, contacts, notes) or an MCP tool.
abstract class AgentTool {
  /// Unique across all tools and valid as a function name: `[a-zA-Z0-9_-]{1,64}`.
  String get name;
  String get description;

  /// JSON Schema (`type: object`) for the arguments.
  Map<String, dynamic> get parameters;

  ToolRisk get risk;

  /// Where it comes from, for grouping in settings and the confirm sheet: `calendar`, `contacts`,
  /// `notes`, or `mcp:<server name>`.
  String get source;

  /// A one-line, human description of this exact call, shown in the confirm sheet
  /// ("Create event 'Dentist' on Fri 14:00").
  String describeCall(Map<String, dynamic> args);

  /// Runs the call. Must not throw for expected failures (permission denied, not found): return
  /// [ToolResult.error] so the model can react. Called only after the user allowed a write.
  Future<ToolResult> run(Map<String, dynamic> args);

  ToolSpec toSpec() => ToolSpec(name: name, description: description, parameters: parameters);
}

enum ConfirmDecision { allowOnce, allowForSession, deny }

class ConfirmRequest {
  const ConfirmRequest({required this.tool, required this.summary, required this.arguments});
  final AgentTool tool;

  /// [AgentTool.describeCall] for this call.
  final String summary;
  final Map<String, dynamic> arguments;
}

/// Asks the person. The UI implements it with a bottom sheet; tests implement it with a script.
abstract class Confirmer {
  Future<ConfirmDecision> ask(ConfirmRequest request);
}

/// The set of tools offered for one turn. Built-ins register once; MCP tools come and go as
/// servers connect and disconnect.
abstract class ToolSource {
  /// Current tools. May change over time; [changes] fires when it does.
  List<AgentTool> get tools;
  Stream<void> get changes;
}

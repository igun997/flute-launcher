import 'agent_tool.dart';
import 'tool_support.dart';

const _weekdays = [
  'Monday',
  'Tuesday',
  'Wednesday',
  'Thursday',
  'Friday',
  'Saturday',
  'Sunday',
];

/// `current_time`: the device's local date and time. Always on, so the model can resolve "today",
/// "tomorrow" or "next Friday" before it writes a calendar event.
class CurrentTimeTool extends AgentTool {
  CurrentTimeTool({Clock? now}) : _now = now ?? DateTime.now;

  final Clock _now;

  @override
  String get name => 'current_time';

  @override
  String get description =>
      'Current local date, time, weekday and UTC offset on this device. Call it before resolving '
      'words such as "today", "tomorrow" or "next Friday".';

  @override
  Map<String, dynamic> get parameters => objectSchema({});

  @override
  ToolRisk get risk => ToolRisk.read;

  @override
  String get source => 'time';

  @override
  String describeCall(Map<String, dynamic> args) => 'Read the current time';

  @override
  Future<ToolResult> run(Map<String, dynamic> args) async {
    final now = _now();
    final weekday = _weekdays[now.weekday - 1];
    return ToolResult(
      '${ymd(now)}T${hm(now)}:${two(now.second)}, $weekday (${offsetText(now.timeZoneOffset)}).',
    );
  }
}

/// The time tools, in the order they are offered.
List<AgentTool> timeTools({Clock? now}) => [CurrentTimeTool(now: now)];

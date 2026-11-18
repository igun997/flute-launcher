import '../tools/agent_tool.dart';
import 'skill.dart';
import 'skill_manager.dart';

const _maxBodyChars = 64 * 1024;

/// Lets the agent read installed skills on demand. The catalogue in the system prompt lists them.
class SkillTools implements ToolSource {
  SkillTools(SkillManager manager)
      : _manager = manager,
        _all = [_LoadSkillTool(manager), _ReadSkillFileTool(manager)];

  final SkillManager _manager;
  final List<AgentTool> _all;

  @override
  List<AgentTool> get tools => _manager.installed.isEmpty ? const [] : _all;

  @override
  Stream<void> get changes => _manager.changes;
}

class _LoadSkillTool extends AgentTool {
  _LoadSkillTool(this._manager);

  final SkillManager _manager;

  @override
  String get name => 'skill_load';

  @override
  String get description =>
      'Load the full instructions of an installed skill by its name. Use it when a skill in the list applies to the request.';

  @override
  Map<String, dynamic> get parameters => {
        'type': 'object',
        'properties': {
          'name': {'type': 'string', 'description': 'The installed skill name'},
        },
        'required': ['name'],
      };

  @override
  ToolRisk get risk => ToolRisk.read;

  @override
  String get source => 'skills';

  @override
  String describeCall(Map<String, dynamic> args) => 'Load skill ${args['name']}';

  @override
  Future<ToolResult> run(Map<String, dynamic> args) async {
    final name = args['name'];
    if (name is! String || name.isEmpty) return const ToolResult.error('Give the skill name.');
    final body = _manager.bodyOf(name);
    if (body == null) {
      final names = _manager.installed.map((s) => s.name).join(', ');
      return ToolResult.error(
        'No installed skill named $name.${names.isEmpty ? ' No skills are installed.' : ' Installed: $names.'}',
      );
    }
    final clipped = body.length > _maxBodyChars ? '${body.substring(0, _maxBodyChars)}\n...(truncated)' : body;
    return ToolResult('# $name\n\n$clipped');
  }
}

class _ReadSkillFileTool extends AgentTool {
  _ReadSkillFileTool(this._manager);

  final SkillManager _manager;

  @override
  String get name => 'skill_read_file';

  @override
  String get description =>
      'Read a file that ships with an installed skill, by its path inside the skill folder (for example references/api.md).';

  @override
  Map<String, dynamic> get parameters => {
        'type': 'object',
        'properties': {
          'name': {'type': 'string', 'description': 'The installed skill name'},
          'path': {'type': 'string', 'description': 'Path inside the skill folder'},
        },
        'required': ['name', 'path'],
      };

  @override
  ToolRisk get risk => ToolRisk.read;

  @override
  String get source => 'skills';

  @override
  String describeCall(Map<String, dynamic> args) => 'Read ${args['path']} from skill ${args['name']}';

  @override
  Future<ToolResult> run(Map<String, dynamic> args) async {
    final name = args['name'];
    final path = args['path'];
    if (name is! String || path is! String) return const ToolResult.error('Give the skill name and the file path.');
    try {
      final text = await _manager.readFile(name, path);
      if (text == null) return ToolResult.error('Skill $name has no file $path.');
      return ToolResult(text);
    } on SkillException catch (e) {
      return ToolResult.error(e.message);
    }
  }
}

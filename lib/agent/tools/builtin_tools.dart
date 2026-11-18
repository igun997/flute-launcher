import 'dart:async';

import 'package:shared_preferences/shared_preferences.dart';

import 'agent_tool.dart';
import 'calendar_backend.dart';
import 'calendar_tools.dart';
import 'contact_tools.dart';
import 'contacts_backend.dart';
import 'notes_store.dart';
import 'notes_tools.dart';
import 'time_tools.dart';

/// The built-in tools (time, calendar, contacts, notes) and their on/off switches.
///
/// Each group's tools are built once, so their remembered labels survive between turns. Turning a
/// group on or off changes which tools are offered; permission is requested separately with
/// [requestPermission], so the settings screen decides when to ask.
class BuiltinTools implements ToolSource {
  BuiltinTools({
    required SharedPreferences prefs,
    NotesStore? notes,
    CalendarBackend? calendar,
    ContactsBackend? contacts,
  }) : _prefs = prefs,
       _notes = notes ?? NotesStore(),
       _calendar = calendar ?? DeviceCalendarBackend(),
       _contacts = contacts ?? DeviceContactsBackend();

  static const groups = ['calendar', 'contacts', 'notes'];

  static const _prefix = 'agent.tools.';

  final SharedPreferences _prefs;
  final NotesStore _notes;
  final CalendarBackend _calendar;
  final ContactsBackend _contacts;
  final _changes = StreamController<void>.broadcast();

  late final List<AgentTool> _timeTools = timeTools();
  late final List<AgentTool> _calendarTools = calendarTools(backend: _calendar);
  late final List<AgentTool> _contactTools = contactTools(_contacts);
  late final List<AgentTool> _notesTools = notesTools(_notes);

  /// Notes default to on; calendar and contacts to off until the person turns them on.
  bool isEnabled(String group) {
    _checkGroup(group);
    return _prefs.getBool('$_prefix$group') ?? group == 'notes';
  }

  Future<void> setEnabled(String group, bool on) async {
    final before = isEnabled(group);
    await _prefs.setBool('$_prefix$group', on);
    if (before != on) _changes.add(null);
  }

  /// Notes need no system permission. Calendar and contacts report whether access is granted.
  Future<bool> hasPermission(String group) {
    _checkGroup(group);
    if (group == 'calendar') return _calendar.hasAccess();
    if (group == 'contacts') return _contacts.hasAccess();
    return Future.value(true);
  }

  /// Shows the system dialog for the group's permission when it is missing. True when granted.
  Future<bool> requestPermission(String group) {
    _checkGroup(group);
    if (group == 'calendar') return _calendar.requestAccess();
    if (group == 'contacts') return _contacts.requestAccess();
    return Future.value(true);
  }

  /// Time is always offered; each group only while it is on.
  @override
  List<AgentTool> get tools => [
    ..._timeTools,
    if (isEnabled('calendar')) ..._calendarTools,
    if (isEnabled('contacts')) ..._contactTools,
    if (isEnabled('notes')) ..._notesTools,
  ];

  @override
  Stream<void> get changes => _changes.stream;

  void dispose() => _changes.close();

  String _checkGroup(String group) {
    if (!groups.contains(group)) {
      throw ArgumentError.value(group, 'group', 'Unknown built-in tool group');
    }
    return group;
  }
}

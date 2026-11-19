import 'package:flutter_test/flutter_test.dart';
import 'package:focus_launcher/agent/tools/agent_tool.dart';
import 'package:focus_launcher/agent/ui/confirm_controller.dart';
import 'package:focus_launcher/agent/ui/confirm_sheet.dart';
import 'package:material_ui/material_ui.dart';

class _FakeTool extends AgentTool {
  _FakeTool(this.name, {Map<String, dynamic>? schema})
      : _schema = schema ?? const {'type': 'object', 'properties': {}};

  final Map<String, dynamic> _schema;

  @override
  final String name;

  @override
  String get source => 'notes';

  @override
  String get description => 'fake';

  @override
  Map<String, dynamic> get parameters => _schema;

  @override
  ToolRisk get risk => ToolRisk.write;

  @override
  String describeCall(Map<String, dynamic> args) => 'Run $name';

  @override
  Future<ToolResult> run(Map<String, dynamic> args) async => const ToolResult('ok');
}

ConfirmRequest _request(
  String tool,
  String summary, {
  Map<String, dynamic> arguments = const {},
  Map<String, dynamic>? schema,
}) =>
    ConfirmRequest(tool: _FakeTool(tool, schema: schema), summary: summary, arguments: arguments);

Future<void> _openSheet(WidgetTester tester, ConfirmController confirm) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => FilledButton(
            onPressed: () => showConfirmSheet(context, confirm),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  test('asks one request at a time, in arrival order', () async {
    final confirm = ConfirmController();
    final first = confirm.ask(_request('notes_create', 'first'));
    final second = confirm.ask(_request('calendar_delete_event', 'second'));

    expect(confirm.pending?.summary, 'first');
    confirm.resolve(ConfirmDecision.allowOnce);
    expect(await first, ConfirmDecision.allowOnce);

    expect(confirm.pending?.summary, 'second');
    confirm.resolve(ConfirmDecision.deny);
    expect(await second, ConfirmDecision.deny);
    expect(confirm.pending, isNull);
  });

  test('allowing for the chat answers queued asks for the same tool without asking again', () async {
    final confirm = ConfirmController();
    final first = confirm.ask(_request('notes_create', 'first'));
    final sameTool = confirm.ask(_request('notes_create', 'same tool, queued'));
    final otherTool = confirm.ask(_request('calendar_create_event', 'other tool'));

    confirm.resolve(ConfirmDecision.allowForSession);

    expect(await first, ConfirmDecision.allowForSession);
    expect(await sameTool, ConfirmDecision.allowForSession);
    expect(confirm.pending?.summary, 'other tool');

    final later = confirm.ask(_request('notes_create', 'later'));
    expect(await later, ConfirmDecision.allowForSession);
    expect(confirm.pending?.summary, 'other tool');

    confirm.resolve(ConfirmDecision.deny);
    expect(await otherTool, ConfirmDecision.deny);
  });

  test('a plain allow or a deny does not carry over to the next request of that tool', () async {
    final confirm = ConfirmController();
    final first = confirm.ask(_request('notes_create', 'first'));
    final second = confirm.ask(_request('notes_create', 'second'));

    confirm.resolve(ConfirmDecision.allowOnce);
    expect(await first, ConfirmDecision.allowOnce);
    expect(confirm.pending?.summary, 'second');

    confirm.resolve(ConfirmDecision.deny);
    expect(await second, ConfirmDecision.deny);
    final third = confirm.ask(_request('notes_create', 'third'));
    expect(confirm.pending?.summary, 'third');
    confirm.resolve(ConfirmDecision.deny);
    expect(await third, ConfirmDecision.deny);
  });

  test('reset forgets the allowances given for the chat', () async {
    final confirm = ConfirmController();
    final first = confirm.ask(_request('notes_create', 'first'));
    confirm.resolve(ConfirmDecision.allowForSession);
    expect(await first, ConfirmDecision.allowForSession);

    confirm.reset();

    final next = confirm.ask(_request('notes_create', 'after reset'));
    expect(confirm.pending?.summary, 'after reset');
    confirm.resolve(ConfirmDecision.deny);
    expect(await next, ConfirmDecision.deny);
  });

  test('listeners hear when the request on screen changes', () {
    final confirm = ConfirmController();
    var changes = 0;
    confirm.addListener(() => changes++);

    confirm.ask(_request('notes_create', 'first'));
    expect(changes, 1);
    confirm.ask(_request('calendar_create_event', 'second'));
    expect(changes, 1, reason: 'a request queued behind another is not on screen yet');

    confirm.resolve(ConfirmDecision.allowOnce);
    expect(changes, 2);
  });

  test('disposing answers waiting requests with deny', () async {
    final confirm = ConfirmController();
    final waiting = confirm.ask(_request('notes_create', 'waiting'));
    confirm.dispose();
    expect(await waiting, ConfirmDecision.deny);
  });

  group('confirm view', () {
    test('a multi-line summary shows its code once, in full, as the body', () {
      const code = "import os\nprint(os.listdir('.'))";
      final view = confirmView(_request(
        'run_python',
        'Run Python in the sandbox:\n$code',
        arguments: {'code': code},
        schema: const {
          'type': 'object',
          'properties': {'code': {'type': 'string'}},
          'required': ['code'],
        },
      ));

      expect(view.headline, 'Run Python in the sandbox:');
      expect(view.body, code);
      expect(view.details, isEmpty);
    });

    test('empty, null, zero and default-looking arguments are dropped', () {
      final view = confirmView(_request(
        'create_reminder',
        "Create reminder 'Stretch'",
        arguments: {
          'title': 'Stretch',
          'weekdays': <String>[],
          'every_minutes': 0,
          'model': '',
          'count': 1,
          'note': null,
          'room': 'Office',
        },
        schema: const {
          'type': 'object',
          'properties': {
            'title': {'type': 'string'},
            'weekdays': {'type': 'array'},
            'every_minutes': {'type': 'integer'},
            'model': {'type': 'string'},
            'count': {'type': 'integer', 'default': 1},
            'note': {'type': 'string'},
            'room': {'type': 'string'},
          },
          'required': ['title'],
        },
      ));

      expect(view.headline, "Create reminder 'Stretch'");
      expect([for (final e in view.details) e.key], ['room']);
    });

    test('a required zero is kept', () {
      final view = confirmView(_request(
        'set_interval',
        'Set the interval',
        arguments: {'every_minutes': 0},
        schema: const {
          'type': 'object',
          'properties': {'every_minutes': {'type': 'integer'}},
          'required': ['every_minutes'],
        },
      ));

      expect([for (final e in view.details) e.key], ['every_minutes']);
    });

    test('one short value opens the details by itself, several stay folded', () {
      final one = confirmView(_request('notes_create', 'Create note', arguments: {'room': 'Office'}));
      final two = confirmView(_request(
        'notes_create',
        'Create note',
        arguments: {'room': 'Office', 'notes': 'Bring the blue folder'},
      ));

      expect(one.detailsOpenByDefault, isTrue);
      expect(two.detailsOpenByDefault, isFalse);
    });
  });

  group('confirm sheet', () {
    testWidgets('allow for this chat answers the request and closes the sheet', (tester) async {
      final confirm = ConfirmController();
      final answer = confirm.ask(_request(
        'notes_create',
        "Create note 'Milk'",
        arguments: {'title': 'Milk'},
      ));
      await _openSheet(tester, confirm);

      expect(find.text("Create note 'Milk'"), findsOneWidget);
      expect(find.text('Milk'), findsNothing, reason: 'the headline already states the title');

      await tester.tap(find.text('Allow for this chat'));
      await tester.pumpAndSettle();

      expect(await answer, ConfirmDecision.allowForSession);
      expect(find.text("Create note 'Milk'"), findsNothing);
    });

    testWidgets('details stay folded until the person opens them', (tester) async {
      final confirm = ConfirmController();
      final answer = confirm.ask(_request(
        'notes_create',
        'Create note',
        arguments: {'room': 'Office', 'notes': 'Bring the blue folder'},
      ));
      await _openSheet(tester, confirm);

      expect(find.text('Office'), findsNothing);

      await tester.tap(find.text('Details'));
      await tester.pumpAndSettle();

      expect(find.text('Office'), findsOneWidget);

      await tester.tap(find.text('Deny'));
      await tester.pumpAndSettle();
      expect(await answer, ConfirmDecision.deny);
    });

    testWidgets('back denies the request', (tester) async {
      final confirm = ConfirmController();
      final answer = confirm.ask(_request('notes_delete', 'Delete note Milk'));
      await _openSheet(tester, confirm);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(await answer, ConfirmDecision.deny);
      expect(find.text('Delete note Milk'), findsNothing);
    });
  });
}

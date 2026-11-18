import 'package:flutter_test/flutter_test.dart';
import 'package:focus_launcher/agent/tools/agent_tool.dart';
import 'package:focus_launcher/agent/ui/confirm_controller.dart';
import 'package:focus_launcher/agent/ui/confirm_sheet.dart';
import 'package:material_ui/material_ui.dart';

class _FakeTool extends AgentTool {
  _FakeTool(this.name);

  @override
  final String name;

  @override
  String get source => 'notes';

  @override
  String get description => 'fake';

  @override
  Map<String, dynamic> get parameters => const {'type': 'object', 'properties': {}};

  @override
  ToolRisk get risk => ToolRisk.write;

  @override
  String describeCall(Map<String, dynamic> args) => 'Run $name';

  @override
  Future<ToolResult> run(Map<String, dynamic> args) async => const ToolResult('ok');
}

ConfirmRequest _request(String tool, String summary, {Map<String, dynamic> arguments = const {}}) =>
    ConfirmRequest(tool: _FakeTool(tool), summary: summary, arguments: arguments);

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

  group('confirm sheet', () {
    testWidgets('allow for this chat answers the request and closes the sheet', (tester) async {
      final confirm = ConfirmController();
      final answer = confirm.ask(_request(
        'notes_create',
        "Create note 'Milk'",
        arguments: {'title': 'Milk'},
      ));
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

      expect(find.text("Create note 'Milk'"), findsOneWidget);
      expect(find.text('Milk'), findsOneWidget);

      await tester.tap(find.text('Allow for this chat'));
      await tester.pumpAndSettle();

      expect(await answer, ConfirmDecision.allowForSession);
      expect(find.text("Create note 'Milk'"), findsNothing);
    });

    testWidgets('back denies the request', (tester) async {
      final confirm = ConfirmController();
      final answer = confirm.ask(_request('notes_delete', 'Delete note Milk'));
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

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(await answer, ConfirmDecision.deny);
      expect(find.text('Delete note Milk'), findsNothing);
    });
  });
}

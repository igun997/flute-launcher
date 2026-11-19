import 'package:flutter_test/flutter_test.dart';
import 'package:focus_launcher/agent/runtime/agent_runtime.dart';
import 'package:focus_launcher/agent/ui/chat_bubbles.dart';
import 'package:material_ui/material_ui.dart';

String _plainText(WidgetTester tester) => tester
    .widgetList<RichText>(find.byType(RichText))
    .map((r) => r.text.toPlainText())
    .join('\n');

Widget _host(Widget child) => MaterialApp(
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

void main() {
  testWidgets('a reply is drawn as Markdown, not as raw syntax', (tester) async {
    final item = AssistantItem(id: 'a1', text: '# Plan\n\nBuy **milk** and eggs.');
    await tester.pumpWidget(_host(AssistantMessage(item: item)));

    final plain = _plainText(tester);
    expect(plain, contains('Plan'));
    expect(plain, contains('Buy milk and eggs.'));
    expect(plain, isNot(contains('**')));
    expect(plain, isNot(contains('# Plan')));
  });

  testWidgets('reasoning stays folded until the person opens it', (tester) async {
    final item = AssistantItem(id: 'a2', text: 'Done.', reasoning: 'Check the calendar first');
    await tester.pumpWidget(_host(AssistantMessage(item: item)));

    expect(find.text('Check the calendar first'), findsNothing);
    expect(find.text('Thought'), findsOneWidget);

    await tester.tap(find.text('Thought'));
    await tester.pumpAndSettle();

    expect(find.text('Check the calendar first'), findsOneWidget);
  });

  testWidgets('a video attachment shows as a named tile next to the text', (tester) async {
    final item = UserItem(
      id: 'u1',
      text: 'What happens here?',
      attachments: [Attachment(kind: AttachmentKind.video, path: '/tmp/clip.mp4', name: 'clip.mp4')],
    );
    await tester.pumpWidget(_host(UserMessage(item: item)));

    expect(find.text('What happens here?'), findsOneWidget);
    expect(find.text('clip.mp4'), findsOneWidget);
  });

  testWidgets('a tool card keeps its output folded until the card is tapped', (tester) async {
    final item = ToolItem(
      id: 't1',
      toolName: 'notes_create',
      source: 'notes',
      summary: "Create note 'Milk'\nextra",
    )
      ..state = ToolState.done
      ..output = 'Saved note 42';
    await tester.pumpWidget(_host(ToolCard(item: item)));

    expect(find.text("Create note 'Milk'"), findsOneWidget);
    expect(find.text('Done'), findsOneWidget);
    expect(find.text('Saved note 42'), findsNothing);

    await tester.tap(find.text("Create note 'Milk'"));
    await tester.pumpAndSettle();

    expect(find.text('Saved note 42'), findsOneWidget);
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:focus_launcher/agent/runtime/agent_runtime.dart';
import 'package:focus_launcher/agent/ui/chat_bubbles.dart';
import 'package:material_ui/material_ui.dart';

String _plainText(WidgetTester tester) => tester
    .widgetList<RichText>(find.byType(RichText))
    .map((r) => r.text.toPlainText())
    .join('\n');

Widget _host(Widget child, {double width = 360}) => MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: SizedBox(width: width, child: child),
        ),
      ),
    );

const _table = '''
| Name | Count | Note |
|:-----|:-----:|-----:|
| `code` | **bold** | right |
| plain | 2 | x |
''';

final _wideTable = '| ${List.generate(10, (i) => 'Column$i').join(' | ')} |\n'
    '| ${List.generate(10, (_) => '---').join(' | ')} |\n'
    '| ${List.generate(10, (i) => 'value number $i that is long').join(' | ')} |\n';

void main() {
  group('GitHub-style tables', () {
    testWidgets('a pipe table renders as cells with bold and plain rows, not raw pipes', (tester) async {
      await tester.pumpWidget(_host(ChatMarkdown(_table)));
      await tester.pumpAndSettle();

      final plain = _plainText(tester);
      expect(plain, contains('Name'));
      expect(plain, contains('Count'));
      expect(plain, contains('plain')); // body rows render, not just the header
      expect(plain, contains('bold'));
      expect(plain, isNot(contains('|')));
      expect(plain, isNot(contains('**')));
      expect(tester.takeException(), isNull);
    });

    testWidgets('a table wider than the bubble scrolls instead of overflowing', (tester) async {
      await tester.pumpWidget(_host(ChatMarkdown(_wideTable), width: 320));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(_plainText(tester), contains('Column9'));
    });
  });

  group('generation stats', () {
    final t0 = DateTime(2026, 1, 1, 12);

    AssistantItem item({
      bool streaming = false,
      int? outputTokens,
      int receivedChars = 0,
      String text = 'Hello there',
      String? error,
      DateTime? firstTokenAt,
      DateTime? endedAt,
    }) {
      return AssistantItem(id: 'a', text: text, streaming: streaming, error: error)
        ..startedAt = t0
        ..firstTokenAt = firstTokenAt
        ..endedAt = endedAt
        ..outputTokens = outputTokens
        ..receivedChars = receivedChars;
    }

    testWidgets('a finished turn shows speed, tokens, duration and time to first token', (tester) async {
      final done = item(
        outputTokens: 40,
        firstTokenAt: t0.add(const Duration(seconds: 1)),
        endedAt: t0.add(const Duration(seconds: 5)),
      );
      await tester.pumpWidget(_host(AssistantMessage(item: done, clock: () => t0.add(const Duration(seconds: 9)))));

      // 40 tokens over the 4 s after the first token = 10 tok/s; the clock is ignored once ended.
      expect(find.text('10 tok/s · 40 tokens · 5.0 s · first token 1.0 s'), findsOneWidget);
    });

    testWidgets('a live turn shows estimated tokens with a tilde and no first-token time yet', (tester) async {
      final live = item(
        streaming: true,
        receivedChars: 40,
        firstTokenAt: t0.add(const Duration(seconds: 1)),
      );
      await tester.pumpWidget(_host(AssistantMessage(item: live, clock: () => t0.add(const Duration(seconds: 3)))));

      // 10 estimated tokens over 2 s after the first token = 5 tok/s; elapsed is 3 s.
      expect(find.text('5 tok/s · ~10 tokens · 3.0 s'), findsOneWidget);

      await tester.pumpWidget(_host(const SizedBox()));
    });

    testWidgets('a turn with no text or reasoning shows no stats line', (tester) async {
      final empty = item(text: '', error: 'Connection lost', outputTokens: 0);
      await tester.pumpWidget(_host(AssistantMessage(item: empty, clock: () => t0)));

      expect(find.textContaining('tokens'), findsNothing);
      expect(find.text('Connection lost'), findsOneWidget);
    });
  });
}

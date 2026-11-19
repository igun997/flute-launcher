import 'package:flutter_test/flutter_test.dart';
import 'package:focus_launcher/agent/voice/voice_page.dart';

void main() {
  group('plainReplyText', () {
    test('drops heading marks and keeps the words', () {
      expect(plainReplyText('## Title\n\nSome text.'), 'Title Some text.');
    });

    test('turns list items into a sentence', () {
      expect(plainReplyText('- one\n- two\n1. three'), 'one two three');
    });

    test('keeps link and image labels, drops URLs', () {
      expect(
        plainReplyText('[Flute](https://example.com) is ![logo](a.png) ok'),
        'Flute is logo ok',
      );
    });

    test('drops code fences but keeps the text after them', () {
      expect(plainReplyText('```dart\nfinal x = 1;\n```\nDone.'), 'Done.');
    });

    test('flattens table rows and drops the rule line', () {
      expect(plainReplyText('| a | b |\n|---|---|\n| 1 | 2 |'), 'a b 1 2');
    });

    test('removes emphasis and inline code markers', () {
      expect(plainReplyText('Use `x` **now**, _soon_ and *later*'), 'Use x now, soon and later');
    });

    test('keeps underscores inside words', () {
      expect(plainReplyText('use my_var here'), 'use my_var here');
    });

    test('returns empty text for markup only', () {
      expect(plainReplyText('```\n```\n|---|'), '');
    });
  });
}

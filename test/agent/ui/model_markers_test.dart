import 'package:flutter_test/flutter_test.dart';
import 'package:focus_launcher/agent/ui/chat_bubbles.dart';

void main() {
  test('citation markers in private-use characters are removed, plain text is untouched', () {
    expect(stripModelMarkers('Flutter 3.50 \uE200cite\uE202turn2search1\uE201 is out.'), 'Flutter 3.50  is out.');
    expect(stripModelMarkers('Hello \u4e2d\u6587 \u{1F600} world'), 'Hello \u4e2d\u6587 \u{1F600} world');
  });

  test('a marker still streaming in is cut, and stray marker characters go', () {
    expect(stripModelMarkers('Answer \uE200cite\uE202turn2sea'), 'Answer ');
    expect(stripModelMarkers('a\uE202b'), 'ab');
  });
}

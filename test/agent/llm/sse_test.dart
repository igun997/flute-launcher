import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:focus_launcher/agent/llm/sse.dart';

Future<List<SseEvent>> parseChunks(List<List<int>> chunks) =>
    parseSse(Stream.fromIterable(chunks)).toList();

void main() {
  test('joins data lines and reads the event name', () async {
    final events = await parseChunks([
      utf8.encode('event: message\ndata: one\ndata: two\n\n'),
    ]);
    expect(events, hasLength(1));
    expect(events.single.event, 'message');
    expect(events.single.data, 'one\ntwo');
  });

  test('skips comments and blank keep-alives', () async {
    final events = await parseChunks([
      utf8.encode(': ping\n\n\n\ndata: x\n\n'),
    ]);
    expect(events.map((e) => e.data), ['x']);
  });

  test('accepts CRLF line endings', () async {
    final events = await parseChunks([
      utf8.encode('data: a\r\n\r\ndata: b\r\n\r\n'),
    ]);
    expect(events.map((e) => e.data), ['a', 'b']);
  });

  test('reassembles lines and a UTF-8 character split across chunks', () async {
    final bytes = utf8.encode('data: héllo wörld\n\ndata: ok\n\n');
    final splitInCharacter = bytes.indexOf(0xC3) + 1; // inside the two bytes of "é"
    final splitInLine = bytes.indexOf(0x0A) + 3; // inside the next line
    final events = await parseChunks([
      bytes.sublist(0, splitInCharacter),
      bytes.sublist(splitInCharacter, splitInLine),
      bytes.sublist(splitInLine),
    ]);
    expect(events.map((e) => e.data), ['héllo wörld', 'ok']);
  });

  test('a message left open when the body ends is still delivered', () async {
    final events = await parseChunks([utf8.encode('data: last')]);
    expect(events.map((e) => e.data), ['last']);
  });

  test('the event name does not carry over to the next message', () async {
    final events = await parseChunks([
      utf8.encode('event: a\ndata: 1\n\ndata: 2\n\n'),
    ]);
    expect(events[0].event, 'a');
    expect(events[1].event, isNull);
  });
}

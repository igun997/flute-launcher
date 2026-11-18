import 'dart:async';
import 'dart:convert';

/// One Server-Sent Events message.
class SseEvent {
  const SseEvent({this.event, required this.data});

  /// The `event:` field, or null when the message did not name one.
  final String? event;

  /// The `data:` lines joined with newlines.
  final String data;
}

/// Parses a Server-Sent Events body into messages (WHATWG rules): comment lines and blank
/// keep-alives are skipped, CRLF and lone CR end lines, and a multi-byte character may be split
/// across chunks. A message still open when the body ends is delivered too, so a gateway that
/// drops the final blank line does not lose its last event.
Stream<SseEvent> parseSse(Stream<List<int>> bytes) async* {
  final lines = bytes
      .transform(Utf8Decoder(allowMalformed: true))
      .transform(const LineSplitter());
  String? event;
  var dataLines = <String>[];
  await for (final line in lines) {
    if (line.isEmpty) {
      if (dataLines.isNotEmpty) {
        yield SseEvent(event: event, data: dataLines.join('\n'));
      }
      event = null;
      dataLines = [];
      continue;
    }
    if (line.startsWith(':')) continue;
    final colon = line.indexOf(':');
    final field = colon < 0 ? line : line.substring(0, colon);
    var value = colon < 0 ? '' : line.substring(colon + 1);
    if (value.startsWith(' ')) value = value.substring(1);
    if (field == 'event') {
      event = value;
    } else if (field == 'data') {
      dataLines.add(value);
    }
  }
  if (dataLines.isNotEmpty) {
    yield SseEvent(event: event, data: dataLines.join('\n'));
  }
}

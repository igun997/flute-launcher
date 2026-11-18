import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:focus_launcher/agent/llm/llm_types.dart';
import 'package:focus_launcher/agent/ui/settings_widgets.dart';
import 'package:http/http.dart' as http;

void main() {
  test('provider messages are shown as written', () {
    const error = LlmException('The key was refused. Check it in your provider settings.', statusCode: 401);
    expect(readableError(error), 'The key was refused. Check it in your provider settings.');
  });

  test('timeouts and network failures get plain sentences', () {
    expect(readableError(TimeoutException('slow')), contains('too long'));
    expect(readableError(const SocketException('Failed host lookup')), 'Cannot reach the server. Check your connection.');
    expect(readableError(http.ClientException('boom')), 'Cannot reach the server. Check your connection.');
  });

  test('validation messages pass through, unknown errors stay generic', () {
    expect(readableError(const FormatException('Enter both the username and the password.')),
        'Enter both the username and the password.');
    expect(readableError(StateError('internal detail')), 'Something went wrong. Please try again.');
  });

  test('long exception text is cut so the sheet stays readable', () {
    final long = Exception('x' * 500);
    final text = readableError(long);
    expect(text.length, lessThanOrEqualTo(203));
    expect(text.endsWith('...'), isTrue);
  });
}

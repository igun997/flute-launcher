import 'package:flutter_test/flutter_test.dart';
import 'package:focus_launcher/agent/sandbox/sandbox_tools.dart';

void main() {
  test('the transcription script escapes the path and language so they cannot break out', () {
    final script = transcribeScript(audioPath: '/tmp/a"b\nimport os.m4a', language: 'en"; x=1');
    expect(script, contains(r'"/tmp/a\"b\nimport os.m4a"'));
    expect(script, contains(r'language="en\"; x=1"'));
    expect(script.split('\n').where((l) => l.startsWith('import os')), isEmpty);
  });

  test('no language means auto-detect, and the model size is passed through', () {
    final script = transcribeScript(audioPath: '/tmp/a.wav', model: 'small');
    expect(script, contains('WhisperModel("small"'));
    expect(script, contains('language=None'));
  });
}

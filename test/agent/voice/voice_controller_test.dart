import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:focus_launcher/agent/voice/voice_controller.dart';
import 'package:focus_launcher/agent/voice/voice_native.dart';
import 'package:shared_preferences/shared_preferences.dart';

class FakeVoiceEngine implements VoiceEngine {
  final _events = StreamController<VoiceEvent>.broadcast();

  bool micGranted = true;
  bool micRequestGranted = true;
  bool listenResult = true;
  bool listenThrows = false;
  bool speakThrows = false;

  int listenCalls = 0;
  String? lastListenLocale;
  int stopListeningCalls = 0;
  int cancelListeningCalls = 0;
  int stopSpeakingCalls = 0;
  final spoken = <({String text, String id, String? language, double rate})>[];

  @override
  Stream<VoiceEvent> get events => _events.stream;

  void emit(VoiceEvent event) => _events.add(event);

  Future<void> close() => _events.close();

  @override
  Future<bool> hasMicPermission() async => micGranted;

  @override
  Future<bool> requestMicPermission() async => micRequestGranted;

  @override
  Future<bool> isOnDeviceAvailable() async => false;

  @override
  Future<bool> listen({String? locale, bool onDevice = false}) async {
    listenCalls++;
    if (listenThrows) throw Exception('recognizer unavailable');
    lastListenLocale = locale;
    return listenResult;
  }

  @override
  Future<void> stopListening() async => stopListeningCalls++;

  @override
  Future<void> cancelListening() async => cancelListeningCalls++;

  @override
  Future<void> speak({
    required String text,
    required String id,
    String? language,
    double rate = 1.0,
  }) async {
    if (speakThrows) throw Exception('tts failed');
    spoken.add((text: text, id: id, language: language, rate: rate));
  }

  @override
  Future<void> stopSpeaking() async => stopSpeakingCalls++;
}

Future<VoiceController> makeController(
  FakeVoiceEngine engine, {
  Map<String, Object> prefs = const {},
}) async {
  SharedPreferences.setMockInitialValues(prefs);
  final sp = await SharedPreferences.getInstance();
  final controller = VoiceController(engine: engine, prefs: sp);
  return controller;
}

void main() {
  group('settings', () {
    test('loads persisted values and clamps the rate', () async {
      final engine = FakeVoiceEngine();
      addTearDown(engine.close);
      final c = await makeController(engine, prefs: {
        'voice.language': '  id-ID ',
        'voice.rate': 9.0,
        'voice.autoSpeak': false,
        'voice.handsFree': true,
      });
      addTearDown(c.dispose);

      expect(c.language, 'id-ID');
      expect(c.rate, 2.0);
      expect(c.autoSpeak, isFalse);
      expect(c.handsFree, isTrue);
    });

    test('defaults when nothing is stored', () async {
      final engine = FakeVoiceEngine();
      addTearDown(engine.close);
      final c = await makeController(engine);
      addTearDown(c.dispose);

      expect(c.language, isNull);
      expect(c.rate, 1.0);
      expect(c.autoSpeak, isTrue);
      expect(c.handsFree, isFalse);
    });

    test('setRate clamps and persists the value', () async {
      final engine = FakeVoiceEngine();
      addTearDown(engine.close);
      SharedPreferences.setMockInitialValues({});
      final sp = await SharedPreferences.getInstance();
      final c = VoiceController(engine: engine, prefs: sp);
      addTearDown(c.dispose);

      c.setRate(0.1);
      expect(c.rate, 0.5);
      await pumpEventQueue();
      expect(sp.getDouble('voice.rate'), 0.5);
    });
  });

  group('listenOnce', () {
    test('returns the trimmed final text and passes the language', () async {
      final engine = FakeVoiceEngine();
      addTearDown(engine.close);
      final c = await makeController(engine);
      addTearDown(c.dispose);
      c.setLanguage('id-ID');

      final heard = c.listenOnce();
      await pumpEventQueue();
      expect(c.listening, isTrue);
      expect(engine.lastListenLocale, 'id-ID');

      engine.emit(const VoicePartial('hel'));
      await pumpEventQueue();
      expect(c.partial, 'hel');

      engine.emit(const VoiceFinal('  hello there  '));
      expect(await heard, 'hello there');
      expect(c.listening, isFalse);
      expect(c.partial, '');
    });

    test('an empty final result means nothing was heard', () async {
      final engine = FakeVoiceEngine();
      addTearDown(engine.close);
      final c = await makeController(engine);
      addTearDown(c.dispose);

      final heard = c.listenOnce();
      await pumpEventQueue();
      engine.emit(const VoiceFinal('   '));
      expect(await heard, isNull);
      expect(c.error, isNull);
    });

    test('denied microphone permission reports permission and never listens',
        () async {
      final engine = FakeVoiceEngine()
        ..micGranted = false
        ..micRequestGranted = false;
      addTearDown(engine.close);
      final c = await makeController(engine);
      addTearDown(c.dispose);

      expect(await c.listenOnce(), isNull);
      expect(c.error, 'permission');
      expect(engine.listenCalls, 0);
      expect(c.listening, isFalse);
    });

    test('no_speech ends quietly while other errors are reported', () async {
      final engine = FakeVoiceEngine();
      addTearDown(engine.close);
      final c = await makeController(engine);
      addTearDown(c.dispose);

      final quiet = c.listenOnce();
      await pumpEventQueue();
      engine.emit(const VoiceRecognitionError('no_speech'));
      expect(await quiet, isNull);
      expect(c.error, isNull);

      final failing = c.listenOnce();
      await pumpEventQueue();
      engine.emit(const VoiceRecognitionError('network'));
      expect(await failing, isNull);
      expect(c.error, 'network');
    });

    test('a refused start reports unknown', () async {
      final engine = FakeVoiceEngine()..listenResult = false;
      addTearDown(engine.close);
      final c = await makeController(engine);
      addTearDown(c.dispose);

      expect(await c.listenOnce(), isNull);
      expect(c.error, 'unknown');
      expect(c.listening, isFalse);
    });

    test('a throwing recognizer reports unknown and stops listening',
        () async {
      final engine = FakeVoiceEngine()..listenThrows = true;
      addTearDown(engine.close);
      final c = await makeController(engine);
      addTearDown(c.dispose);

      expect(await c.listenOnce(), isNull);
      expect(c.error, 'unknown');
      expect(c.listening, isFalse);
    });

    test('cancelListen drops what was heard', () async {
      final engine = FakeVoiceEngine();
      addTearDown(engine.close);
      final c = await makeController(engine);
      addTearDown(c.dispose);

      final heard = c.listenOnce();
      await pumpEventQueue();
      c.cancelListen();
      expect(await heard, isNull);
      await pumpEventQueue();
      expect(engine.cancelListeningCalls, 1);
    });

    test('finishListen asks the engine to stop and keeps the result',
        () async {
      final engine = FakeVoiceEngine();
      addTearDown(engine.close);
      final c = await makeController(engine);
      addTearDown(c.dispose);

      final heard = c.listenOnce();
      await pumpEventQueue();
      await c.finishListen();
      expect(engine.stopListeningCalls, 1);

      engine.emit(const VoiceFinal('done'));
      expect(await heard, 'done');
    });
  });

  group('speech', () {
    test('speakAndWait completes when the engine reports speech done',
        () async {
      final engine = FakeVoiceEngine();
      addTearDown(engine.close);
      final c = await makeController(engine);
      addTearDown(c.dispose);

      final done = c.speakAndWait('Hi there');
      await pumpEventQueue();
      expect(engine.spoken.single.text, 'Hi there');
      expect(c.state, VoiceState.speaking);

      engine.emit(VoiceSpeechDone(engine.spoken.single.id));
      await done;
      expect(c.state, VoiceState.idle);
    });

    test('a failed tts start reports tts_failed and does not hang', () async {
      final engine = FakeVoiceEngine()..speakThrows = true;
      addTearDown(engine.close);
      final c = await makeController(engine);
      addTearDown(c.dispose);

      await c.speakAndWait('Hi');
      expect(c.error, 'tts_failed');
    });

    test('a speech error event is reported and completes the wait', () async {
      final engine = FakeVoiceEngine();
      addTearDown(engine.close);
      final c = await makeController(engine);
      addTearDown(c.dispose);

      final done = c.speakAndWait('Hi');
      await pumpEventQueue();
      engine.emit(
        VoiceSpeechError(engine.spoken.single.id, 'tts_unavailable'),
      );
      await done;
      expect(c.error, 'tts_unavailable');
    });

    test('stop silences the engine and releases a waiting speaker', () async {
      final engine = FakeVoiceEngine();
      addTearDown(engine.close);
      final c = await makeController(engine);
      addTearDown(c.dispose);

      final done = c.speakAndWait('Long sentence');
      await pumpEventQueue();
      await c.stop();
      await done;
      expect(engine.stopSpeakingCalls, 1);
      expect(c.state, VoiceState.idle);
    });

    test('blank text is never spoken', () async {
      final engine = FakeVoiceEngine();
      addTearDown(engine.close);
      final c = await makeController(engine);
      addTearDown(c.dispose);

      await c.speakAndWait('   ');
      expect(engine.spoken, isEmpty);
    });
  });

  group('readReply', () {
    test('speaks each sentence once as the reply streams in', () async {
      final engine = FakeVoiceEngine();
      addTearDown(engine.close);
      final c = await makeController(engine);
      addTearDown(c.dispose);

      c.readReply('item-1', 'Hello there. How', done: false);
      await pumpEventQueue();
      expect(engine.spoken.map((s) => s.text), ['Hello there.']);

      c.readReply('item-1', 'Hello there. How are you.', done: true);
      await pumpEventQueue();
      expect(engine.spoken.map((s) => s.text), [
        'Hello there.',
        'How are you.',
      ]);
    });

    test('autoSpeak off means the reply is not spoken', () async {
      final engine = FakeVoiceEngine();
      addTearDown(engine.close);
      final c = await makeController(engine, prefs: {
        'voice.autoSpeak': false,
      });
      addTearDown(c.dispose);

      c.readReply('item-1', 'Hello there.', done: true);
      await pumpEventQueue();
      expect(engine.spoken, isEmpty);
    });

    test('stop mutes the rest of the reply until the next turn', () async {
      final engine = FakeVoiceEngine();
      addTearDown(engine.close);
      final c = await makeController(engine);
      addTearDown(c.dispose);

      await c.stop();
      c.readReply('item-1', 'Muted sentence.', done: true);
      await pumpEventQueue();
      expect(engine.spoken, isEmpty);

      c.setThinking(true);
      c.readReply('item-2', 'Next turn.', done: true);
      await pumpEventQueue();
      expect(engine.spoken.map((s) => s.text), ['Next turn.']);
    });

    test('speech uses the configured language and rate', () async {
      final engine = FakeVoiceEngine();
      addTearDown(engine.close);
      final c = await makeController(engine);
      addTearDown(c.dispose);
      c.setLanguage('en-US');
      c.setRate(1.5);

      c.readReply('item-1', 'Ready.', done: true);
      await pumpEventQueue();
      expect(engine.spoken.single.language, 'en-US');
      expect(engine.spoken.single.rate, 1.5);
    });
  });

  group('voice mode', () {
    test('turning voice mode off cancels listening and speech', () async {
      final engine = FakeVoiceEngine();
      addTearDown(engine.close);
      final c = await makeController(engine);
      addTearDown(c.dispose);

      c.setVoiceMode(true);
      final heard = c.listenOnce();
      await pumpEventQueue();
      c.setVoiceMode(false);
      expect(await heard, isNull);
      await pumpEventQueue();
      expect(engine.cancelListeningCalls, 1);
      expect(engine.stopSpeakingCalls, 1);
      expect(c.voiceMode, isFalse);
    });
  });
}

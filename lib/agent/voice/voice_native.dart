import 'package:flutter/services.dart';

/// Events from the native speech recognizer and text-to-speech engine.
sealed class VoiceEvent {
  const VoiceEvent();
}

final class VoiceLevel extends VoiceEvent {
  const VoiceLevel(this.value);
  final double value;
}

final class VoicePartial extends VoiceEvent {
  const VoicePartial(this.text);
  final String text;
}

final class VoiceFinal extends VoiceEvent {
  const VoiceFinal(this.text);
  final String text;
}

/// [code] is one of no_speech, network, audio, permission, busy, unknown.
final class VoiceRecognitionError extends VoiceEvent {
  const VoiceRecognitionError(this.code);
  final String code;
}

final class VoiceSpeechDone extends VoiceEvent {
  const VoiceSpeechDone(this.id);
  final String id;
}

final class VoiceSpeechStopped extends VoiceEvent {
  const VoiceSpeechStopped(this.id);
  final String id;
}

/// [message] is tts_unavailable or tts_failed.
final class VoiceSpeechError extends VoiceEvent {
  const VoiceSpeechError(this.id, this.message);
  final String id;
  final String message;
}

VoiceEvent? parseVoiceEvent(Object? raw) {
  if (raw is! Map) return null;
  final type = raw['type'];
  final id = raw['id'];
  switch (type) {
    case 'level':
      final value = raw['value'];
      return value is num ? VoiceLevel(value.toDouble()) : null;
    case 'partial':
      final text = raw['text'];
      return text is String ? VoicePartial(text) : null;
    case 'final':
      final text = raw['text'];
      return text is String ? VoiceFinal(text) : null;
    case 'error':
      final code = raw['code'];
      return code is String ? VoiceRecognitionError(code) : null;
    case 'speechDone':
      return id is String ? VoiceSpeechDone(id) : null;
    case 'speechStopped':
      return id is String ? VoiceSpeechStopped(id) : null;
    case 'speechError':
      final message = raw['message'];
      return id is String && message is String
          ? VoiceSpeechError(id, message)
          : null;
  }
  return null;
}

/// Speech input and output. Tests replace it with a fake.
abstract interface class VoiceEngine {
  Stream<VoiceEvent> get events;
  Future<bool> hasMicPermission();
  Future<bool> requestMicPermission();
  Future<bool> isOnDeviceAvailable();
  Future<bool> listen({String? locale, bool onDevice = false});
  Future<void> stopListening();
  Future<void> cancelListening();
  Future<void> speak({
    required String text,
    required String id,
    String? language,
    double rate = 1.0,
  });
  Future<void> stopSpeaking();
}

final class NativeVoiceEngine implements VoiceEngine {
  NativeVoiceEngine();

  static const MethodChannel _channel = MethodChannel('flute/voice');
  static const EventChannel _eventChannel = EventChannel('flute/voice_events');

  @override
  final Stream<VoiceEvent> events = _eventChannel
      .receiveBroadcastStream()
      .handleError((Object _) {})
      .expand((raw) {
        final event = parseVoiceEvent(raw);
        return event == null ? const <VoiceEvent>[] : <VoiceEvent>[event];
      })
      .asBroadcastStream();

  @override
  Future<bool> hasMicPermission() async =>
      (await _channel.invokeMethod<bool>('hasMicPermission')) ?? false;

  @override
  Future<bool> requestMicPermission() async =>
      (await _channel.invokeMethod<bool>('requestMicPermission')) ?? false;

  @override
  Future<bool> isOnDeviceAvailable() async =>
      (await _channel.invokeMethod<bool>('isOnDeviceAvailable')) ?? false;

  @override
  Future<bool> listen({String? locale, bool onDevice = false}) async =>
      (await _channel.invokeMethod<bool>('listen', {
        'locale': locale,
        'onDevice': onDevice,
      })) ??
      false;

  @override
  Future<void> stopListening() async {
    await _channel.invokeMethod<void>('stopListening');
  }

  @override
  Future<void> cancelListening() async {
    await _channel.invokeMethod<void>('cancelListening');
  }

  @override
  Future<void> speak({
    required String text,
    required String id,
    String? language,
    double rate = 1.0,
  }) async {
    await _channel.invokeMethod<void>('speak', {
      'text': text,
      'id': id,
      'language': language,
      'rate': rate,
    });
  }

  @override
  Future<void> stopSpeaking() async {
    await _channel.invokeMethod<void>('stopSpeaking');
  }
}

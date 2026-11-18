import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'voice_native.dart';

const _kLanguage = 'voice.language';
const _kRate = 'voice.rate';
const _kAutoSpeak = 'voice.autoSpeak';
const _kHandsFree = 'voice.handsFree';

enum VoiceState { idle, listening, thinking, speaking }

/// Speech input and output for voice mode. Replies are spoken as they stream
/// in; a listen ends with the recognized text.
class VoiceController extends ChangeNotifier {
  VoiceController({required this.engine, required SharedPreferences prefs})
    : _prefs = prefs,
      _language = _cleanLanguage(prefs.getString(_kLanguage)),
      _rate = _clampRate(prefs.getDouble(_kRate) ?? 1.0),
      _autoSpeak = prefs.getBool(_kAutoSpeak) ?? true,
      _handsFree = prefs.getBool(_kHandsFree) ?? false {
    _sub = engine.events.listen(_onEvent);
  }

  final VoiceEngine engine;
  final SharedPreferences _prefs;

  /// Input level 0..1 while listening. Read by the orb; does not notify.
  final ValueNotifier<double> levels = ValueNotifier(0);

  StreamSubscription<VoiceEvent>? _sub;

  String? _language;
  double _rate;
  bool _autoSpeak;
  bool _handsFree;
  bool _voiceMode = false;

  bool _listening = false;
  String _partial = '';
  String? _error;
  Completer<String?>? _heard;

  bool _thinking = false;
  bool _replyMuted = false;
  final Set<String> _speaking = {};
  final Map<String, Completer<void>> _waiters = {};
  int _speechSeq = 0;

  SpeechStream _stream = SpeechStream();
  String? _streamItem;
  String _streamText = '';

  bool _disposed = false;

  String? get language => _language;
  double get rate => _rate;
  bool get autoSpeak => _autoSpeak;
  bool get handsFree => _handsFree;
  bool get voiceMode => _voiceMode;
  bool get listening => _listening;
  String get partial => _partial;
  String? get error => _error;

  VoiceState get state {
    if (_listening) return VoiceState.listening;
    if (_speaking.isNotEmpty) return VoiceState.speaking;
    if (_thinking) return VoiceState.thinking;
    return VoiceState.idle;
  }

  void setLanguage(String? value) {
    _language = _cleanLanguage(value);
    final language = _language;
    if (language == null) {
      unawaited(_prefs.remove(_kLanguage));
    } else {
      unawaited(_prefs.setString(_kLanguage, language));
    }
    _notify();
  }

  void setRate(double value) {
    _rate = _clampRate(value);
    unawaited(_prefs.setDouble(_kRate, _rate));
    _notify();
  }

  void setAutoSpeak(bool value) {
    _autoSpeak = value;
    unawaited(_prefs.setBool(_kAutoSpeak, value));
    if (!value) unawaited(stop());
    _notify();
  }

  void setHandsFree(bool value) {
    _handsFree = value;
    unawaited(_prefs.setBool(_kHandsFree, value));
    _notify();
  }

  void clearError() {
    if (_error == null) return;
    _error = null;
    _notify();
  }

  /// Voice mode is on while the voice page is open. Turning it off stops
  /// listening and speech.
  void setVoiceMode(bool value) {
    if (_voiceMode == value) return;
    _voiceMode = value;
    if (!value) {
      cancelListen();
      unawaited(stop());
    }
    _notify();
  }

  /// Listens for one utterance. Returns the recognized text, or null when
  /// nothing was heard or listening failed (see [error]).
  Future<String?> listenOnce() async {
    if (_listening || _disposed) return null;
    _listening = true;
    _partial = '';
    _error = null;
    final heard = _heard = Completer<String?>();
    _notify();
    var started = false;
    try {
      if (await _ensureMicPermission()) {
        started = await engine.listen(locale: _language);
      } else {
        _error = 'permission';
      }
    } on Exception {
      started = false;
    }
    if (!started) {
      _error ??= 'unknown';
      _endListening();
      return null;
    }
    return heard.future;
  }

  /// Ends listening and keeps the words recognized so far.
  Future<void> finishListen() async {
    if (!_listening) return;
    await engine.stopListening();
  }

  /// Ends listening and drops what was heard.
  void cancelListen() {
    if (!_listening) return;
    _endListening();
    unawaited(_quiet(engine.cancelListening));
  }

  /// Speaks [text] and completes when it finished (or timed out).
  Future<void> speakAndWait(String text) async {
    final clean = text.trim();
    if (clean.isEmpty || _disposed) return;
    final id = 'prompt-${_speechSeq++}';
    final waiter = _waiters[id] = Completer<void>();
    await _speak(clean, id);
    if (_speaking.contains(id)) {
      await waiter.future.timeout(
        const Duration(seconds: 20),
        onTimeout: () => _finishSpeech(id),
      );
    }
    _waiters.remove(id);
  }

  /// Speaks the growing reply of assistant item [itemId]. Only text not spoken
  /// yet is queued.
  void readReply(String itemId, String text, {required bool done}) {
    if (!_autoSpeak || _replyMuted || _disposed) return;
    if (_streamItem != itemId) {
      _flushStream();
      _stream = SpeechStream();
      _streamItem = itemId;
      _streamText = '';
    }
    _streamText = text;
    _speakChunks(_stream.feed(text, done: done));
  }

  /// Call with the agent's busy state. A new turn unmutes replies.
  void setThinking(bool value) {
    if (_thinking == value) return;
    _thinking = value;
    if (value) {
      _stream = SpeechStream();
      _streamItem = null;
      _streamText = '';
      _replyMuted = false;
    } else {
      _flushStream();
    }
    _notify();
  }

  /// Stops speech and mutes the rest of the current reply.
  Future<void> stop() async {
    _replyMuted = true;
    _speaking.clear();
    final waiters = _waiters.values.toList();
    _waiters.clear();
    for (final waiter in waiters) {
      if (!waiter.isCompleted) waiter.complete();
    }
    _notify();
    await _quiet(engine.stopSpeaking);
  }

  Future<bool> _ensureMicPermission() async {
    if (await engine.hasMicPermission()) return true;
    return engine.requestMicPermission();
  }

  void _endListening({String? text}) {
    _listening = false;
    _partial = '';
    levels.value = 0;
    final heard = _heard;
    _heard = null;
    if (heard != null && !heard.isCompleted) heard.complete(text);
    _notify();
  }

  void _onEvent(VoiceEvent event) {
    if (_disposed) return;
    switch (event) {
      case VoiceLevel(:final value):
        if (_listening) {
          final v = value.clamp(0.0, 1.0).toDouble();
          levels.value = levels.value * 0.6 + v * 0.4;
        }
      case VoicePartial(:final text):
        if (_listening) {
          _partial = text;
          _notify();
        }
      case VoiceFinal(:final text):
        if (_listening) {
          final trimmed = text.trim();
          _endListening(text: trimmed.isEmpty ? null : trimmed);
        }
      case VoiceRecognitionError(:final code):
        if (_listening) {
          if (code != 'no_speech') _error = code;
          _endListening();
        }
      case VoiceSpeechDone(:final id) || VoiceSpeechStopped(:final id):
        _finishSpeech(id);
      case VoiceSpeechError(:final id, :final message):
        _error = message;
        _finishSpeech(id);
    }
  }

  Future<void> _speak(String text, String id) async {
    _speaking.add(id);
    _notify();
    try {
      await engine.speak(text: text, id: id, language: _language, rate: _rate);
    } on Exception {
      _error = 'tts_failed';
      _finishSpeech(id);
    }
  }

  void _finishSpeech(String id) {
    _speaking.remove(id);
    final waiter = _waiters.remove(id);
    if (waiter != null && !waiter.isCompleted) waiter.complete();
    _notify();
  }

  void _speakChunks(List<String> chunks) {
    for (final chunk in chunks) {
      unawaited(_speak(chunk, 'reply-${_speechSeq++}'));
    }
  }

  void _flushStream() {
    if (_streamItem == null || !_autoSpeak || _replyMuted) return;
    _speakChunks(_stream.feed(_streamText, done: true));
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> _quiet(Future<void> Function() call) async {
    try {
      await call();
    } on Exception {
      // The native side is gone or idle; there is nothing left to undo.
    }
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_sub?.cancel());
    final waiters = _waiters.values.toList();
    _waiters.clear();
    for (final waiter in waiters) {
      if (!waiter.isCompleted) waiter.complete();
    }
    final heard = _heard;
    _heard = null;
    if (heard != null && !heard.isCompleted) heard.complete();
    levels.dispose();
    super.dispose();
  }
}

String? _cleanLanguage(String? value) {
  final trimmed = value?.trim();
  return trimmed == null || trimmed.isEmpty ? null : trimmed;
}

double _clampRate(double value) => value.clamp(0.5, 2.0).toDouble();

/// Turns a reply that is still streaming into speakable pieces, cut at line
/// and sentence ends so that no text is spoken twice.
final class SpeechStream {
  static final _sentenceEnd = RegExp(r'(?<!\d)[.!?](?=\s)');
  static final _tableRule = RegExp(r'^[\s|:\-]+$');

  int _consumed = 0;
  bool _inFence = false;

  /// [text] is the whole reply so far. Returns the pieces that became
  /// speakable since the last call.
  List<String> feed(String text, {bool done = false}) {
    if (text.length < _consumed) return const [];
    final out = <String>[];
    var cut = _cutPoint(text.substring(_consumed), done: done);
    while (cut > 0) {
      out.addAll(_speakable(text.substring(_consumed, _consumed + cut)));
      _consumed += cut;
      cut = _cutPoint(text.substring(_consumed), done: done);
    }
    return out;
  }

  static int _cutPoint(String rest, {required bool done}) {
    if (rest.isEmpty) return 0;
    if (done) return rest.length;
    var cut = rest.lastIndexOf('\n') + 1;
    for (final match in _sentenceEnd.allMatches(rest)) {
      if (match.end > cut && _balanced(rest.substring(0, match.end))) {
        cut = match.end;
      }
    }
    return cut;
  }

  static bool _balanced(String s) =>
      _count(s, '[') == _count(s, ']') && _count(s, '(') == _count(s, ')');

  static int _count(String s, String ch) => s.split(ch).length - 1;

  List<String> _speakable(String chunk) {
    final out = <String>[];
    for (final raw in chunk.split('\n')) {
      final line = raw.trim();
      if (line.startsWith('```')) {
        if (!_inFence) out.add('Code block.');
        _inFence = !_inFence;
        continue;
      }
      if (_inFence || line.isEmpty) continue;
      final spoken = _speakableLine(line);
      out.addAll(
        spoken.split(RegExp(r'(?<=[.!?])\s+')).where((p) => p.isNotEmpty),
      );
    }
    return out;
  }

  static String _speakableLine(String line) {
    if (_tableRule.hasMatch(line) && line.contains('-')) return '';
    var s = line;
    if (s.startsWith('|') || s.endsWith('|')) {
      final cells = s
          .split('|')
          .map((c) => c.trim())
          .where((c) => c.isNotEmpty)
          .join(', ');
      s = cells.isEmpty ? '' : '$cells.';
    }
    return s
        .replaceFirst(RegExp(r'^#{1,6}\s+'), '')
        .replaceFirst(RegExp(r'^>\s?'), '')
        .replaceFirst(RegExp(r'^([-*+]|\d+[.)])\s+'), '')
        .replaceAllMapped(
          RegExp(r'!\[([^\]]*)\]\([^)]*\)'),
          (m) => m[1]!,
        )
        .replaceAllMapped(RegExp(r'\[([^\]]*)\]\([^)]*\)'), (m) => m[1]!)
        .replaceAllMapped(RegExp(r'`([^`]*)`'), (m) => m[1]!)
        .replaceAll(RegExp(r'[*~]+'), '')
        .replaceAll(RegExp(r'(?<!\w)_+|_+(?!\w)'), '')
        .trim();
  }
}

import 'dart:async';

import '../tools/agent_tool.dart';
import '../ui/confirm_controller.dart';
import 'voice_controller.dart';

/// The spoken words that answer a tool confirmation.
class VoiceWords {
  const VoiceWords({required this.allow, required this.deny});

  static const defaults = VoiceWords(
    allow: {
      'allow',
      'yes',
      'ok',
      'okay',
      'go ahead',
      'do it',
      'ya',
      'boleh',
      'sure',
      'approve',
      'yep',
      'yeah',
    },
    deny: {
      'deny',
      'no',
      'cancel',
      'stop',
      'tidak',
      'jangan',
      'reject',
      'dont',
      'nope',
      'never',
    },
  );

  final Set<String> allow;
  final Set<String> deny;

  /// The decision the words give, or null when the answer is unclear. Deny wins over allow.
  ConfirmDecision? decide(String? heard) {
    if (heard == null) return null;
    final text = ' ${_normalise(heard)} ';
    if (text.trim().isEmpty) return null;
    if (deny.any((w) => text.contains(' ${_normalise(w)} '))) {
      return ConfirmDecision.deny;
    }
    if (allow.any((w) => text.contains(' ${_normalise(w)} '))) {
      return ConfirmDecision.allowOnce;
    }
    return null;
  }

  static String _normalise(String s) => s
      .toLowerCase()
      .replaceAll("'", '')
      .replaceAll(RegExp(r'[^a-z0-9 ]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}

/// Asks the person aloud while voice mode is on, and always shows the confirm sheet.
///
/// The sheet stays the source of truth: a tap answers it and stops the spoken question. A voice
/// answer is only ever allow once. A request that waits behind another one is shown on the sheet
/// only, since the spoken question is asked for the request at the head of the queue.
class VoiceAwareConfirmer implements Confirmer {
  VoiceAwareConfirmer({
    required this.sheet,
    required this.voice,
    this.words = VoiceWords.defaults,
  });

  final ConfirmController sheet;
  final VoiceController voice;
  final VoiceWords words;

  static const _attempts = 2;

  @override
  Future<ConfirmDecision> ask(ConfirmRequest request) {
    final answer = sheet.ask(request);
    if (!identical(sheet.pending, request)) return answer;
    if (voice.voiceMode) unawaited(_askAloud(request));
    unawaited(answer.then((_) => voice.cancelListen()));
    return answer;
  }

  Future<void> _askAloud(ConfirmRequest request) async {
    for (var attempt = 0; attempt < _attempts; attempt++) {
      if (!_open(request)) return;
      final question = attempt == 0
          ? '${request.summary}. Allow? Say yes or no.'
          : 'Say yes or no.';
      await voice.speakAndWait(question);
      if (!_open(request)) return;
      final decision = words.decide(await voice.listenOnce());
      if (!_open(request)) return;
      if (decision != null) {
        _answer(request, decision);
        return;
      }
    }
    _answer(request, ConfirmDecision.deny);
  }

  bool _open(ConfirmRequest request) =>
      voice.voiceMode && identical(sheet.pending, request);

  void _answer(ConfirmRequest request, ConfirmDecision decision) {
    if (identical(sheet.pending, request)) sheet.resolve(decision);
  }
}

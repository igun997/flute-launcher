import 'dart:async';

import 'package:flutter/foundation.dart';

import '../tools/agent_tool.dart';

/// Asks the person before a write runs.
///
/// Requests are answered in the order they arrive. The head of the queue is [pending] and the
/// confirm sheet shows it. A tool the person allowed for this chat is not asked about again;
/// queued requests for that tool are answered as soon as the allowance is given.
class ConfirmController extends ChangeNotifier implements Confirmer {
  final List<_Waiting> _queue = [];
  final Set<String> _allowedForChat = {};

  /// The request the sheet should show now, or null when nothing waits for an answer.
  ConfirmRequest? get pending => _queue.isEmpty ? null : _queue.first.request;

  @override
  Future<ConfirmDecision> ask(ConfirmRequest request) {
    if (_allowedForChat.contains(request.tool.name)) {
      return Future.value(ConfirmDecision.allowForSession);
    }
    final waiting = _Waiting(request);
    _queue.add(waiting);
    if (_queue.length == 1) notifyListeners();
    return waiting.completer.future;
  }

  /// Answers [pending]. Does nothing when no request waits.
  void resolve(ConfirmDecision decision) {
    if (_queue.isEmpty) return;
    final answered = _queue.removeAt(0);
    if (decision == ConfirmDecision.allowForSession) {
      _allowedForChat.add(answered.request.tool.name);
    }
    answered.completer.complete(decision);
    _answerAllowedQueued();
    notifyListeners();
  }

  /// Forgets the allowances given for this chat. Called on a new chat.
  void reset() => _allowedForChat.clear();

  void _answerAllowedQueued() {
    var i = 0;
    while (i < _queue.length) {
      final waiting = _queue[i];
      if (_allowedForChat.contains(waiting.request.tool.name)) {
        _queue.removeAt(i);
        waiting.completer.complete(ConfirmDecision.allowForSession);
      } else {
        i++;
      }
    }
  }

  @override
  void dispose() {
    for (final waiting in _queue) {
      waiting.completer.complete(ConfirmDecision.deny);
    }
    _queue.clear();
    super.dispose();
  }
}

class _Waiting {
  _Waiting(this.request);
  final ConfirmRequest request;
  final Completer<ConfirmDecision> completer = Completer<ConfirmDecision>();
}

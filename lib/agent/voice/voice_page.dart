import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/theme.dart';
import '../runtime/agent_runtime.dart';
import 'voice_controller.dart';
import 'voice_orb.dart';

/// Full-screen voice conversation. The orb listens, the agent answers, and the reply is read aloud.
/// With hands-free on, listening resumes after each reply.
class VoicePage extends StatefulWidget {
  const VoicePage({super.key, required this.agent, required this.voice});

  final AgentRuntime agent;
  final VoiceController voice;

  @override
  State<VoicePage> createState() => _VoicePageState();
}

/// Turns a markdown reply into plain text for the on-screen caption. Code fences, table rules and
/// markup are dropped; the words stay. Lines are joined with spaces.
String plainReplyText(String markdown) {
  final lines = <String>[];
  var inFence = false;
  for (final raw in markdown.split('\n')) {
    final line = raw.trim();
    if (line.startsWith('```') || line.startsWith('~~~')) {
      inFence = !inFence;
      continue;
    }
    if (inFence) continue;
    if (_tableRule.hasMatch(line)) continue;
    lines.add(
      line
          .replaceFirst(_heading, '')
          .replaceFirst(_quote, '')
          .replaceFirst(_listMarker, '')
          .replaceAll('|', ' '),
    );
  }
  return lines
      .join(' ')
      .replaceAllMapped(_image, (m) => m[1] ?? '')
      .replaceAllMapped(_link, (m) => m[1] ?? '')
      .replaceAllMapped(_code, (m) => m[1] ?? '')
      .replaceAllMapped(_boldStar, (m) => m[1] ?? '')
      .replaceAllMapped(_boldUnderscore, (m) => m[1] ?? '')
      .replaceAllMapped(_italicStar, (m) => m[1] ?? '')
      .replaceAllMapped(_italicUnderscore, (m) => m[1] ?? '')
      .replaceAll(_stray, '')
      .replaceAll(_spaces, ' ')
      .trim();
}

final _tableRule = RegExp(r'^\|?\s*:?-{3,}:?\s*(\|\s*:?-{3,}:?\s*)*\|?$');
final _heading = RegExp(r'^#{1,6}\s+');
final _quote = RegExp(r'^>\s?');
final _listMarker = RegExp(r'^([-*+]|\d+\.)\s+');
final _image = RegExp(r'!\[([^\]]*)\]\([^)]*\)');
final _link = RegExp(r'\[([^\]]+)\]\([^)]*\)');
final _code = RegExp(r'`([^`]*)`');
final _boldStar = RegExp(r'\*\*(.+?)\*\*');
final _boldUnderscore = RegExp(r'__(.+?)__');
final _italicStar = RegExp(r'\*(.+?)\*');
final _italicUnderscore = RegExp(r'(?<![A-Za-z0-9])_(.+?)_(?![A-Za-z0-9])');
final _stray = RegExp(r'[*`]');
final _spaces = RegExp(r'\s+');

Duration _dur(BuildContext context, int ms) =>
    MediaQuery.disableAnimationsOf(context) ? Duration.zero : Duration(milliseconds: ms);

class _VoicePageState extends State<VoicePage> {
  /// Ids of rows that existed before the current turn. Only a newer assistant row is read aloud.
  final Set<String> _seen = {};
  bool _wasBusy = false;
  bool _turning = false;

  AgentRuntime get _agent => widget.agent;
  VoiceController get _voice => widget.voice;

  bool get _canListen =>
      mounted && !_turning && !_agent.busy && _voice.state == VoiceState.idle && _voice.error == null;

  @override
  void initState() {
    super.initState();
    _seen.addAll(_agent.items.map((item) => item.id));
    _wasBusy = _agent.busy;
    _agent.addListener(_onAgent);
    _voice.addListener(_onVoice);
    _voice.setVoiceMode(true);
    _voice.setThinking(_wasBusy);
    Future<void>.microtask(() {
      if (mounted) unawaited(_listen());
    });
  }

  @override
  void dispose() {
    _agent.removeListener(_onAgent);
    _voice.removeListener(_onVoice);
    _voice.setVoiceMode(false);
    super.dispose();
  }

  void _onAgent() {
    if (!mounted) return;
    final busy = _agent.busy;
    if (busy && !_wasBusy) _voice.setThinking(true);
    final fresh = _freshReply();
    if (fresh != null) _voice.readReply(fresh.id, fresh.text, done: !fresh.streaming);
    if (!busy && _wasBusy) _voice.setThinking(false);
    _wasBusy = busy;
    if (!busy) {
      _seen.addAll(_agent.items.map((item) => item.id));
      _maybeListen();
    }
  }

  void _onVoice() {
    if (!mounted) return;
    _maybeListen();
  }

  void _maybeListen() {
    if (_voice.handsFree) unawaited(_listen());
  }

  /// The newest assistant row, when it arrived during the current turn.
  AssistantItem? _freshReply() {
    for (final item in _agent.items.reversed) {
      if (item is AssistantItem) return _seen.contains(item.id) ? null : item;
    }
    return null;
  }

  /// The newest assistant reply as plain text, shown on screen whether or not it is fresh.
  String? _lastReplyText() {
    for (final item in _agent.items.reversed) {
      if (item is AssistantItem) {
        final text = plainReplyText(item.text);
        return text.isEmpty ? null : text;
      }
    }
    return null;
  }

  Future<void> _listen() async {
    if (!_canListen) return;
    _turning = true;
    final heard = (await _voice.listenOnce())?.trim() ?? '';
    _turning = false;
    if (!mounted) return;
    if (heard.isEmpty) {
      _maybeListen();
      return;
    }
    unawaited(_agent.send(heard));
  }

  void _onOrbTap() {
    HapticFeedback.lightImpact();
    if (_voice.listening) {
      unawaited(_voice.finishListen());
      return;
    }
    if (_agent.busy) {
      unawaited(_voice.stop());
      _agent.cancel();
      return;
    }
    if (_voice.error != null) _voice.clearError();
    unawaited(_voice.stop());
    unawaited(_listen());
  }

  String _status() {
    return switch (_voice.state) {
      VoiceState.idle => _voice.handsFree ? 'Hands-free is on. Speak anytime.' : 'Tap the orb to talk.',
      VoiceState.listening => 'Listening… tap to send',
      VoiceState.thinking => 'Thinking… tap to cancel',
      VoiceState.speaking => 'Speaking… tap to interrupt',
    };
  }

  String? _errorText() {
    final error = _voice.error;
    if (error == null) return null;
    if (error == 'permission') return 'Microphone permission is needed. Tap the orb to allow it.';
    return 'Voice input stopped. Tap the orb to try again.';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: FluteColors.bg,
      appBar: AppBar(
        backgroundColor: FluteColors.bg,
        elevation: 0,
        title: const Text('Voice'),
        actions: [
          IconButton(
            icon: const Icon(Icons.close),
            tooltip: 'Close',
            onPressed: () => Navigator.of(context).maybePop(),
          ),
        ],
      ),
      body: SafeArea(
        child: ListenableBuilder(
          listenable: Listenable.merge([_agent, _voice]),
          builder: (context, _) => _body(context),
        ),
      ),
    );
  }

  Widget _body(BuildContext context) {
    final status = _status();
    final reply = _lastReplyText();
    final error = _errorText();
    final partial = _voice.partial;
    final listening = _voice.state == VoiceState.listening;
    final motion = _dur(context, 260);
    return Column(
      children: [
        Expanded(
          child: Center(
            child: VoiceOrb(voice: _voice, onTap: _onOrbTap, label: status),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AnimatedSwitcher(
                duration: _dur(context, 220),
                child: Text(
                  status,
                  key: ValueKey(status),
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: FluteColors.muted, fontSize: 14),
                ),
              ),
              AnimatedSize(
                duration: motion,
                curve: Curves.easeOutCubic,
                alignment: Alignment.topCenter,
                child: partial.isEmpty
                    ? const SizedBox.shrink()
                    : Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: Text(
                          partial,
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: FluteColors.text, fontSize: 18),
                        ),
                      ),
              ),
              AnimatedSize(
                duration: motion,
                curve: Curves.easeOutCubic,
                alignment: Alignment.topCenter,
                child: reply == null
                    ? const SizedBox.shrink()
                    : Padding(
                        padding: const EdgeInsets.only(top: 16),
                        child: AnimatedOpacity(
                          opacity: listening ? 0 : 1,
                          duration: _dur(context, 220),
                          child: AnimatedSwitcher(
                            duration: _dur(context, 220),
                            child: Text(
                              reply,
                              key: ValueKey(reply),
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.center,
                              style: const TextStyle(color: FluteColors.softText, fontSize: 15),
                            ),
                          ),
                        ),
                      ),
              ),
              AnimatedSize(
                duration: motion,
                curve: Curves.easeOutCubic,
                alignment: Alignment.topCenter,
                child: error == null
                    ? const SizedBox.shrink()
                    : Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: Text(
                          error,
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: FluteColors.warn, fontSize: 14),
                        ),
                      ),
              ),
            ],
          ),
        ),
        SwitchListTile(
          title: const Text('Hands-free', style: TextStyle(color: FluteColors.text)),
          value: _voice.handsFree,
          onChanged: _voice.setHandsFree,
        ),
        const SizedBox(height: 16),
      ],
    );
  }
}

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/theme.dart';
import '../../home/press_scale.dart';
import '../runtime/agent_runtime.dart';
import '../ui/chat_bubbles.dart';
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

  /// The newest user line in the conversation, kept on screen until the next one arrives.
  String? _lastUserText() {
    for (final item in _agent.items.reversed) {
      if (item is UserItem) {
        final text = item.text.trim();
        return text.isEmpty ? null : text;
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: FluteColors.bg,
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
    final error = _errorText();
    final state = _voice.state;
    final listening = state == VoiceState.listening;
    final partial = _voice.partial;
    // While listening, the live words are the user's line; the reply returns once the turn ends.
    final userLine = partial.isNotEmpty ? partial : (listening ? null : _lastUserText());
    final replyLine = listening ? null : _lastReplyText();
    final duration = motion(context, 260);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(FluteSpace.lg, FluteSpace.sm, FluteSpace.sm, 0),
          child: Row(
            children: [
              Text('Voice', style: FluteText.overline),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.close_rounded),
                tooltip: 'Close',
                onPressed: () => Navigator.of(context).maybePop(),
              ),
            ],
          ),
        ),
        Expanded(
          flex: 5,
          child: Center(
            child: VoiceOrb(voice: _voice, onTap: _onOrbTap, label: status),
          ),
        ),
        AnimatedSwitcher(
          duration: motion(context, 220),
          child: Text(
            status,
            key: ValueKey(status),
            textAlign: TextAlign.center,
            style: FluteText.overline,
          ),
        ),
        const SizedBox(height: FluteSpace.lg),
        Expanded(
          flex: 4,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: FluteSpace.xl),
            child: Align(
              alignment: Alignment.topCenter,
              child: _Transcript(user: userLine, reply: replyLine, duration: duration),
            ),
          ),
        ),
        AnimatedSize(
          duration: duration,
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: error == null
              ? const SizedBox(width: double.infinity)
              : Padding(
                  padding: const EdgeInsets.fromLTRB(FluteSpace.xl, 0, FluteSpace.xl, FluteSpace.md),
                  child: Text(
                    error,
                    textAlign: TextAlign.center,
                    style: FluteText.label.copyWith(fontWeight: FontWeight.w400, color: FluteColors.warn),
                  ),
                ),
        ),
        Expanded(
          flex: 3,
          child: Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: const EdgeInsets.only(bottom: FluteSpace.xl),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _TalkButton(
                    listening: listening,
                    stop: state != VoiceState.idle,
                    label: _buttonLabel(state),
                    onTap: _onOrbTap,
                  ),
                  const SizedBox(width: FluteSpace.lg),
                  _HandsFreeChip(on: _voice.handsFree, onTap: _toggleHandsFree),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  void _toggleHandsFree() {
    HapticFeedback.selectionClick();
    _voice.setHandsFree(!_voice.handsFree);
  }

  String _buttonLabel(VoiceState state) => switch (state) {
        VoiceState.idle => 'Start listening',
        VoiceState.listening => 'Stop listening',
        VoiceState.thinking => 'Cancel',
        VoiceState.speaking => 'Stop speaking',
      };
}

/// The conversation on screen: what the user is saying (or last said), then the reply. Each line is
/// capped at four lines, fades at the bottom edge, and swaps with a crossfade when it changes.
class _Transcript extends StatelessWidget {
  const _Transcript({required this.user, required this.reply, required this.duration});

  final String? user;
  final String? reply;
  final Duration duration;

  @override
  Widget build(BuildContext context) {
    return ShaderMask(
      blendMode: BlendMode.dstIn,
      shaderCallback: (rect) => const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [FluteColors.text, Colors.transparent],
        stops: [0.8, 1],
      ).createShader(rect),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _Line(text: user, style: FluteText.title, duration: duration),
          SizedBox(height: user == null || reply == null ? 0 : FluteSpace.md),
          _Line(
            text: reply,
            style: FluteText.body.copyWith(color: FluteColors.textSecondary),
            duration: duration,
          ),
        ],
      ),
    );
  }
}

class _Line extends StatelessWidget {
  const _Line({required this.text, required this.style, required this.duration});

  final String? text;
  final TextStyle style;
  final Duration duration;

  @override
  Widget build(BuildContext context) {
    final line = text;
    return AnimatedSwitcher(
      duration: duration,
      switchInCurve: Curves.easeOutCubic,
      child: line == null
          ? const SizedBox(key: ValueKey('empty'), width: double.infinity)
          : Text(
              line,
              key: ValueKey(line),
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: style,
            ),
    );
  }
}

/// The one primary control in the thumb zone. A neutral disc; the accent ring shows only while listening.
class _TalkButton extends StatelessWidget {
  const _TalkButton({required this.listening, required this.stop, required this.label, required this.onTap});

  final bool listening;
  final bool stop;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      child: PressScale(
        borderRadius: FluteRadius.pillAll,
        onTap: onTap,
        child: AnimatedContainer(
          duration: motion(context, 220),
          curve: Curves.easeOutCubic,
          width: 72,
          height: 72,
          decoration: BoxDecoration(
            color: FluteColors.surfaceHigh,
            shape: BoxShape.circle,
            border: Border.all(
              color: listening ? FluteColors.accent : FluteColors.line,
              width: listening ? 2 : 1,
            ),
          ),
          child: Icon(stop ? Icons.stop_rounded : Icons.mic_rounded, size: 30, color: FluteColors.text),
        ),
      ),
    );
  }
}

/// Hands-free as a quiet pill: neutral fill, accent text only while it is on.
class _HandsFreeChip extends StatelessWidget {
  const _HandsFreeChip({required this.on, required this.onTap});

  final bool on;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      toggled: on,
      label: 'Hands-free',
      excludeSemantics: true,
      child: PressScale(
        borderRadius: FluteRadius.pillAll,
        onTap: onTap,
        child: Container(
          height: 48,
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: FluteSpace.xl),
          decoration: BoxDecoration(color: FluteColors.surfaceHigh, borderRadius: FluteRadius.pillAll),
          child: AnimatedDefaultTextStyle(
            duration: motion(context, 220),
            style: FluteText.label.copyWith(color: on ? FluteColors.accent : FluteColors.textSecondary),
            child: const Text('Hands-free'),
          ),
        ),
      ),
    );
  }
}

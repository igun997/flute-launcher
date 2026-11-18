import 'dart:async';

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

  /// The newest assistant text, shown on screen whether or not it is fresh.
  String? _lastReplyText() {
    for (final item in _agent.items.reversed) {
      if (item is AssistantItem) {
        final text = item.text.trim();
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
      VoiceState.listening => 'Listening…',
      VoiceState.thinking => 'Thinking…',
      VoiceState.speaking => 'Speaking. Tap to interrupt.',
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
          builder: (context, _) => _body(),
        ),
      ),
    );
  }

  Widget _body() {
    final reply = _lastReplyText();
    final error = _errorText();
    final partial = _voice.partial;
    return Column(
      children: [
        Expanded(
          child: Center(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _onOrbTap,
              child: VoiceOrb(voice: _voice),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _status(),
                textAlign: TextAlign.center,
                style: const TextStyle(color: FluteColors.muted, fontSize: 14),
              ),
              if (partial.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    partial,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: FluteColors.text, fontSize: 18),
                  ),
                ),
              if (reply != null)
                Padding(
                  padding: const EdgeInsets.only(top: 16),
                  child: Text(
                    reply,
                    maxLines: 6,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: FluteColors.softText, fontSize: 15),
                  ),
                ),
              if (error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    error,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: FluteColors.warn, fontSize: 14),
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

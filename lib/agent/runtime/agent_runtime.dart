import 'dart:async';

import 'package:flutter/foundation.dart';

import '../auth/provider_store.dart';
import '../llm/chat_completions_client.dart';
import '../llm/llm_types.dart';
import '../llm/model_info.dart';
import '../llm/responses_client.dart';
import '../skills/skill_commands.dart';
import '../skills/skill_manager.dart';
import '../tools/agent_tool.dart';
import 'attachment_prep.dart';
import 'system_prompt.dart';

enum AttachmentKind { image, video, file }

class Attachment {
  const Attachment({required this.kind, required this.path, required this.name});
  final AttachmentKind kind;
  final String path;
  final String name;
}

enum ToolState { waiting, running, done, denied, failed }

sealed class ChatItem {
  ChatItem(this.id);
  final String id;
}

class UserItem extends ChatItem {
  UserItem({required String id, required this.text, this.attachments = const []}) : super(id);
  final String text;
  final List<Attachment> attachments;
}

class AssistantItem extends ChatItem {
  AssistantItem({required String id, this.text = '', this.reasoning = '', this.streaming = true, this.error}) : super(id);
  String text;
  String reasoning;
  bool streaming;
  String? error;

  /// When the request was sent, when the first piece of text arrived, and when the turn ended.
  DateTime? startedAt;
  DateTime? firstTokenAt;
  DateTime? endedAt;

  /// Tokens the provider reported for this turn; null when it did not report any.
  int? inputTokens;
  int? outputTokens;

  /// Characters received so far (text and reasoning): the basis of the live estimate.
  int receivedChars = 0;

  /// Rough tokens from characters (about 4 per token), used until the provider reports real usage.
  int get estimatedOutputTokens => (receivedChars / 4).ceil();
  int get shownOutputTokens => outputTokens ?? estimatedOutputTokens;
  bool get tokensEstimated => outputTokens == null;

  /// Time from request to first text (the wait before anything appears).
  Duration? get timeToFirstToken => (startedAt != null && firstTokenAt != null) ? firstTokenAt!.difference(startedAt!) : null;

  /// Total time so far, or for the whole turn once it ended.
  Duration? elapsed(DateTime now) => startedAt == null ? null : (endedAt ?? now).difference(startedAt!);

  /// Output tokens per second while text is flowing (after the first token). Null until measurable.
  double? tokensPerSecond(DateTime now) {
    final first = firstTokenAt;
    if (first == null) return null;
    final seconds = (endedAt ?? now).difference(first).inMicroseconds / 1e6;
    if (seconds < 0.25) return null;
    return shownOutputTokens / seconds;
  }
}

class ToolItem extends ChatItem {
  ToolItem({
    required String id,
    required this.toolName,
    required this.source,
    required this.summary,
    this.makesImages = false,
  }) : super(id);
  final String toolName;
  final bool makesImages;

  /// Picture files the tool produced.
  List<String> images = const [];
  final String source;
  final String summary;
  ToolState state = ToolState.waiting;
  String? output;
}

/// Output of a slash command (`skills add ...`): Markdown, not sent to the model.
class NoticeItem extends ChatItem {
  NoticeItem({required String id, required this.text}) : super(id);
  final String text;
}

/// Creates the wire client for a profile. Overridable for tests.
typedef ClientFactory = LlmClient Function(ProviderProfile profile);

/// One conversation: streams the model, runs tools (asking first), keeps the history.
class AgentRuntime extends ChangeNotifier {
  AgentRuntime({
    required this.providers,
    required this.toolSources,
    required this.skills,
    required this.confirmer,
    ClientFactory? clientFactory,
    AttachmentPrep? prep,
    DateTime Function()? clock,
    this.confirmPersonalReads = true,
    this.maxRounds = 12,
    this.onNewChat,
    this.onRunEnd,
  })  : _clientFactory = clientFactory,
        _prep = prep ?? AttachmentPrep(),
        _clock = clock ?? DateTime.now {
    providers.addListener(notifyListeners);
  }

  final ProviderStore providers;
  final List<ToolSource> toolSources;
  final SkillManager skills;
  final Confirmer confirmer;
  final ClientFactory? _clientFactory;
  final AttachmentPrep _prep;
  final DateTime Function() _clock;

  /// Reading the calendar, contacts or notes asks once per chat, like writing does.
  final bool confirmPersonalReads;

  /// Called when a message has been fully handled (reply done, cancelled or failed), e.g. to shut
  /// the sandbox down so nothing keeps running or billing.
  final Future<void> Function()? onRunEnd;

  /// Called by [newChat], e.g. to forget "allow for this chat" answers.
  final VoidCallback? onNewChat;

  /// Upper bound on model turns for one message, so a looping model cannot run forever.
  final int maxRounds;

  static const _personalSources = {'calendar', 'contacts', 'notes'};

  final List<ChatItem> _items = [];
  final List<ChatMessage> _history = [];
  bool _busy = false;
  bool _cancelled = false;
  int _seq = 0;
  StreamSubscription<LlmEvent>? _sub;
  Completer<void>? _streamDone;

  List<ChatItem> get items => List.unmodifiable(_items);
  bool get busy => _busy;
  ProviderProfile? get profile => providers.active;
  String? get model => profile?.model;

  List<String> get slashHints => const [
        'skills add owner/repo',
        'skills list owner/repo',
        'skills find <query>',
        'skills update',
        'skills remove <name>',
        'npx skills add owner/repo',
      ];

  /// Null when a message can be sent; otherwise what is missing.
  String? get setupProblem {
    final p = profile;
    if (p == null) return 'Add a provider to start.';
    if (p.model == null || p.model!.isEmpty) return 'Choose a model.';
    return null;
  }

  String _id() => 'i${_seq++}';

  void newChat() {
    cancel();
    _items.clear();
    _history.clear();
    onNewChat?.call();
    notifyListeners();
  }

  void cancel() {
    if (!_busy) return;
    _cancelled = true;
    _sub?.cancel();
    final done = _streamDone;
    if (done != null && !done.isCompleted) done.complete();
  }

  Future<void> send(String text, {List<Attachment> attachments = const []}) async {
    final trimmed = text.trim();
    if (_busy || (trimmed.isEmpty && attachments.isEmpty)) return;

    if (attachments.isEmpty && SkillCommands.matches(trimmed)) {
      await _runSlash(trimmed);
      return;
    }

    _items.add(UserItem(id: _id(), text: trimmed, attachments: attachments));
    final problem = setupProblem;
    if (problem != null) {
      _items.add(AssistantItem(id: _id())
        ..streaming = false
        ..error = problem);
      notifyListeners();
      return;
    }

    _busy = true;
    _cancelled = false;
    notifyListeners();
    final mark = _history.length;
    try {
      final parts = await _prep.prepare(trimmed, attachments);
      _history.add(ChatMessage(role: Role.user, parts: parts));
      await _runTurns();
    } on LlmException catch (e) {
      _failLast(e.message);
    } catch (e) {
      // Attachment read failures and anything unexpected: the class name only, never the content.
      _failLast('Something went wrong (${e.runtimeType}).');
      if (_history.length > mark && _history.last.role == Role.user) _history.removeLast();
    } finally {
      _busy = false;
      _sub = null;
      _streamDone = null;
      notifyListeners();
      final end = onRunEnd;
      if (end != null) {
        try {
          await end();
        } catch (_) {
          // Cleanup reports its own failures; it must never break the chat.
        }
      }
    }
  }

  Future<void> _runSlash(String input) async {
    _items.add(UserItem(id: _id(), text: input));
    _busy = true;
    notifyListeners();
    try {
      final out = await SkillCommands(skills).run(input);
      _items.add(NoticeItem(id: _id(), text: out));
    } catch (e) {
      _items.add(NoticeItem(id: _id(), text: 'That command failed (${e.runtimeType}).'));
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  void _failLast(String message) {
    final last = _items.isNotEmpty ? _items.last : null;
    if (last is AssistantItem) {
      last.streaming = false;
      last.error = message;
    } else {
      _items.add(AssistantItem(id: _id())
        ..streaming = false
        ..error = message);
    }
  }

  LlmClient _client(ProviderProfile p) {
    final f = _clientFactory;
    if (f != null) return f(p);
    switch (p.kind) {
      case ProviderKind.openaiCompatible:
        return ChatCompletionsClient(
          baseUrl: p.baseUrl,
          apiKey: () => providers.tokenFor(p.id),
          extraHeaders: p.baseUrl.contains('openrouter.ai')
              ? const {'HTTP-Referer': 'https://github.com/igun997/flute-launcher', 'X-Title': 'Flute'}
              : const {},
        );
      case ProviderKind.chatgptPlan:
        return ResponsesClient(baseUrl: p.baseUrl, accessToken: () => providers.tokenFor(p.id));
    }
  }

  Map<String, AgentTool> _toolMap() {
    final map = <String, AgentTool>{};
    for (final source in toolSources) {
      for (final t in source.tools) {
        map.putIfAbsent(t.name, () => t);
      }
    }
    return map;
  }

  Future<void> _runTurns() async {
    final p = providers.active!;
    final client = _client(p);
    try {
      for (var round = 0; round < maxRounds; round++) {
        final tools = _toolMap();
        final assistant = AssistantItem(id: _id())..startedAt = _clock();
        _items.add(assistant);
        notifyListeners();

        final request = LlmRequest(
          model: p.model!,
          messages: List.of(_history),
          tools: [for (final t in tools.values) t.toSpec()],
          instructions: buildInstructions(now: _clock(), skillCatalogue: skills.catalogue()),
        );

        final finished = await _consume(client.stream(request), assistant);
        assistant.streaming = false;
        assistant.endedAt = _clock();
        final usage = finished?.usage;
        assistant.inputTokens = usage?.inputTokens;
        assistant.outputTokens = usage?.outputTokens;
        if (_cancelled) {
          notifyListeners();
          return;
        }
        final calls = finished?.toolCalls ?? const <ToolCall>[];
        _history.add(ChatMessage(
          role: Role.assistant,
          parts: assistant.text.isEmpty ? const [] : [TextPart(assistant.text)],
          toolCalls: calls,
        ));
        if (assistant.text.isEmpty && assistant.reasoning.isEmpty) {
          // A turn that only asked for tools shows just the tool cards; an empty one is an error.
          if (calls.isEmpty) {
            assistant.error = 'The model sent an empty reply.';
          } else {
            _items.remove(assistant);
          }
        }
        notifyListeners();
        if (calls.isEmpty) return;

        for (final call in calls) {
          if (_cancelled) {
            _history.add(ChatMessage.toolResult(call.id, 'Cancelled by the user.', error: true));
            continue;
          }
          _history.add(await _runCall(call, tools));
        }
        if (_cancelled) return;
      }
      _items.add(AssistantItem(id: _id())
        ..streaming = false
        ..error = 'Stopped after $maxRounds steps. Ask again to continue.');
    } finally {
      client.close();
    }
  }

  /// Reads one model turn into [assistant]. Returns the finish event, or null when cancelled.
  Future<LlmFinished?> _consume(Stream<LlmEvent> stream, AssistantItem assistant) {
    final result = Completer<LlmFinished?>();
    _streamDone = Completer<void>();
    LlmFinished? finished;
    _sub = stream.listen(
      (e) {
        switch (e) {
          case TextDelta():
            assistant.text += e.text;
            assistant.receivedChars += e.text.length;
            assistant.firstTokenAt ??= _clock();
          case ReasoningDelta():
            assistant.reasoning += e.text;
            assistant.receivedChars += e.text.length;
            assistant.firstTokenAt ??= _clock();
          case LlmFinished():
            finished = e;
        }
        notifyListeners();
      },
      onError: (Object err, StackTrace st) {
        if (!result.isCompleted) result.completeError(err, st);
      },
      onDone: () {
        if (!result.isCompleted) result.complete(finished);
      },
      cancelOnError: true,
    );
    _streamDone!.future.then((_) {
      if (!result.isCompleted) result.complete(null);
    });
    return result.future;
  }

  Future<ChatMessage> _runCall(ToolCall call, Map<String, AgentTool> tools) async {
    final tool = tools[call.name];
    if (tool == null) {
      final item = ToolItem(id: _id(), toolName: call.name, source: '', summary: call.name)
        ..state = ToolState.failed
        ..output = 'Unknown tool';
      _items.add(item);
      notifyListeners();
      return ChatMessage.toolResult(call.id, 'Unknown tool "${call.name}".', error: true);
    }

    final item = ToolItem(
      id: _id(),
      toolName: tool.name,
      source: tool.source,
      summary: tool.describeCall(call.arguments),
      makesImages: tool.makesImages,
    );
    _items.add(item);
    notifyListeners();

    final needsAsk = tool.risk == ToolRisk.write ||
        (confirmPersonalReads && _personalSources.contains(tool.source));
    if (needsAsk) {
      final decision = await confirmer.ask(ConfirmRequest(tool: tool, summary: item.summary, arguments: call.arguments));
      if (decision == ConfirmDecision.deny) {
        item.state = ToolState.denied;
        notifyListeners();
        return ChatMessage.toolResult(
          call.id,
          'The user declined this action. Do not retry it; ask what they want instead.',
          error: true,
        );
      }
    }

    item.state = ToolState.running;
    notifyListeners();
    ToolResult result;
    try {
      result = await tool.run(call.arguments);
    } catch (e) {
      result = ToolResult.error('The tool failed (${e.runtimeType}).');
    }
    item.state = result.isError ? ToolState.failed : ToolState.done;
    item.images = result.images;
    item.output = result.text.length > 4000 ? '${result.text.substring(0, 4000)}...' : result.text;
    notifyListeners();
    final forModel = result.text.length > 12000 ? '${result.text.substring(0, 12000)}...(truncated)' : result.text;
    return ChatMessage.toolResult(call.id, forModel, error: result.isError);
  }

  @override
  void dispose() {
    providers.removeListener(notifyListeners);
    _sub?.cancel();
    super.dispose();
  }
}

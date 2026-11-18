import 'dart:async';

import '../auth/provider_store.dart';
import '../llm/chat_completions_client.dart';
import '../llm/llm_types.dart';
import '../llm/model_info.dart';
import '../llm/responses_client.dart';
import '../runtime/agent_runtime.dart';
import '../skills/skill_manager.dart';
import '../tools/agent_tool.dart';
import 'routine.dart';
import 'routine_native.dart';
import 'routine_store.dart';

/// Speaks one sentence aloud. The owner wires it to the voice output; null means no speech.
typedef RoutineSpeaker = Future<void> Function(String sentence);

/// The write policy of an unattended run. Reads are always allowed. Writes are denied unless the
/// routine allows them; even then sandbox code and anything that deletes or removes is denied,
/// because nobody is there to look before it runs.
class RoutineRunPolicy implements Confirmer {
  const RoutineRunPolicy({required this.allowWrites});

  final bool allowWrites;

  static bool allows(AgentTool tool, {required bool allowWrites}) {
    if (tool.risk == ToolRisk.read) return true;
    if (!allowWrites) return false;
    if (tool.source == 'sandbox') return false;
    if (isDeletion(tool.name)) return false;
    return true;
  }

  static bool isDeletion(String toolName) {
    final name = toolName.toLowerCase();
    return name.contains('delete') || name.contains('remove') || name.contains('destroy') || name.contains('drop');
  }

  @override
  Future<ConfirmDecision> ask(ConfirmRequest request) async =>
      allows(request.tool, allowWrites: allowWrites) ? ConfirmDecision.allowOnce : ConfirmDecision.deny;
}

/// Runs routines on their own: each run gets its own [AgentRuntime] (never the visible chat),
/// posts a notification with the answer, and records the run in the history.
///
/// Fires from the native scheduler are handled one at a time, in order. [start] listens to fire
/// events and drains the fires queued while the app was not running.
class RoutineRunner {
  RoutineRunner({
    required this.providers,
    required this.toolSources,
    required this.skills,
    required this.store,
    required this.native,
    DateTime Function()? clock,
    this.budget = const Duration(minutes: 3),
    this.clientFactory,
    this.speak,
    this.onRunEnd,
  }) : _clock = clock ?? DateTime.now;

  final ProviderStore providers;

  /// The tools a routine may use. Do not include the routine tools themselves.
  final List<ToolSource> toolSources;
  final SkillManager skills;
  final RoutineStore store;
  final RoutineNative native;

  /// Longest a single run may take. The run is cancelled and reported as timed out after this.
  final Duration budget;

  /// Test seam: builds the wire client. Null uses the same clients as the chat.
  final ClientFactory? clientFactory;
  final RoutineSpeaker? speak;

  /// Called when a run ends, e.g. to shut a sandbox down so nothing keeps running.
  final Future<void> Function()? onRunEnd;
  final DateTime Function() _clock;

  final StreamController<RoutineRun> _opened = StreamController<RoutineRun>.broadcast();

  /// Runs a notification tap asked to open. The owner shows the full result.
  Stream<RoutineRun> get opened => _opened.stream;

  final Set<String> _seenTokens = {};
  StreamSubscription<RoutineNativeEvent>? _subscription;
  Future<void> _queue = Future<void>.value();
  bool _started = false;
  int _sequence = 0;

  /// Listens to native fires and runs the ones queued while the app was closed. Safe to call twice.
  Future<void> start() async {
    if (_started) return;
    _started = true;
    _subscription = native.events.listen((event) {
      final fire = event.fire;
      if (fire != null) {
        _enqueue(fire);
        return;
      }
      final runId = event.openedRunId;
      if (runId != null) _openRun(runId);
    });
    await store.syncSchedules();
    for (final fire in await native.pendingFires()) {
      _enqueue(fire);
    }
    final opened = await native.takeOpenedRunId();
    if (opened != null) _openRun(opened);
  }

  Future<void> dispose() async {
    await _subscription?.cancel();
    await _opened.close();
  }

  /// Runs [routine] now (no schedule involved). Waits for the answer, records it and, when
  /// [notify] is true, posts the notification. Never throws: failures come back as a run.
  Future<RoutineRun> run(Routine routine, {bool notify = true}) =>
      _run(routine, startedAt: _clock(), manual: true, notify: notify);

  void _enqueue(RoutineFire fire) {
    if (!_seenTokens.add(fire.token)) return;
    // Taken: native may forget it. A run cut short by the app closing is not retried.
    unawaited(native.ackFire(fire.token));
    _queue = _queue.then((_) => _handleFire(fire));
  }

  Future<void> _handleFire(RoutineFire fire) async {
    try {
      final routine = store.byId(fire.routineId);
      if (routine == null) return;
      if (!routine.enabled && !fire.manual) {
        final skipped = RoutineRun(
          id: _newId(),
          routineId: routine.id,
          startedAt: fire.firedAt,
          endedAt: _clock(),
          ok: false,
          skipped: true,
          error: 'Skipped: the routine is paused.',
        );
        await store.recordRun(skipped);
        return;
      }
      await _run(routine, startedAt: fire.firedAt, manual: fire.manual, notify: true);
    } catch (_) {
      // One bad fire must not stop the queue; the finally below still releases the wake lock.
    } finally {
      await native.finishFire(fire.token);
    }
  }

  void _openRun(String runId) {
    final run = store.runById(runId);
    if (run != null && !_opened.isClosed) _opened.add(run);
  }

  Future<RoutineRun> _run(
    Routine routine, {
    required DateTime startedAt,
    required bool manual,
    required bool notify,
  }) async {
    final problem = _setupProblem(routine);
    if (problem != null) {
      return _finish(
        routine,
        startedAt: startedAt,
        endedAt: _clock(),
        ok: false,
        skipped: true,
        error: problem,
        result: '',
        manual: manual,
        notify: notify,
      );
    }

    final runtime = AgentRuntime(
      providers: providers,
      toolSources: toolSources,
      skills: skills,
      confirmer: RoutineRunPolicy(allowWrites: routine.allowWrites),
      clientFactory: _clientFactoryFor(routine),
      clock: _clock,
      // Nobody is watching: reads never ask, writes are decided by the policy above.
      confirmPersonalReads: false,
      onRunEnd: onRunEnd,
    );

    var timedOut = false;
    String? crash;
    try {
      final sending = runtime.send(_promptFor(routine));
      try {
        await sending.timeout(budget);
      } on TimeoutException {
        timedOut = true;
        runtime.cancel();
        try {
          await sending.timeout(const Duration(seconds: 10));
        } catch (_) {
          // Cancelled: whatever arrived so far is kept below.
        }
      }
    } catch (e) {
      crash = 'Something went wrong (${e.runtimeType}).';
    }

    final endedAt = _clock();
    final assistants = runtime.items.whereType<AssistantItem>().toList();
    runtime.dispose();

    final answers = [
      for (final item in assistants)
        if (item.text.trim().isNotEmpty) item.text.trim(),
    ];
    final answer = answers.isEmpty ? '' : answers.last;
    final modelError = assistants.map((a) => a.error).whereType<String>().lastOrNull;
    final error = crash ??
        (timedOut
            ? 'Timed out after ${_durationText(budget)}. The run was cancelled.'
            : modelError ?? (answer.isEmpty ? 'The routine gave no answer.' : null));

    int? inputTokens;
    int? outputTokens;
    var estimated = false;
    DateTime? firstToken;
    DateTime? lastEnd;
    for (final item in assistants) {
      final input = item.inputTokens;
      if (input != null) inputTokens = (inputTokens ?? 0) + input;
      if (item.outputTokens != null || item.receivedChars > 0) {
        outputTokens = (outputTokens ?? 0) + item.shownOutputTokens;
        if (item.tokensEstimated) estimated = true;
      }
      firstToken ??= item.firstTokenAt;
      if (item.endedAt != null) lastEnd = item.endedAt;
    }
    double? tokensPerSecond;
    if (outputTokens != null && firstToken != null && lastEnd != null) {
      final seconds = lastEnd.difference(firstToken).inMicroseconds / 1e6;
      if (seconds >= 0.25) tokensPerSecond = outputTokens / seconds;
    }

    return _finish(
      routine,
      startedAt: startedAt,
      endedAt: endedAt,
      ok: error == null,
      skipped: false,
      error: error,
      result: answer,
      inputTokens: inputTokens,
      outputTokens: outputTokens,
      tokensPerSecond: tokensPerSecond,
      tokensEstimated: estimated,
      manual: manual,
      notify: notify,
    );
  }

  Future<RoutineRun> _finish(
    Routine routine, {
    required DateTime startedAt,
    required DateTime endedAt,
    required bool ok,
    required bool skipped,
    required String? error,
    required String result,
    int? inputTokens,
    int? outputTokens,
    double? tokensPerSecond,
    bool tokensEstimated = false,
    required bool manual,
    required bool notify,
  }) async {
    final run = RoutineRun(
      id: _newId(),
      routineId: routine.id,
      startedAt: startedAt,
      endedAt: endedAt,
      ok: ok,
      skipped: skipped,
      error: error,
      result: RoutineRun.trimResult(result),
      inputTokens: inputTokens,
      outputTokens: outputTokens,
      tokensPerSecond: tokensPerSecond,
      tokensEstimated: tokensEstimated,
      manual: manual,
    );
    await store.recordRun(run);
    final paused = await store.pauseIfFailing(routine.id);
    if (notify) await _notify(routine, run, paused: paused);
    if (run.ok) await _speakSummary(routine, run);
    return run;
  }

  Future<void> _notify(Routine routine, RoutineRun run, {required bool paused}) async {
    final title = run.ok
        ? routine.name
        : '${routine.name}: ${run.skipped ? 'skipped' : 'failed'}';
    var text = run.ok ? _head(run.result.isEmpty ? 'Done.' : run.result, 400) : (run.error ?? 'Failed.');
    if (paused) text = '$text\nPaused after two failed runs. Turn it on again in Routines.';
    try {
      await native.notify(
        routineId: routine.id,
        runId: run.id,
        title: title,
        text: text,
        ok: run.ok,
      );
    } catch (_) {
      // Notifications are best effort: the run is already in the history.
    }
  }

  Future<void> _speakSummary(Routine routine, RoutineRun run) async {
    final speaker = speak;
    if (!routine.speak || speaker == null || run.result.isEmpty) return;
    try {
      if (!await native.isScreenOn()) return;
      await speaker(_firstSentence(run.result));
    } catch (_) {
      // Speech is an extra: a failure must not affect the run.
    }
  }

  String? _setupProblem(Routine routine) {
    final profile = providers.active;
    if (profile == null) return 'Skipped: add a provider to run routines.';
    // The runtime refuses to send without a chat model, even when the routine overrides it.
    if ((profile.model ?? '').isEmpty) {
      return 'Skipped: choose a model to run routines.';
    }
    return null;
  }

  String _promptFor(Routine routine) {
    final rules = routine.allowWrites ? '' : ' This run is read-only: do not change anything.';
    return 'This runs unattended on a schedule as the routine "${routine.name}". '
        'Nobody can answer questions, so do the task and reply with the result in a few short sentences.'
        '$rules\n\n${routine.prompt}';
  }

  ClientFactory? _clientFactoryFor(Routine routine) {
    final override = routine.modelOverride;
    final factory = clientFactory;
    if (factory != null) return factory;
    if (override == null || override.isEmpty) return null;
    return (profile) => _ModelOverrideClient(_defaultClient(profile), override);
  }

  /// The same wire clients the chat uses, for a routine that picks its own model.
  LlmClient _defaultClient(ProviderProfile profile) {
    switch (profile.kind) {
      case ProviderKind.openaiCompatible:
        return ChatCompletionsClient(
          baseUrl: profile.baseUrl,
          apiKey: () => providers.tokenFor(profile.id),
          extraHeaders: profile.baseUrl.contains('openrouter.ai')
              ? const {'HTTP-Referer': 'https://github.com/igun997/flute-launcher', 'X-Title': 'Flute'}
              : const {},
        );
      case ProviderKind.chatgptPlan:
        return ResponsesClient(baseUrl: profile.baseUrl, accessToken: () => providers.tokenFor(profile.id));
    }
  }

  String _newId() => 'r${_clock().microsecondsSinceEpoch}-${_sequence++}';
}

/// Sends the same request with another model name.
class _ModelOverrideClient implements LlmClient {
  _ModelOverrideClient(this._inner, this._model);

  final LlmClient _inner;
  final String _model;

  @override
  Stream<LlmEvent> stream(LlmRequest request) => _inner.stream(
        LlmRequest(
          model: _model,
          messages: request.messages,
          tools: request.tools,
          instructions: request.instructions,
        ),
      );

  @override
  void close() => _inner.close();
}

String _head(String text, int limit) => text.length <= limit ? text : '${text.substring(0, limit - 1)}…';

String _firstSentence(String text) {
  final line = text.split('\n').firstWhere((l) => l.trim().isNotEmpty, orElse: () => text).trim();
  final match = RegExp(r'^(.+?[.!?])(\s|$)').firstMatch(line);
  return _head(match?.group(1) ?? line, 200);
}

String _durationText(Duration d) => d.inMinutes >= 1
    ? '${d.inMinutes} minutes'
    : '${(d.inMilliseconds / 1000).toStringAsFixed(1)} seconds';

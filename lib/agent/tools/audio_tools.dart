import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../auth/provider_store.dart';
import '../llm/llm_types.dart';
import '../llm/model_catalog.dart';
import '../llm/model_info.dart';
import '../llm/wire_support.dart';
import 'agent_tool.dart';
import 'tool_support.dart';

const _audioExtensions = {'mp3', 'mp4', 'mpeg', 'mpga', 'm4a', 'wav', 'webm', 'ogg', 'flac'};
const _maxAudioBytes = 25 * 1024 * 1024;
const _fallbackTranscribeModel = 'whisper-1';

/// Speech-to-text tools. Only the active OpenAI-compatible provider is used.
class AudioTools implements ToolSource {
  AudioTools({
    required ProviderStore providers,
    required SharedPreferences prefs,
    http.Client? httpClient,
  }) : tools = <AgentTool>[
          AudioTranscribeTool(
            providers: providers,
            prefs: prefs,
            client: httpClient ?? http.Client(),
          ),
        ];

  @override
  final List<AgentTool> tools;

  @override
  Stream<void> get changes => const Stream<void>.empty();
}

/// `audio_transcribe`: the text of a local audio file, through `POST {baseUrl}/audio/transcriptions`.
class AudioTranscribeTool extends BuiltinTool {
  AudioTranscribeTool({
    required ProviderStore providers,
    required SharedPreferences prefs,
    required http.Client client,
  })  : _providers = providers,
        _prefs = prefs,
        _client = client,
        super(subject: 'Audio');

  final ProviderStore _providers;
  final SharedPreferences _prefs;
  final http.Client _client;

  @override
  String get name => 'audio_transcribe';

  @override
  String get description =>
      'Transcribe a local audio file to text. Supported: ${_audioExtensions.join(', ')}; '
      'up to 25 MB. Give the file path on this device.';

  @override
  Map<String, dynamic> get parameters => objectSchema(
        {'path': stringProp('Path to the audio file on this device.')},
        required: const ['path'],
      );

  @override
  ToolRisk get risk => ToolRisk.read;

  @override
  String get source => 'audio';

  @override
  String describeCall(Map<String, dynamic> args) =>
      'Transcribe ${argString(args, 'path') ?? 'an audio file'}';

  @override
  Future<ToolResult> perform(Map<String, dynamic> args) async {
    final path = requireArg(args, 'path');
    final dot = path.lastIndexOf('.');
    final extension = dot < 0 ? '' : path.substring(dot + 1).toLowerCase();
    if (!_audioExtensions.contains(extension)) {
      throw ToolError('Unsupported audio type. Use one of: ${_audioExtensions.join(', ')}.');
    }
    final file = File(path);
    if (!await file.exists()) throw ToolError('No audio file at $path.');
    if (await file.length() > _maxAudioBytes) throw const ToolError('Audio file is over 25 MB.');

    final profile = _providers.active;
    if (profile == null || profile.kind != ProviderKind.openaiCompatible) {
      return const ToolResult.error(
        'Transcription needs an OpenAI-compatible provider. Set one up in Agent settings.',
      );
    }

    final token = await _providers.tokenFor(profile.id);
    final host = hostOf(profile.baseUrl);
    final cached = ModelCatalog.loadCache(_prefs, profile.id) ?? const <ModelInfo>[];
    final model = cached
        .map((m) => m.id)
        .firstWhere(
          (id) => id.contains('whisper') || id.contains('transcribe'),
          orElse: () => _fallbackTranscribeModel,
        );

    final request = http.MultipartRequest(
      'POST',
      Uri.parse('${normaliseBaseUrl(profile.baseUrl)}/audio/transcriptions'),
    )
      ..headers['Authorization'] = 'Bearer $token'
      ..fields['model'] = model
      ..files.add(await http.MultipartFile.fromPath('file', path));

    try {
      final streamed = await _client.send(request).timeout(llmConnectTimeout);
      final body = await readBody(streamed, host);
      if (streamed.statusCode != 200) {
        throw httpFailure(
          status: streamed.statusCode,
          body: body,
          host: host,
          secret: token,
          kind: profile.kind,
        );
      }
      final json = decodeObject(body, host);
      final text = json['text'];
      if (text is! String) throw LlmException('Unexpected reply from $host');
      return ToolResult(text.trim());
    } on LlmException catch (e) {
      return ToolResult.error(e.message);
    } catch (e) {
      if (isNetworkError(e)) return ToolResult.error(unreachable(host).message);
      rethrow;
    }
  }
}

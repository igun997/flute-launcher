import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../auth/provider_store.dart';
import '../image/image_models.dart';
import '../image/image_settings.dart';
import '../llm/llm_types.dart';
import '../llm/model_catalog.dart';
import '../llm/model_info.dart';
import '../llm/wire_support.dart';
import 'agent_tool.dart';
import 'tool_support.dart';

const _maxPromptChars = 4000;
const _maxDescribeChars = 80;
const _keepImages = 60;
const _requestTimeout = Duration(seconds: 180);

const _sizes = {
  'square': '1024x1024',
  'portrait': '1024x1536',
  'landscape': '1536x1024',
};

/// Picture generation through the active OpenAI-compatible provider
/// (`POST {baseUrl}/images/generations`). Models are found in the provider's own list.
class ImageTools implements ToolSource {
  ImageTools({
    required ProviderStore providers,
    required SharedPreferences prefs,
    required ImageSettings settings,
    http.Client? httpClient,
    Future<Directory> Function()? imageDirectory,
  }) : tools = <AgentTool>[
          ImageGenerateTool(
            providers: providers,
            prefs: prefs,
            settings: settings,
            client: httpClient ?? http.Client(),
            imageDirectory: imageDirectory ?? _defaultDirectory,
          ),
        ];

  @override
  final List<AgentTool> tools;

  @override
  Stream<void> get changes => const Stream<void>.empty();

  static Future<Directory> _defaultDirectory() async {
    final support = await getApplicationSupportDirectory();
    return Directory('${support.path}/images');
  }
}

class ImageGenerateTool extends BuiltinTool {
  ImageGenerateTool({
    required ProviderStore providers,
    required SharedPreferences prefs,
    required ImageSettings settings,
    required http.Client client,
    required Future<Directory> Function() imageDirectory,
  })  : _providers = providers,
        _prefs = prefs,
        _settings = settings,
        _client = client,
        _imageDirectory = imageDirectory,
        super(subject: 'Image');

  final ProviderStore _providers;
  final SharedPreferences _prefs;
  final ImageSettings _settings;
  final http.Client _client;
  final Future<Directory> Function() _imageDirectory;

  @override
  String get name => 'image_generate';

  @override
  String get description =>
      'Create a picture from a text description and show it in the chat. Describe subject, style, '
      'lighting and composition in the prompt. Takes 10 to 60 seconds. One picture per call.';

  @override
  Map<String, dynamic> get parameters => objectSchema(
        {
          'prompt': stringProp('What the picture shows. English works best.'),
          'shape': {
            'type': 'string',
            'enum': _sizes.keys.toList(),
            'description': 'square (default), portrait or landscape.',
          },
        },
        required: const ['prompt'],
      );

  // It spends the provider's credits, so it asks first.
  @override
  ToolRisk get risk => ToolRisk.write;

  @override
  bool get makesImages => true;

  @override
  String get source => 'image';

  @override
  String describeCall(Map<String, dynamic> args) {
    final prompt = (argString(args, 'prompt') ?? '').replaceAll(RegExp(r'\s+'), ' ').trim();
    final shown = prompt.length > _maxDescribeChars ? '${prompt.substring(0, _maxDescribeChars)}...' : prompt;
    return 'Create an image: "$shown"';
  }

  @override
  Future<ToolResult> perform(Map<String, dynamic> args) async {
    final prompt = requireArg(args, 'prompt');
    if (prompt.length > _maxPromptChars) {
      throw const ToolError('The prompt is too long. Keep it under $_maxPromptChars characters.');
    }
    final size = _sizes[argString(args, 'shape')] ?? _sizes['square']!;

    final profile = _providers.active;
    if (profile == null || profile.kind != ProviderKind.openaiCompatible) {
      return const ToolResult.error(
        'Image generation needs an OpenAI-compatible provider such as a gateway or an OpenAI key. Set one up in Agent settings.',
      );
    }
    final catalog = ModelCatalog.loadCache(_prefs, profile.id) ?? const <ModelInfo>[];
    final models = ImageModels.candidates(catalog, preferred: _settings.model);
    if (models.isEmpty) {
      return const ToolResult.error(
        'No image model was found on this provider. Pick a model in Agent settings once the model list has loaded.',
      );
    }

    final token = await _providers.tokenFor(profile.id);
    final host = hostOf(profile.baseUrl);
    final uri = Uri.parse('${normaliseBaseUrl(profile.baseUrl)}/images/generations');
    LlmException? last;
    for (final model in models.take(ImageModels.maxAttempts)) {
      try {
        final bytes = await _request(uri, token, host, model, prompt, size);
        final path = await _save(bytes);
        return ToolResult(
          'Created the picture with $model ($size). It is now shown to the user in the chat. '
          'You cannot see it; do not describe details you cannot know.',
          images: [path],
        );
      } on LlmException catch (e) {
        last = e;
      } catch (e) {
        if (isNetworkError(e)) return ToolResult.error(unreachable(host).message);
        rethrow;
      }
    }
    return ToolResult.error(last?.message ?? 'Image generation failed.');
  }

  Future<Uint8List> _request(
    Uri uri,
    String token,
    String host,
    String model,
    String prompt,
    String size,
  ) async {
    final request = http.Request('POST', uri)
      ..headers['Authorization'] = 'Bearer $token'
      ..headers['Content-Type'] = 'application/json'
      ..body = jsonEncode({'model': model, 'prompt': prompt, 'n': 1, 'size': size});
    final streamed = await _client.send(request).timeout(_requestTimeout);
    final body = await readBody(streamed, host);
    if (streamed.statusCode != 200) {
      throw httpFailure(
        status: streamed.statusCode,
        body: body,
        host: host,
        secret: token,
        kind: ProviderKind.openaiCompatible,
      );
    }
    // Pictures arrive as 1 to 4 MB of base64: decode off the UI isolate.
    final payload = await Isolate.run(() => parseImageResponse(body));
    final bytes = payload.bytes;
    if (bytes != null) return bytes;
    final url = payload.url;
    if (url == null) throw LlmException('$host returned no picture.');
    final downloaded = await _client.get(Uri.parse(url)).timeout(_requestTimeout);
    if (downloaded.statusCode != 200 || downloaded.bodyBytes.isEmpty) {
      throw LlmException('$host returned a picture link that could not be opened.');
    }
    return downloaded.bodyBytes;
  }

  Future<String> _save(Uint8List bytes) async {
    final dir = await _imageDirectory();
    await dir.create(recursive: true);
    final file = File('${dir.path}/img_${DateTime.now().millisecondsSinceEpoch}.${imageExtension(bytes)}');
    await file.writeAsBytes(bytes, flush: true);
    await _prune(dir);
    return file.path;
  }

  Future<void> _prune(Directory dir) async {
    final files = <File>[
      await for (final e in dir.list()) if (e is File) e,
    ];
    if (files.length <= _keepImages) return;
    files.sort((a, b) => a.path.compareTo(b.path));
    for (final old in files.take(files.length - _keepImages)) {
      try {
        await old.delete();
      } on FileSystemException {
        // Already gone.
      }
    }
  }
}

/// The picture in an OpenAI images reply: inline base64, or a link to download.
({Uint8List? bytes, String? url}) parseImageResponse(String body) {
  final Object? json;
  try {
    json = jsonDecode(body);
  } on FormatException {
    return (bytes: null, url: null);
  }
  final data = json is Map ? json['data'] : null;
  final first = data is List && data.isNotEmpty ? data.first : null;
  if (first is! Map) return (bytes: null, url: null);
  final b64 = first['b64_json'];
  if (b64 is String && b64.isNotEmpty) {
    try {
      return (bytes: base64Decode(b64), url: null);
    } on FormatException {
      return (bytes: null, url: null);
    }
  }
  final url = first['url'];
  if (url is String && url.startsWith('https://')) return (bytes: null, url: url);
  return (bytes: null, url: null);
}

/// File extension from the first bytes: png, jpg or webp. Falls back to png.
String imageExtension(List<int> bytes) {
  bool at(int i, int v) => bytes.length > i && bytes[i] == v;
  if (at(0, 0xFF) && at(1, 0xD8)) return 'jpg';
  if (at(0, 0x52) && at(1, 0x49) && at(2, 0x46) && at(3, 0x46) && at(8, 0x57) && at(9, 0x45)) return 'webp';
  return 'png';
}

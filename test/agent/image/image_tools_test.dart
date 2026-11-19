import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:focus_launcher/agent/auth/provider_store.dart';
import 'package:focus_launcher/agent/auth/secret_store.dart';
import 'package:focus_launcher/agent/image/image_settings.dart';
import 'package:focus_launcher/agent/llm/model_catalog.dart';
import 'package:focus_launcher/agent/llm/model_info.dart';
import 'package:focus_launcher/agent/tools/image_tools.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

// 1x1 PNG.
const _png =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==';

late SharedPreferences prefs;
late Directory dir;

Future<ImageGenerateTool> _tool(http.Client client, {List<String> models = const ['cx/gpt-6-luna']}) async {
  final secrets = MemorySecretStore();
  final providers = ProviderStore(prefs: prefs, secrets: secrets);
  final profile = await providers.addApiKeyProfile(
    label: 'Gateway',
    baseUrl: 'https://gw.example.com/v1',
    apiKey: 'sk-test',
  );
  await ModelCatalog.saveCache(prefs, profile.id, [for (final id in models) ModelInfo(id: id, name: id)]);
  return ImageTools(
    providers: providers,
    prefs: prefs,
    settings: ImageSettings(prefs),
    httpClient: client,
    imageDirectory: () async => dir,
  ).tools.single as ImageGenerateTool;
}

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    dir = await Directory.systemTemp.createTemp('flute_img');
  });
  tearDown(() => dir.delete(recursive: true));

  test('saves the picture to a file and returns its path without sending bytes to the model', () async {
    late http.Request seen;
    final tool = await _tool(MockClient((request) async {
      seen = request;
      return http.Response(jsonEncode({'data': [{'b64_json': _png}]}), 200);
    }));
    final result = await tool.run({'prompt': 'a duck', 'shape': 'landscape'});

    expect(result.isError, isFalse);
    expect(result.images, hasLength(1));
    expect(result.images.single, endsWith('.png'));
    expect(await File(result.images.single).readAsBytes(), base64Decode(_png));
    expect(result.text, isNot(contains(_png)));
    final body = jsonDecode(seen.body) as Map;
    expect(seen.url.path, '/v1/images/generations');
    expect(body['model'], 'cx/gpt-image-2');
    expect(body['size'], '1536x1024');
    expect(seen.headers['Authorization'], 'Bearer sk-test');
  });

  test('falls back to the next image model when the first is refused', () async {
    final tried = <String>[];
    final tool = await _tool(MockClient((request) async {
      final model = (jsonDecode(request.body) as Map)['model'] as String;
      tried.add(model);
      if (tried.length == 1) {
        return http.Response(jsonEncode({'error': {'message': 'not supported'}}), 400);
      }
      return http.Response(jsonEncode({'data': [{'b64_json': _png}]}), 200);
    }), models: ['cx/gpt-6-luna', 'gemini/gemini-3.6-flash']);
    final result = await tool.run({'prompt': 'a duck'});

    expect(result.isError, isFalse);
    expect(tried, ['cx/gpt-image-2', 'gemini/gemini-3.1-flash-image-preview']);
  });

  test('reports the provider\'s error when every model fails', () async {
    final tool = await _tool(MockClient((_) async => http.Response(
          jsonEncode({'error': {'message': 'No credentials'}}),
          400,
        )));
    final result = await tool.run({'prompt': 'a duck'});
    expect(result.isError, isTrue);
    expect(result.images, isEmpty);
  });

  test('no image model in the provider list is a clear error, not a request', () async {
    var called = false;
    final tool = await _tool(MockClient((_) async {
      called = true;
      return http.Response('', 500);
    }), models: ['gpt-4o']);
    final result = await tool.run({'prompt': 'a duck'});
    expect(result.isError, isTrue);
    expect(called, isFalse);
  });

  test('picture type is read from the bytes', () {
    expect(imageExtension([0xFF, 0xD8, 0xFF]), 'jpg');
    expect(imageExtension(base64Decode(_png)), 'png');
    expect(imageExtension([0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0, 0x57, 0x45, 0x42, 0x50]), 'webp');
  });

  test('a reply that is not a picture yields nothing instead of throwing', () {
    expect(parseImageResponse('not json').bytes, isNull);
    expect(parseImageResponse('{"data":[]}').bytes, isNull);
    expect(parseImageResponse('{"data":[{"url":"http://insecure/x.png"}]}').url, isNull);
    expect(parseImageResponse('{"data":[{"url":"https://ok/x.png"}]}').url, 'https://ok/x.png');
  });
}

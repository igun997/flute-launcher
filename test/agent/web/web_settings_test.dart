import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:focus_launcher/agent/auth/secret_store.dart';
import 'package:focus_launcher/agent/web/web_api.dart';
import 'package:focus_launcher/agent/web/web_settings.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

http.Response _tavilyOk() => http.Response(jsonEncode({'answer': 'ok', 'results': []}), 200);

void main() {
  late SharedPreferences prefs;
  late MemorySecretStore secrets;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    secrets = MemorySecretStore();
  });

  WebSettings settingsWith(http.Response Function(http.Request) respond) {
    return WebSettings(
      prefs: prefs,
      secrets: secrets,
      httpClient: MockClient((request) async => respond(request)),
    );
  }

  test('a key that the service accepts is stored and selects its provider', () async {
    final settings = settingsWith((_) => _tavilyOk());

    await settings.saveKey(WebProvider.tavily, '  tvly-test-key  ');

    expect(settings.hasKey(WebProvider.tavily), isTrue);
    expect(settings.apiKey(WebProvider.tavily), 'tvly-test-key');
    expect(settings.provider, WebProvider.tavily);
    expect(await secrets.read(WebProvider.tavily.secretKey), 'tvly-test-key');
  });

  test('a key the service rejects is not stored', () async {
    final settings = settingsWith((_) => http.Response('{}', 401));

    await expectLater(
      settings.saveKey(WebProvider.tavily, 'bad-key'),
      throwsA(isA<WebApiException>().having((e) => e.message, 'message', 'The API key was not accepted.')),
    );

    expect(settings.hasKey(WebProvider.tavily), isFalse);
    expect(settings.provider, isNull);
    expect(await secrets.read(WebProvider.tavily.secretKey), isNull);
  });

  test('a blank key is refused before any request is sent', () async {
    var requests = 0;
    final settings = settingsWith((_) {
      requests++;
      return _tavilyOk();
    });

    await expectLater(settings.saveKey(WebProvider.firecrawl, '   '), throwsA(isA<FormatException>()));

    expect(requests, 0);
    expect(settings.hasKey(WebProvider.firecrawl), isFalse);
  });

  test('removing the only key leaves no provider', () async {
    final settings = settingsWith((_) => _tavilyOk());
    await settings.saveKey(WebProvider.tavily, 'tvly-test-key');

    await settings.removeKey(WebProvider.tavily);

    expect(settings.hasKey(WebProvider.tavily), isFalse);
    expect(settings.provider, isNull);
    expect(await secrets.read(WebProvider.tavily.secretKey), isNull);
  });

  test('the chosen provider falls back to one that has a key', () async {
    final settings = settingsWith((_) => _tavilyOk());
    await settings.saveKey(WebProvider.tavily, 'tvly-test-key');

    await settings.setProvider(WebProvider.firecrawl);

    expect(settings.provider, WebProvider.tavily);
  });

  test('load restores the saved provider and keys after a restart', () async {
    final first = settingsWith((_) => _tavilyOk());
    await first.saveKey(WebProvider.tavily, 'tvly-test-key');

    final restarted = settingsWith((_) => _tavilyOk());
    await restarted.load();

    expect(restarted.provider, WebProvider.tavily);
    expect(restarted.apiKey(WebProvider.tavily), 'tvly-test-key');
  });
}

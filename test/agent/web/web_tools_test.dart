import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:focus_launcher/agent/auth/secret_store.dart';
import 'package:focus_launcher/agent/web/web_api.dart';
import 'package:focus_launcher/agent/web/web_settings.dart';
import 'package:focus_launcher/agent/web/web_tools.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _searchReply = {
  'answer': 'Flutter 3.50 shipped in May.',
  'results': [
    {'title': 'Flutter release notes', 'url': 'https://docs.flutter.dev/release', 'content': 'Notes for\nthe release.'},
  ],
};

http.Response _ok(Object body) => http.Response(jsonEncode(body), 200);

/// Saves a key through a healthy mock first, then answers later requests with [respond].
Future<WebSettings> _settingsWith(http.Response Function(http.Request) respond) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  var ready = false;
  final settings = WebSettings(
    prefs: prefs,
    secrets: MemorySecretStore(),
    httpClient: MockClient((request) async => ready ? respond(request) : _ok(_searchReply)),
  );
  await settings.saveKey(WebProvider.tavily, 'tvly-test-key');
  ready = true;
  return settings;
}

void main() {
  group('isPublicWebUrl', () {
    test('allows public http and https addresses', () {
      expect(isPublicWebUrl(Uri.parse('https://docs.flutter.dev/page')), isTrue);
      expect(isPublicWebUrl(Uri.parse('http://example.com')), isTrue);
    });

    test('refuses other schemes, localhost names and private literal addresses', () {
      expect(isPublicWebUrl(Uri.parse('file:///etc/passwd')), isFalse);
      expect(isPublicWebUrl(Uri.parse('http://localhost:8080/x')), isFalse);
      expect(isPublicWebUrl(Uri.parse('http://printer.local/')), isFalse);
      expect(isPublicWebUrl(Uri.parse('http://127.0.0.1/')), isFalse);
      expect(isPublicWebUrl(Uri.parse('http://192.168.1.20/')), isFalse);
      expect(isPublicWebUrl(Uri.parse('http://169.254.169.254/latest/meta-data')), isFalse);
      expect(isPublicWebUrl(Uri.parse('http://[::1]/')), isFalse);
    });
  });

  test('search returns the answer and numbered hits with their URLs', () async {
    final settings = await _settingsWith((request) {
      expect(request.url.toString(), 'https://api.tavily.com/search');
      return _ok(_searchReply);
    });

    final result = await WebSearchTool(settings).run({'query': 'flutter 3.50 release'});

    expect(result.isError, isFalse);
    expect(result.text, contains('Flutter 3.50 shipped in May.'));
    expect(result.text, contains('Flutter release notes'));
    expect(result.text, contains('https://docs.flutter.dev/release'));
  });

  test('search without a query is an error and sends nothing', () async {
    var requests = 0;
    final settings = await _settingsWith((_) {
      requests++;
      return _ok(_searchReply);
    });

    final result = await WebSearchTool(settings).run({'query': '  '});

    expect(result.isError, isTrue);
    expect(requests, 0);
  });

  test('search with a bad time range is an error', () async {
    final settings = await _settingsWith((_) => _ok(_searchReply));

    final result = await WebSearchTool(settings).run({'query': 'news', 'time_range': 'decade'});

    expect(result.isError, isTrue);
  });

  test('search without any key says how to add one', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final settings = WebSettings(
      prefs: prefs,
      secrets: MemorySecretStore(),
      httpClient: MockClient((_) async => _ok(_searchReply)),
    );

    final result = await WebSearchTool(settings).run({'query': 'anything'});

    expect(result.isError, isTrue);
    expect(result.text, contains('Agent settings'));
  });

  test('a failed lookup reports a plain message instead of the raw error', () async {
    final settings = await _settingsWith((_) => http.Response('boom', 500));

    final result = await WebSearchTool(settings).run({'query': 'flutter'});

    expect(result.isError, isTrue);
    expect(result.text, contains('HTTP 500'));
  });

  test('fetch returns the page text for a public URL', () async {
    final settings = await _settingsWith((request) {
      expect(request.url.toString(), 'https://api.tavily.com/extract');
      return _ok({
        'results': [
          {'url': 'https://example.com/a', 'raw_content': '# Title\n\nBody text.'},
        ],
      });
    });

    final result = await WebFetchTool(settings).run({'url': 'https://example.com/a'});

    expect(result.isError, isFalse);
    expect(result.text, contains('Body text.'));
  });

  test('fetch refuses a private address without contacting the service', () async {
    var requests = 0;
    final settings = await _settingsWith((_) {
      requests++;
      return _ok(_searchReply);
    });

    final result = await WebFetchTool(settings).run({'url': 'http://10.0.0.5/admin'});

    expect(result.isError, isTrue);
    expect(requests, 0);
  });

  test('WebTools lists no tools without a key and the two tools with one', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final settings = WebSettings(
      prefs: prefs,
      secrets: MemorySecretStore(),
      httpClient: MockClient((_) async => _ok(_searchReply)),
    );
    final tools = WebTools(settings);
    addTearDown(tools.dispose);

    expect(tools.tools, isEmpty);

    final changed = tools.changes.first;
    await settings.saveKey(WebProvider.tavily, 'tvly-test-key');
    await changed;

    expect(tools.tools.map((t) => t.name), containsAll(['web_search', 'web_fetch']));
  });
}

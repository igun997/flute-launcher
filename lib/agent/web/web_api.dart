import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

enum WebProvider {
  tavily('Tavily', 'tavily_key', 'https://app.tavily.com/home'),
  firecrawl('Firecrawl', 'firecrawl_key', 'https://www.firecrawl.dev/app/api-keys');

  const WebProvider(this.label, this.secretKey, this.keyUrl);

  final String label;
  final String secretKey;
  final String keyUrl;
}

class WebApiException implements Exception {
  const WebApiException(this.message);

  final String message;

  @override
  String toString() => message;
}

class WebHit {
  const WebHit({required this.title, required this.url, required this.snippet});

  final String title;
  final String url;
  final String snippet;
}

class WebSearch {
  const WebSearch({this.answer, required this.hits});

  final String? answer;
  final List<WebHit> hits;
}

/// Talks to Tavily and Firecrawl. Keys are passed per call and never stored here.
class WebApi {
  WebApi(this._client);

  final http.Client _client;

  static const _timeout = Duration(seconds: 25);

  /// [timeRange] is one of day, week, month, year, or null for no limit.
  Future<WebSearch> search(
    WebProvider provider,
    String key, {
    required String query,
    int maxResults = 5,
    String? timeRange,
    List<String> includeDomains = const [],
  }) async {
    switch (provider) {
      case WebProvider.tavily:
        final json = await _post(
          Uri.parse('https://api.tavily.com/search'),
          key,
          {
            'query': query,
            'max_results': maxResults,
            'search_depth': 'basic',
            'include_answer': true,
            'time_range': ?timeRange,
            if (includeDomains.isNotEmpty) 'include_domains': includeDomains,
          },
        );
        final answer = _str(json['answer']);
        return WebSearch(
          answer: answer.isEmpty ? null : answer,
          hits: [
            for (final row in _rows(json['results']))
              WebHit(
                title: _str(row['title']),
                url: _str(row['url']),
                snippet: _str(row['content']),
              ),
          ],
        );
      case WebProvider.firecrawl:
        final json = await _post(
          Uri.parse('https://api.firecrawl.dev/v2/search'),
          key,
          {
            'query': query,
            'limit': maxResults,
            'tbs': ?_firecrawlTbs(timeRange),
            if (includeDomains.isNotEmpty) 'includeDomains': includeDomains,
          },
        );
        if (json['success'] == false) {
          throw const WebApiException('The search service failed.');
        }
        final data = json['data'];
        // Newer responses nest results under data.web; older ones return data as the list.
        final rows = data is Map ? _rows(data['web']) : _rows(data);
        return WebSearch(
          hits: [
            for (final row in rows)
              WebHit(
                title: _str(row['title']),
                url: _str(row['url']),
                snippet: _str(row['description']),
              ),
          ],
        );
    }
  }

  /// Returns the page as markdown.
  Future<String> fetch(WebProvider provider, String key, Uri url) async {
    switch (provider) {
      case WebProvider.tavily:
        final json = await _post(
          Uri.parse('https://api.tavily.com/extract'),
          key,
          {
            'urls': [url.toString()],
          },
        );
        final rows = _rows(json['results']);
        final text = rows.isEmpty ? '' : _str(rows.first['raw_content']);
        if (text.isEmpty) {
          throw const WebApiException('The page could not be read.');
        }
        return text;
      case WebProvider.firecrawl:
        final json = await _post(
          Uri.parse('https://api.firecrawl.dev/v2/scrape'),
          key,
          {
            'url': url.toString(),
            'formats': ['markdown'],
            'onlyMainContent': true,
          },
        );
        if (json['success'] == false) {
          throw const WebApiException('The page could not be read.');
        }
        final data = json['data'];
        final text = data is Map ? _str(data['markdown']) : '';
        if (text.isEmpty) {
          throw const WebApiException('The page could not be read.');
        }
        return text;
    }
  }

  void close() => _client.close();

  Future<Map<String, dynamic>> _post(
    Uri uri,
    String key,
    Map<String, dynamic> body,
  ) async {
    final http.Response response;
    try {
      response = await _client
          .post(
            uri,
            headers: {
              'Authorization': 'Bearer $key',
              'Content-Type': 'application/json',
            },
            body: jsonEncode(body),
          )
          .timeout(_timeout);
    } on TimeoutException {
      throw const WebApiException('The search service timed out.');
    }
    if (response.statusCode != 200) {
      throw WebApiException(_statusMessage(response.statusCode));
    }
    try {
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is Map<String, dynamic>) return decoded;
    } on FormatException {
      // Falls through to the shared message below.
    }
    throw const WebApiException('The search service sent an unexpected reply.');
  }

  static String _statusMessage(int code) => switch (code) {
    400 || 422 => 'The search request was rejected.',
    401 || 403 => 'The API key was not accepted.',
    402 => 'The account is out of credits.',
    429 => 'Too many requests. Wait a moment and try again.',
    432 || 433 || 434 => 'The plan or usage limit was reached.',
    _ => 'The search service failed (HTTP $code).',
  };

  static String? _firecrawlTbs(String? timeRange) => switch (timeRange) {
    'day' => 'qdr:d',
    'week' => 'qdr:w',
    'month' => 'qdr:m',
    'year' => 'qdr:y',
    _ => null,
  };

  static List<Map<String, dynamic>> _rows(Object? value) => value is List
      ? value.whereType<Map<String, dynamic>>().toList()
      : const [];

  static String _str(Object? value) => value is String ? value.trim() : '';
}

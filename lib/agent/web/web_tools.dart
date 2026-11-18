import 'dart:async';
import 'dart:io';

import '../tools/agent_tool.dart';
import '../tools/tool_support.dart';
import 'web_api.dart';
import 'web_settings.dart';

const _noKeyMessage =
    'No web search key is set. Add a Tavily or Firecrawl key in Agent settings.';
const _lookupFailed = 'Web lookup failed. Check the connection and try again.';
const _refusedUrl = 'Only public http and https pages can be fetched.';
const _timeRanges = {'day', 'week', 'month', 'year'};

class WebSearchTool extends AgentTool {
  WebSearchTool(this._settings);

  final WebSettings _settings;

  @override
  String get name => 'web_search';

  @override
  String get description =>
      'Search the web. Returns numbered results with titles, URLs and snippets, plus a short answer when the provider gives one.';

  @override
  Map<String, dynamic> get parameters => objectSchema({
    'query': stringProp('What to search for.'),
    'max_results': intProp('How many results to return, 1 to 10. Default 5.'),
    'time_range': stringProp('Only recent pages: day, week, month or year.'),
    'include_domains': stringListProp('Only return results from these domains, e.g. ["github.com"].'),
  }, required: ['query']);

  @override
  ToolRisk get risk => ToolRisk.read;

  @override
  String get source => 'web';

  @override
  String describeCall(Map<String, dynamic> args) =>
      'Search the web for "${argString(args, 'query') ?? ''}"';

  @override
  Future<ToolResult> run(Map<String, dynamic> args) async {
    final query = argString(args, 'query') ?? '';
    if (query.isEmpty) return const ToolResult.error('Give a search query.');
    final provider = _settings.provider;
    final key = provider == null ? null : _settings.apiKey(provider);
    if (provider == null || key == null) return const ToolResult.error(_noKeyMessage);

    final requested = argInt(args, 'max_results') ?? 5;
    final maxResults = requested < 1 ? 1 : (requested > 10 ? 10 : requested);
    final timeRange = argString(args, 'time_range');
    if (timeRange != null && timeRange.isNotEmpty && !_timeRanges.contains(timeRange)) {
      return const ToolResult.error('time_range must be day, week, month or year.');
    }
    final domains = argStrings(args, 'include_domains') ?? const <String>[];

    try {
      final result = await _settings.api.search(
        provider,
        key,
        query: query,
        maxResults: maxResults,
        timeRange: timeRange == null || timeRange.isEmpty ? null : timeRange,
        includeDomains: domains,
      );
      return ToolResult(_format(query, result));
    } on WebApiException catch (e) {
      return ToolResult.error(e.message);
    } on Exception {
      return const ToolResult.error(_lookupFailed);
    }
  }

  static String _format(String query, WebSearch result) {
    if (result.hits.isEmpty && result.answer == null) {
      return 'No results for "$query".';
    }
    final out = StringBuffer();
    final answer = result.answer;
    if (answer != null) out.writeln('Answer: ${clip(_flat(answer), 1000)}\n');
    for (var i = 0; i < result.hits.length; i++) {
      final hit = result.hits[i];
      out
        ..writeln('${i + 1}. ${clip(_flat(hit.title), 200)}')
        ..writeln('   ${hit.url}');
      final snippet = _flat(hit.snippet);
      if (snippet.isNotEmpty) out.writeln('   ${clip(snippet, 300)}');
    }
    return out.toString().trimRight();
  }
}

class WebFetchTool extends AgentTool {
  WebFetchTool(this._settings);

  final WebSettings _settings;

  static const _maxChars = 12000;

  @override
  String get name => 'web_fetch';

  @override
  String get description =>
      'Read one public web page and return its main content as markdown.';

  @override
  Map<String, dynamic> get parameters => objectSchema({
    'url': stringProp('The public http or https page to read.'),
  }, required: ['url']);

  @override
  ToolRisk get risk => ToolRisk.read;

  @override
  String get source => 'web';

  @override
  String describeCall(Map<String, dynamic> args) =>
      'Read the web page ${argString(args, 'url') ?? ''}';

  @override
  Future<ToolResult> run(Map<String, dynamic> args) async {
    final uri = Uri.tryParse(argString(args, 'url') ?? '');
    if (uri == null || !isPublicWebUrl(uri)) return const ToolResult.error(_refusedUrl);
    final provider = _settings.provider;
    final key = provider == null ? null : _settings.apiKey(provider);
    if (provider == null || key == null) return const ToolResult.error(_noKeyMessage);

    try {
      final markdown = await _settings.api.fetch(provider, key, uri);
      return ToolResult(clip(markdown.trim(), _maxChars));
    } on WebApiException catch (e) {
      return ToolResult.error(e.message);
    } on Exception {
      return const ToolResult.error(_lookupFailed);
    }
  }
}

/// Rejects anything that is not an http(s) URL to a public host. Only literal
/// addresses and local names are checked; the provider resolves DNS itself.
bool isPublicWebUrl(Uri uri) {
  if (uri.scheme != 'http' && uri.scheme != 'https') return false;
  final host = uri.host.toLowerCase();
  if (host.isEmpty) return false;
  if (host == 'localhost' || host.endsWith('.localhost') || host.endsWith('.local')) {
    return false;
  }
  final address = InternetAddress.tryParse(host);
  return address == null || !_isPrivate(address);
}

bool _isPrivate(InternetAddress address) {
  if (address.isLoopback || address.isLinkLocal || address.isMulticast) return true;
  final raw = address.rawAddress;
  if (address.type == InternetAddressType.IPv4) {
    final a = raw[0];
    final b = raw[1];
    return a == 0 ||
        a == 10 ||
        a == 127 ||
        (a == 100 && b >= 64 && b <= 127) ||
        (a == 169 && b == 254) ||
        (a == 172 && b >= 16 && b <= 31) ||
        (a == 192 && b == 168);
  }
  if ((raw[0] & 0xfe) == 0xfc) return true; // fc00::/7 unique local
  if (raw.every((byte) => byte == 0)) return true; // ::
  final mapped = raw.sublist(0, 10).every((byte) => byte == 0) && raw[10] == 0xff && raw[11] == 0xff;
  if (mapped) return _isPrivate(InternetAddress.fromRawAddress(raw.sublist(12)));
  return false;
}

String _flat(String text) => text.replaceAll(RegExp(r'\s+'), ' ').trim();

/// Web tools, listed only while a provider key is saved.
class WebTools implements ToolSource {
  WebTools(this._settings)
    : _tools = [WebSearchTool(_settings), WebFetchTool(_settings)] {
    _settings.addListener(_notify);
  }

  final WebSettings _settings;
  final List<AgentTool> _tools;
  final _changes = StreamController<void>.broadcast();

  @override
  List<AgentTool> get tools => _settings.provider == null ? const [] : _tools;

  @override
  Stream<void> get changes => _changes.stream;

  void _notify() => _changes.add(null);

  void dispose() {
    _settings.removeListener(_notify);
    _changes.close();
  }
}

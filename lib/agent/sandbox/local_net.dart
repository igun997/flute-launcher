import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data' show BytesBuilder;

import 'package:http/http.dart' as http;

/// True for addresses on the public internet. Loopback, private, link-local, carrier-grade NAT,
/// multicast and unspecified addresses are refused so sandboxed code cannot reach the phone itself
/// or devices on the home network (a router page, a printer, another app's local server).
bool isPublicAddress(InternetAddress address) {
  final b = address.rawAddress;
  if (address.type == InternetAddressType.IPv4) return _publicV4(b[0], b[1], b[2]);
  if (address.isLoopback || address.isLinkLocal || address.isMulticast) return false;
  if (b.every((v) => v == 0)) return false;
  if ((b[0] & 0xfe) == 0xfc) return false; // unique local fc00::/7
  if (b[0] == 0xfe && (b[1] & 0xc0) == 0x80) return false; // link local fe80::/10
  final mapped = b.sublist(0, 10).every((v) => v == 0) && b[10] == 0xff && b[11] == 0xff;
  if (mapped) return _publicV4(b[12], b[13], b[14]);
  return true;
}

bool _publicV4(int a, int b, int c) {
  if (a == 0 || a == 10 || a == 127 || a >= 224) return false;
  if (a == 169 && b == 254) return false;
  if (a == 172 && b >= 16 && b <= 31) return false;
  if (a == 192 && b == 168) return false;
  if (a == 100 && b >= 64 && b <= 127) return false;
  if (a == 192 && b == 0 && c == 0) return false;
  return true;
}

/// Answers the HTTP requests a local Python run makes. The Rust side relays each request as one
/// JSON line (`m` method, `u` url, `h` headers, `b` base64 body) and expects one JSON line back
/// (`status`, `reason`, `headers`, `body` as base64, or `error`). Errors are answers, never throws:
/// the program sees them as an `OSError`.
class LocalNetBridge {
  LocalNetBridge({
    http.Client? client,
    Future<List<InternetAddress>> Function(String host)? lookup,
    this.timeout = const Duration(seconds: 30),
  })  : _client = client ?? http.Client(),
        _lookup = lookup ?? InternetAddress.lookup;

  static const maxRequestBytes = 2 * 1024 * 1024;
  static const maxResponseBytes = 5 * 1024 * 1024;
  static const _methods = {'GET', 'HEAD', 'POST', 'PUT', 'PATCH', 'DELETE'};
  static const _dropped = {'host', 'content-length', 'transfer-encoding', 'connection'};

  final http.Client _client;
  final Future<List<InternetAddress>> Function(String host) _lookup;
  final Duration timeout;

  Future<String> handle(String requestJson) async {
    try {
      return jsonEncode(await _perform(requestJson));
    } on _Refused catch (e) {
      return jsonEncode({'error': e.message});
    } on TimeoutException {
      return jsonEncode({'error': 'the request timed out'});
    } on http.ClientException {
      return jsonEncode({'error': 'could not reach the server'});
    } on SocketException {
      return jsonEncode({'error': 'could not reach the server'});
    } on HandshakeException {
      return jsonEncode({'error': 'could not make a secure connection'});
    } on FormatException {
      return jsonEncode({'error': 'the request was not understood'});
    }
  }

  Future<Map<String, Object?>> _perform(String requestJson) async {
    final decoded = jsonDecode(requestJson);
    if (decoded is! Map) throw const _Refused('the request was not understood');
    final method = '${decoded['m']}'.toUpperCase();
    if (!_methods.contains(method)) throw _Refused('method $method is not allowed');
    final uri = Uri.tryParse('${decoded['u']}');
    if (uri == null || !(uri.scheme == 'http' || uri.scheme == 'https') || uri.host.isEmpty) {
      throw const _Refused('only http and https addresses can be fetched');
    }
    await _checkHost(uri.host);

    final body = base64Decode('${decoded['b'] ?? ''}');
    if (body.length > maxRequestBytes) throw const _Refused('the request body is larger than 2 MB');
    final headers = <String, String>{};
    final rawHeaders = decoded['h'];
    if (rawHeaders is Map) {
      for (final entry in rawHeaders.entries) {
        final key = '${entry.key}';
        if (_dropped.contains(key.toLowerCase())) continue;
        headers[key] = '${entry.value}';
      }
    }

    // Redirects are answered as they are: the program's own client follows them, and each hop comes
    // back through here to be checked.
    final request = http.Request(method, uri)
      ..followRedirects = false
      ..headers.addAll(headers)
      ..bodyBytes = body;
    final response = await _client.send(request).timeout(timeout);
    final builder = BytesBuilder(copy: false);
    await for (final chunk in response.stream.timeout(timeout)) {
      builder.add(chunk);
      if (builder.length > maxResponseBytes) throw const _Refused('the response is larger than 5 MB');
    }
    return {
      'status': response.statusCode,
      'reason': response.reasonPhrase ?? '',
      'headers': response.headers,
      'body': base64Encode(builder.takeBytes()),
    };
  }

  Future<void> _checkHost(String host) async {
    final literal = InternetAddress.tryParse(host);
    final List<InternetAddress> addresses;
    if (literal != null) {
      addresses = [literal];
    } else {
      try {
        addresses = await _lookup(host).timeout(const Duration(seconds: 10));
      } on SocketException {
        throw _Refused('could not find $host');
      }
    }
    if (addresses.isEmpty || !addresses.every(isPublicAddress)) {
      throw _Refused('$host is not a public internet address, so it is blocked');
    }
  }
}

class _Refused implements Exception {
  const _Refused(this.message);
  final String message;
}

import 'dart:async';
import 'dart:io';

/// A one-shot HTTP listener on 127.0.0.1 for the browser redirect at the end of an OAuth flow.
class LoopbackServer {
  LoopbackServer._(this._server, this._path) {
    _callback.future.ignore();
  }

  final HttpServer _server;
  final String _path;
  final Completer<Map<String, String>> _callback = Completer<Map<String, String>>();
  bool _closed = false;

  /// Binds 127.0.0.1. Port 0 picks any free port.
  static Future<LoopbackServer> start({int port = 0, String path = '/auth/callback'}) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    final loopback = LoopbackServer._(server, path);
    server.listen(loopback._handle);
    return loopback;
  }

  int get port => _server.port;

  Uri redirectUri({String host = '127.0.0.1'}) =>
      Uri(scheme: 'http', host: host, port: port, path: _path);

  /// The query parameters of the first request to the callback path. Throws [TimeoutException]
  /// when none arrives in time, and an error when the listener is closed first.
  Future<Map<String, String>> waitForCallback({Duration timeout = const Duration(minutes: 5)}) =>
      _callback.future.timeout(timeout);

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    if (!_callback.isCompleted) {
      _callback.completeError(StateError('The sign-in listener was closed.'));
    }
    await _server.close(force: true);
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    if (request.uri.path != _path || _callback.isCompleted) {
      response.statusCode = HttpStatus.notFound;
      await _quietClose(response);
      return;
    }
    final query = request.uri.queryParameters;
    final failed = query.containsKey('error');
    response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType.html
      ..headers.set('Cache-Control', 'no-store')
      ..write(_page(failed
          ? 'Sign-in did not finish. You can return to Flute.'
          : 'Signed in. You can return to Flute.'));
    await _quietClose(response);
    // Complete after the page is flushed: closing the server right after must not cut it off.
    if (!_callback.isCompleted) _callback.complete(query);
  }

  static Future<void> _quietClose(HttpResponse response) async {
    try {
      await response.close();
    } catch (_) {
      // The browser hung up; the callback still counts.
    }
  }

  static String _page(String message) =>
      '<!doctype html><html><head><meta name="viewport" content="width=device-width,'
      'initial-scale=1"><title>Flute</title></head><body style="font-family:sans-serif;'
      'background:#0b1220;color:#e5ecf5;display:flex;align-items:center;'
      'justify-content:center;height:100vh;margin:0"><p>$message</p></body></html>';
}

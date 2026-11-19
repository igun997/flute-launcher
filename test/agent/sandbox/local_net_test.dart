import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:focus_launcher/agent/sandbox/local_net.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

String _request(String url, {String method = 'GET', String body = '', Map<String, String> headers = const {}}) =>
    jsonEncode({'m': method, 'u': url, 'h': headers, 'b': base64Encode(utf8.encode(body))});

LocalNetBridge _bridge(
  http.Client client, {
  Map<String, List<String>> dns = const {},
}) =>
    LocalNetBridge(
      client: client,
      lookup: (host) async {
        final found = dns[host];
        if (found == null) throw SocketException('no such host $host');
        return [for (final a in found) InternetAddress(a)];
      },
    );

Map<String, Object?> _decode(String reply) => jsonDecode(reply) as Map<String, Object?>;

void main() {
  group('isPublicAddress', () {
    test('refuses the phone itself and every private range', () {
      for (final a in [
        '127.0.0.1', '10.1.2.3', '172.16.0.1', '172.31.255.255', '192.168.1.1', '169.254.1.1',
        '100.64.0.1', '0.0.0.0', '224.0.0.1', '::1', '::', 'fe80::1', 'fd00::1', '::ffff:192.168.1.5',
      ]) {
        expect(isPublicAddress(InternetAddress(a)), isFalse, reason: a);
      }
    });

    test('allows public addresses, including the edges next to private ranges', () {
      for (final a in ['8.8.8.8', '172.32.0.1', '172.15.0.1', '100.63.0.1', '100.128.0.1', '2606:4700::1111', '::ffff:8.8.8.8']) {
        expect(isPublicAddress(InternetAddress(a)), isTrue, reason: a);
      }
    });
  });

  group('LocalNetBridge', () {
    test('fetches a public page and returns status, headers and the body as base64', () async {
      late http.BaseRequest seen;
      final bridge = _bridge(
        MockClient.streaming((request, _) async {
          seen = request;
          return http.StreamedResponse(
            Stream.value(utf8.encode('hello')),
            200,
            headers: {'content-type': 'text/plain'},
            reasonPhrase: 'OK',
          );
        }),
        dns: {'example.com': ['93.184.216.34']},
      );
      final reply = _decode(await bridge.handle(_request('https://example.com/x?y=1', headers: {'Accept': 'text/plain', 'Host': 'evil'})));

      expect(reply['status'], 200);
      expect(reply['reason'], 'OK');
      expect(utf8.decode(base64Decode(reply['body']! as String)), 'hello');
      expect((reply['headers']! as Map)['content-type'], 'text/plain');
      expect(seen.url.toString(), 'https://example.com/x?y=1');
      expect(seen.headers['Accept'], 'text/plain');
      expect(seen.headers.keys.map((k) => k.toLowerCase()), isNot(contains('host')));
      expect((seen as http.Request).followRedirects, isFalse);
    });

    test('sends a POST body', () async {
      String? sentBody;
      final bridge = _bridge(
        MockClient((request) async {
          sentBody = request.body;
          return http.Response('', 201);
        }),
        dns: {'api.example.com': ['93.184.216.34']},
      );
      final reply = _decode(await bridge.handle(_request('http://api.example.com/p', method: 'POST', body: 'a=1')));
      expect(reply['status'], 201);
      expect(sentBody, 'a=1');
    });

    test('blocks loopback, private and home-network addresses before any request is made', () async {
      var requests = 0;
      final bridge = _bridge(
        MockClient((_) async {
          requests++;
          return http.Response('secret', 200);
        }),
        dns: {'router.lan': ['192.168.1.1'], 'rebind.example': ['93.184.216.34', '10.0.0.5']},
      );
      for (final url in [
        'http://127.0.0.1:8080/', 'http://localhost/', 'http://192.168.1.1/admin',
        'http://[::1]/', 'http://router.lan/', 'http://rebind.example/', 'http://10.0.0.1/',
      ]) {
        final reply = _decode(await bridge.handle(_request(url)));
        expect(reply['error'], isA<String>(), reason: url);
        expect(reply.containsKey('status'), isFalse, reason: url);
      }
      expect(requests, 0);
    });

    test('refuses other schemes and methods, and an unknown host reads as an error answer', () async {
      final bridge = _bridge(MockClient((_) async => http.Response('', 200)));
      expect(_decode(await bridge.handle(_request('file:///etc/passwd')))['error'], isA<String>());
      expect(_decode(await bridge.handle(_request('ftp://example.com/')))['error'], isA<String>());
      expect(_decode(await bridge.handle(_request('http://example.com/', method: 'TRACE')))['error'], isA<String>());
      expect(_decode(await bridge.handle(_request('http://nowhere.invalid/')))['error'], contains('nowhere.invalid'));
      expect(_decode(await bridge.handle('not json'))['error'], isA<String>());
    });

    test('a redirect is returned as it is, so every hop is checked again', () async {
      final bridge = _bridge(
        MockClient((_) async => http.Response('', 302, headers: {'location': 'http://127.0.0.1/'})),
        dns: {'example.com': ['93.184.216.34']},
      );
      final reply = _decode(await bridge.handle(_request('http://example.com/')));
      expect(reply['status'], 302);
      expect((reply['headers']! as Map)['location'], 'http://127.0.0.1/');
      expect(_decode(await bridge.handle(_request('http://127.0.0.1/')))['error'], isA<String>());
    });

    test('a response over 5 MB is refused and a network failure is an error answer', () async {
      final big = _bridge(
        MockClient.streaming((request, _) async => http.StreamedResponse(
              Stream.fromIterable(List.generate(6, (_) => List.filled(1024 * 1024, 65))),
              200,
            )),
        dns: {'big.example': ['93.184.216.34']},
      );
      expect(_decode(await big.handle(_request('http://big.example/')))['error'], contains('5 MB'));

      final down = _bridge(
        MockClient((_) async => throw http.ClientException('connection reset by peer 10.0.0.9')),
        dns: {'down.example': ['93.184.216.34']},
      );
      final reply = _decode(await down.handle(_request('http://down.example/')));
      expect(reply['error'], 'could not reach the server');
    });
  });
}

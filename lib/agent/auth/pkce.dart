import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

/// PKCE (RFC 7636): a random verifier and its S256 challenge.
class Pkce {
  const Pkce({required this.verifier, required this.challenge});

  final String verifier;
  final String challenge;

  /// A fresh verifier (43 characters) and its challenge.
  static Pkce generate() {
    final verifier = randomUrlSafe(32);
    return Pkce(verifier: verifier, challenge: challengeFor(verifier));
  }

  /// `BASE64URL(SHA256(ASCII(verifier)))` without padding.
  static String challengeFor(String verifier) =>
      _base64UrlNoPadding(sha256.convert(ascii.encode(verifier)).bytes);

  /// [bytes] of secure randomness as base64url without padding; also used for `state` and `nonce`.
  static String randomUrlSafe([int bytes = 32]) {
    final random = Random.secure();
    return _base64UrlNoPadding([for (var i = 0; i < bytes; i++) random.nextInt(256)]);
  }

  static String _base64UrlNoPadding(List<int> bytes) =>
      base64Url.encode(bytes).replaceAll('=', '');
}

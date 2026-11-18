import 'package:flutter_test/flutter_test.dart';
import 'package:focus_launcher/agent/auth/pkce.dart';

void main() {
  test('the challenge matches the RFC 7636 appendix B vector', () {
    const verifier = 'dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk';
    expect(Pkce.challengeFor(verifier), 'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM');
  });

  test('generated verifiers are URL-safe, within the length limits, and unique', () {
    final a = Pkce.generate();
    final b = Pkce.generate();
    expect(a.verifier.length, inInclusiveRange(43, 128));
    expect(RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(a.verifier), isTrue);
    expect(a.challenge, Pkce.challengeFor(a.verifier));
    expect(a.verifier, isNot(b.verifier));
    expect(Pkce.randomUrlSafe(16), isNot(Pkce.randomUrlSafe(16)));
  });
}

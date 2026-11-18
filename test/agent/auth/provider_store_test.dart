import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:focus_launcher/agent/auth/chatgpt_oauth.dart';
import 'package:focus_launcher/agent/auth/pkce.dart';
import 'package:focus_launcher/agent/auth/provider_store.dart';
import 'package:focus_launcher/agent/auth/secret_store.dart';
import 'package:focus_launcher/agent/llm/llm_types.dart';
import 'package:focus_launcher/agent/llm/model_info.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'test_support.dart';

late SharedPreferences prefs;
late MemorySecretStore secrets;

/// A store whose network calls fail the test unless a fake is supplied.
ProviderStore _store({http.Client? client, Future<bool> Function(Uri url)? openBrowser}) =>
    ProviderStore(
      prefs: prefs,
      secrets: secrets,
      httpClient: client ?? MockClient((_) async => http.Response('unexpected request', 500)),
      openBrowser: openBrowser ?? ((_) async => true),
    );

ChatGptSession _session({required Duration expiresIn}) => ChatGptSession(
      clientId: 'oaiapp_test',
      subject: 'user-123',
      email: 'user@example.com',
      idToken: 'id.tok.en',
      accessToken: 'access-1',
      refreshToken: 'refresh-1',
      scopes: const [ChatGptOAuth.planScope],
      expiresAt: DateTime.now().toUtc().add(expiresIn),
    );

/// Stores a ChatGPT profile the way a previous sign-in left it.
Future<void> _seedChatGpt(ChatGptSession session) async {
  const profile = ProviderProfile(
    id: 'chat-1',
    label: 'ChatGPT plan',
    kind: ProviderKind.chatgptPlan,
    auth: ProviderAuth.chatgptOAuth,
    baseUrl: 'https://api.openai.com/v1',
  );
  await prefs.setString('agent.profiles', jsonEncode([profile.toJson()]));
  await prefs.setString('agent.active', 'chat-1');
  await secrets.write('agent.chatgpt.chat-1', jsonEncode(session.toJson()));
}

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    secrets = MemorySecretStore();
  });

  test('an API key profile survives a restart and the key never reaches preferences', () async {
    final store = _store();
    final profile = await store.addApiKeyProfile(
      label: '  Home gateway ',
      baseUrl: 'https://gw.example.com/v1/',
      apiKey: '  sk-test-123  ',
    );
    expect(profile.label, 'Home gateway');
    expect(profile.baseUrl, 'https://gw.example.com/v1');

    final restarted = _store();
    await restarted.load();
    expect(restarted.profiles.single.id, profile.id);
    expect(restarted.active?.baseUrl, 'https://gw.example.com/v1');
    expect(await restarted.tokenFor(profile.id), 'sk-test-123');
    expect(prefs.getString('agent.profiles'), isNot(contains('sk-test-123')));
    expect(await secrets.read('agent.key.${profile.id}'), 'sk-test-123');
  });

  test('provider addresses must be https, or http on this device or the local network', () async {
    final store = _store();
    for (final bad in ['http://example.com/v1', 'ftp://gw.example.com', 'https://']) {
      await expectLater(
        store.addApiKeyProfile(label: 'x', baseUrl: bad, apiKey: 'k'),
        throwsA(isA<LlmException>()),
        reason: bad,
      );
    }
    for (final good in [
      'http://localhost:11434/v1',
      'http://192.168.1.20:8080/v1',
      'http://10.0.0.4/v1',
      'http://100.101.2.3:9000/v1',
    ]) {
      await store.addApiKeyProfile(label: 'x', baseUrl: good, apiKey: 'k');
    }
    expect(store.profiles, hasLength(4));
  });

  test('a ChatGPT token well before expiry is used as stored, without a request', () async {
    final fake = FakeOpenAuth();
    await _seedChatGpt(_session(expiresIn: const Duration(minutes: 30)));
    final store = _store(client: fake.client);
    await store.load();

    expect(await store.tokenFor('chat-1'), 'access-1');
    expect(fake.tokenForms, isEmpty);
  });

  test('a token within two minutes of expiry is renewed and the rotated pair replaces the old',
      () async {
    final fake = FakeOpenAuth();
    await _seedChatGpt(_session(expiresIn: const Duration(minutes: 1)));
    final store = _store(client: fake.client);
    await store.load();

    expect(await store.tokenFor('chat-1'), 'access-2');
    expect(fake.tokenForms.single['refresh_token'], 'refresh-1');
    final stored = ChatGptSession.decode(await secrets.read('agent.chatgpt.chat-1'))!;
    expect(stored.accessToken, 'access-2');
    expect(stored.refreshToken, 'refresh-2');
    expect(store.accountLabel('chat-1'), 'user@example.com');
  });

  test('a revoked session clears its tokens and asks for sign-in again', () async {
    final fake = FakeOpenAuth()
      ..onRefresh = (_) => jsonReply({'error': 'invalid_grant'}, status: 400);
    await _seedChatGpt(_session(expiresIn: const Duration(seconds: 30)));
    final store = _store(client: fake.client);
    await store.load();

    await expectLater(
      store.tokenFor('chat-1'),
      throwsA(isA<LlmException>().having((e) => e.isAuth, 'isAuth', isTrue)),
    );
    final kept = ChatGptSession.decode(await secrets.read('agent.chatgpt.chat-1'))!;
    expect(kept.hasTokens, isFalse);
    expect(kept.clientId, 'oaiapp_test');
    expect(kept.email, 'user@example.com');

    await expectLater(
      store.tokenFor('chat-1'),
      throwsA(isA<LlmException>().having((e) => e.statusCode, 'statusCode', 401)),
    );
    expect(fake.tokenForms, hasLength(1));
  });

  test('signing in with OpenRouter stores the returned key on a new profile', () async {
    final fake = FakeOpenAuth();
    final store = _store(client: fake.client, openBrowser: fake.openBrowser);

    final profile = await store.signInWithOpenRouter();

    expect(profile.label, 'OpenRouter');
    expect(profile.baseUrl, 'https://openrouter.ai/api/v1');
    expect(profile.auth, ProviderAuth.openrouterOAuth);
    expect(profile.kind, ProviderKind.openaiCompatible);
    expect(await store.tokenFor(profile.id), 'sk-or-test');
    expect(store.signingIn, isFalse);

    final verifier = fake.openRouterBodies.single['code_verifier'] as String;
    expect(Pkce.challengeFor(verifier), fake.authorizeUrls.single.queryParameters['code_challenge']);
  });

  test('signing in with ChatGPT again reauthorises the same profile and registration', () async {
    final fake = FakeOpenAuth();
    final store = _store(client: fake.client, openBrowser: fake.openBrowser);

    final first = await store.signInWithChatGpt();
    expect(first.baseUrl, 'https://api.openai.com/v1');
    expect(first.kind, ProviderKind.chatgptPlan);
    expect(first.auth, ProviderAuth.chatgptOAuth);
    expect(store.accountLabel(first.id), 'user@example.com');
    final firstUrl = fake.authorizeUrls[0].queryParameters;
    expect(firstUrl['client_id'], 'dynamic_agent_client');
    expect(firstUrl['agent_name_hint'], 'Flute');
    expect(firstUrl['ext_agent_host_id'], startsWith('urn:uuid:'));

    final second = await store.signInWithChatGpt();
    expect(second.id, first.id);
    expect(store.profiles, hasLength(1));
    final again = fake.authorizeUrls[1].queryParameters;
    expect(again['client_id'], 'oaiapp_test');
    expect(again.containsKey('agent_name_hint'), isFalse);
    expect(again['id_token_hint'], isNotNull);
    expect(again['login_hint'], 'user@example.com');
    expect(again['ext_agent_host_id'], firstUrl['ext_agent_host_id']);
  });

  test('signing in with a different ChatGPT account leaves the saved one untouched', () async {
    final fake = FakeOpenAuth();
    final store = _store(client: fake.client, openBrowser: fake.openBrowser);
    final first = await store.signInWithChatGpt();
    final saved = await secrets.read('agent.chatgpt.${first.id}');

    fake.subject = 'someone-else';
    await expectLater(
      store.signInWithChatGpt(),
      throwsA(isA<LlmException>()
          .having((e) => e.message, 'message', contains('not the one saved'))),
    );
    expect(await secrets.read('agent.chatgpt.${first.id}'), saved);
    expect(store.profiles.single.id, first.id);
  });

  test('cancelling a sign-in ends it with a cancel error and leaves nothing behind', () async {
    final store = _store();

    final pending = store.signInWithOpenRouter();
    expect(store.signingIn, isTrue);
    store.cancelSignIn();

    await expectLater(
      pending,
      throwsA(isA<LlmException>()
          .having((e) => e.message, 'message', 'Sign-in was cancelled.')),
    );
    expect(store.signingIn, isFalse);
    expect(store.profiles, isEmpty);
  });

  test('removing a ChatGPT profile revokes its session and deletes its secrets', () async {
    final fake = FakeOpenAuth();
    await _seedChatGpt(_session(expiresIn: const Duration(minutes: 30)));
    final store = _store(client: fake.client);
    await store.load();

    await store.remove('chat-1');

    expect(fake.revokeForms.single['token'], 'refresh-1');
    expect(fake.revokeForms.single['client_id'], 'oaiapp_test');
    expect(await secrets.read('agent.chatgpt.chat-1'), isNull);
    expect(store.profiles, isEmpty);
    expect(store.active, isNull);
    expect(prefs.getString('agent.active'), isNull);
  });
}

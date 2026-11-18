import 'dart:async';
import 'dart:convert';

import 'package:enough_mail/enough_mail.dart'
    show ImapClient, Mailbox, MimeMessage, StatusFlags;
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'email_merge.dart';
import 'email_models.dart';

const _accountsKey = 'email.accounts';
const _refreshInterval = Duration(seconds: 60);
const _accountTimeout = Duration(seconds: 15);
const _probeTimeout = Duration(seconds: 20);
const _previewCount = 10;

/// Headers only. The body is never requested, so message contents are not
/// downloaded and `.PEEK` leaves the \Seen flag untouched.
const _headerCriteria =
    'UID FLAGS BODY.PEEK[HEADER.FIELDS (FROM SUBJECT DATE)]';

final _addressPattern = RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$');

String _secretKey(String accountId) => 'email.$accountId';

/// Multi-account read-only inbox preview. Passwords live only in secure
/// storage; the prefs JSON and all error text are free of credentials.
class EmailService extends ChangeNotifier {
  EmailService._();

  static final EmailService instance = EmailService._();

  final FlutterSecureStorage _secrets = FlutterSecureStorage();

  Future<void>? _loading;
  Future<void>? _refreshing;
  DateTime? _lastRefresh;
  List<EmailAccount> _accounts = const [];
  List<EmailAccountResult> _results = const [];
  EmailSummary _summary = mergeEmailSummary(const []);

  /// Loads accounts from shared_preferences. Safe to call repeatedly; every
  /// other method also awaits it.
  Future<void> init() => _loading ??= _load();

  List<EmailAccount> get accounts => List.unmodifiable(_accounts);

  EmailSummary get summary => _summary;

  /// Verifies the account by connecting and logging in. Returns an error
  /// message for the user, or null when the account was saved.
  Future<String?> addAccount(EmailAccount account, String password) async {
    await init();
    final candidate = EmailAccount(
      id: account.id,
      label: account.label.trim().isEmpty
          ? account.address.trim()
          : account.label.trim(),
      address: account.address.trim(),
      host: account.host.trim(),
      port: account.port,
      ssl: account.ssl,
    );

    final problem = _validate(candidate, password);
    if (problem != null) return problem;

    if (_accounts.any(
      (a) => a.id == candidate.id || _sameInbox(a, candidate),
    )) {
      return 'This inbox is already connected.';
    }

    final failure = await _probe(candidate, password);
    if (failure != null) return failure;

    final next = [..._accounts, candidate];
    try {
      await _secrets.write(key: _secretKey(candidate.id), value: password);
      await _persist(next);
    } on Object {
      await _deleteSecret(candidate.id);
      return 'Could not save the inbox on this device.';
    }

    _accounts = next;
    notifyListeners();
    unawaited(refresh(force: true));
    return null;
  }

  Future<void> removeAccount(String id) async {
    await init();
    if (!_accounts.any((a) => a.id == id)) return;

    final next = [
      for (final a in _accounts)
        if (a.id != id) a,
    ];
    await _persist(next);

    _accounts = next;
    _results = [
      for (final r in _results)
        if (r.accountId != id) r,
    ];
    _summary = mergeEmailSummary(_results);
    notifyListeners();
    await _deleteSecret(id);
  }

  /// Fetches all accounts in parallel. Without [force], does nothing if the
  /// last refresh started less than 60 s ago. Joins a refresh already running.
  Future<void> refresh({bool force = false}) async {
    await init();

    final running = _refreshing;
    if (running != null) return running;

    final now = DateTime.now();
    final last = _lastRefresh;
    if (!force && last != null && now.difference(last) < _refreshInterval) {
      return;
    }

    _lastRefresh = now;
    final run = _runRefresh();
    _refreshing = run;
    return run;
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    _accounts = _decodeAccounts(prefs.getString(_accountsKey));
    notifyListeners();
  }

  Future<void> _persist(List<EmailAccount> accounts) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _accountsKey,
      jsonEncode([for (final a in accounts) a.toJson()]),
    );
  }

  Future<void> _runRefresh() async {
    try {
      final fetched = await Future.wait([
        for (final a in _accounts) _fetch(a),
      ]);
      // Accounts may have been removed while the fetch was running.
      final current = {for (final a in _accounts) a.id};
      _results = [
        for (final r in fetched)
          if (current.contains(r.accountId)) r,
      ];
      _summary = mergeEmailSummary(_results);
    } finally {
      _refreshing = null;
      notifyListeners();
    }
  }

  /// Never throws: every failure becomes an error result for that account.
  Future<EmailAccountResult> _fetch(EmailAccount account) async {
    EmailAccountResult failed(String message) => EmailAccountResult(
      accountId: account.id,
      label: account.label,
      fetchedAt: DateTime.now(),
      error: message,
    );

    try {
      final password = await _secrets.read(key: _secretKey(account.id));
      if (password == null || password.isEmpty) {
        return failed(
          'Saved password is missing. Remove this inbox and add it again.',
        );
      }

      return await _session<EmailAccountResult>(
        account,
        password,
        _accountTimeout,
        (client, inbox) async {
          await client.statusMailbox(inbox, [StatusFlags.unseen]);
          final unread = inbox.messagesUnseen;

          final recent = await client.fetchRecentMessages(
            messageCount: _previewCount,
            criteria: _headerCriteria,
          );
          final previews = [
            for (final m in recent.messages) _preview(account.id, m),
          ];

          return EmailAccountResult(
            accountId: account.id,
            label: account.label,
            fetchedAt: DateTime.now(),
            unread: unread,
            latest: previews,
          );
        },
      );
    } on _EmailFailure catch (failure) {
      return failed(failure.message);
    } on Object {
      return failed('Could not read the saved password.');
    }
  }

  Future<String?> _probe(EmailAccount account, String password) async {
    try {
      await _session<void>(
        account,
        password,
        _probeTimeout,
        (client, inbox) async {},
      );
      return null;
    } on _EmailFailure catch (failure) {
      return failure.message;
    }
  }

  /// Connects, logs in, selects INBOX, runs [body], and always disconnects.
  /// The deadline closes the socket, so a hung server cannot stall the call.
  /// Every failure is rethrown as [_EmailFailure] with a summary that
  /// contains no credentials.
  Future<T> _session<T>(
    EmailAccount account,
    String password,
    Duration timeout,
    Future<T> Function(ImapClient client, Mailbox inbox) body,
  ) async {
    final client = ImapClient(isLogEnabled: false);
    var stage = _Stage.connect;
    var timedOut = false;
    final deadline = Timer(timeout, () {
      timedOut = true;
      unawaited(_closeQuietly(client));
    });

    try {
      await client.connectToServer(
        account.host,
        account.port,
        isSecure: account.ssl,
      );
      stage = _Stage.login;
      await client.login(account.address, password);
      stage = _Stage.open;
      final inbox = await client.selectInbox();
      stage = _Stage.read;
      return await body(client, inbox);
    } catch (_) {
      throw _EmailFailure(
        _stageMessage(stage, account, timedOut: timedOut),
      );
    } finally {
      deadline.cancel();
      await _closeQuietly(client);
    }
  }

  Future<void> _deleteSecret(String accountId) async {
    try {
      await _secrets.delete(key: _secretKey(accountId));
    } on Object {
      // Nothing secret is logged; a stale entry is unreachable without the
      // account record, which has already been removed from prefs.
    }
  }

  static List<EmailAccount> _decodeAccounts(String? raw) {
    if (raw == null || raw.isEmpty) return const [];
    try {
      final items = jsonDecode(raw) as List<dynamic>;
      final accounts = <EmailAccount>[];
      for (final item in items) {
        try {
          accounts.add(EmailAccount.fromJson(item as Map<String, dynamic>));
        } on Object {
          // Skip a corrupt entry rather than losing every account.
        }
      }
      return accounts;
    } on Object {
      return const [];
    }
  }

  static String? _validate(EmailAccount account, String password) {
    if (!_addressPattern.hasMatch(account.address)) {
      return 'Enter a valid email address.';
    }
    if (password.isEmpty) return 'Enter the password.';
    if (account.host.isEmpty) return 'Enter the IMAP host.';
    if (account.port < 1 || account.port > 65535) {
      return 'Enter a valid port.';
    }
    return null;
  }

  static bool _sameInbox(EmailAccount a, EmailAccount b) =>
      a.address.toLowerCase() == b.address.toLowerCase() &&
      a.host.toLowerCase() == b.host.toLowerCase();

  static EmailPreview _preview(String accountId, MimeMessage message) {
    final from = message.from;
    final sender = (from == null || from.isEmpty) ? null : from.first;
    final name = sender?.personalName?.trim();
    final subject = message.decodeSubject()?.trim();
    return EmailPreview(
      accountId: accountId,
      from: (name != null && name.isNotEmpty)
          ? name
          : (sender?.email ?? 'Unknown sender'),
      subject: (subject == null || subject.isEmpty) ? '(no subject)' : subject,
      date: message.decodeDate() ?? emailNeverFetched,
      seen: message.isSeen,
      uid: '${message.uid ?? message.sequenceId ?? ''}',
    );
  }
}

enum _Stage { connect, login, open, read }

class _EmailFailure implements Exception {
  const _EmailFailure(this.message);

  final String message;

  @override
  String toString() => message;
}

String _stageMessage(
  _Stage stage,
  EmailAccount account, {
  required bool timedOut,
}) {
  final server = '${account.host}:${account.port}';
  if (timedOut) return 'Timed out contacting $server. Try again.';
  return switch (stage) {
    _Stage.connect =>
      'Could not connect to $server. Check the host, port and network.',
    _Stage.login =>
      'Sign-in failed. Check the address and password. Lark and Gmail need '
          'their generated password, not your normal one.',
    _Stage.open => 'Signed in, but the INBOX could not be opened.',
    _Stage.read => 'Could not read the inbox.',
  };
}

Future<void> _closeQuietly(ImapClient client) async {
  try {
    await client.disconnect();
  } on Object {
    // Already closed or never opened; there is nothing else to release.
  }
}

/// A configured IMAP inbox. The password is deliberately not part of this
/// model: it lives in flutter_secure_storage under `email.<id>`.
class EmailAccount {
  const EmailAccount({
    required this.id,
    required this.label,
    required this.address,
    required this.host,
    required this.port,
    required this.ssl,
  });

  final String id;
  final String label;
  final String address;
  final String host;
  final int port;
  final bool ssl;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'label': label,
    'address': address,
    'host': host,
    'port': port,
    'ssl': ssl,
  };

  factory EmailAccount.fromJson(Map<String, dynamic> json) => EmailAccount(
    id: json['id'] as String,
    label: json['label'] as String,
    address: json['address'] as String,
    host: json['host'] as String,
    port: (json['port'] as num).toInt(),
    ssl: json['ssl'] as bool? ?? true,
  );
}

/// Header-only view of one message. Bodies are never fetched.
class EmailPreview {
  const EmailPreview({
    required this.accountId,
    required this.from,
    required this.subject,
    required this.date,
    required this.seen,
    required this.uid,
  });

  final String accountId;
  final String from;
  final String subject;
  final DateTime date;
  final bool seen;
  final String uid;
}

/// Merged view across all accounts.
class EmailSummary {
  const EmailSummary({
    required this.unread,
    required this.latest,
    required this.fetchedAt,
    this.error,
  });

  final int unread;
  final List<EmailPreview> latest;
  final DateTime fetchedAt;
  final String? error;
}

/// Connection settings for one provider. [help] is shown to the user before
/// they enter credentials.
class EmailPreset {
  const EmailPreset({
    required this.name,
    required this.host,
    required this.port,
    required this.ssl,
    required this.passwordLabel,
    this.help,
  });

  final String name;
  final String host;
  final int port;
  final bool ssl;
  final String passwordLabel;
  final String? help;

  /// Custom presets have no fixed host; the user supplies it.
  bool get isCustom => host.isEmpty;
}

abstract final class EmailPresets {
  static const lark = EmailPreset(
    name: 'Lark',
    host: 'imap.larksuite.com',
    port: 993,
    ssl: true,
    passwordLabel: 'Generated client password',
    help:
        'Lark Mail needs two steps. First, a Lark admin must allow third-party '
        'email clients for your organisation. Then, in the Lark client, open '
        'Third-party Email Client Sign-in and generate a dedicated password. '
        'Enter that password here, not your Lark login password.',
  );

  static const gmail = EmailPreset(
    name: 'Gmail',
    host: 'imap.gmail.com',
    port: 993,
    ssl: true,
    passwordLabel: 'App password',
    help:
        'Gmail needs an app password. Turn on 2-Step Verification for your '
        'Google account, create an app password, and enter it here instead of '
        'your Google password.',
  );

  static const custom = EmailPreset(
    name: 'Custom',
    host: '',
    port: 993,
    ssl: true,
    passwordLabel: 'Password',
    help:
        "Enter your provider's IMAP server. The connection always uses SSL on "
        'the port you give.',
  );

  static const List<EmailPreset> all = [lark, gmail, custom];
}

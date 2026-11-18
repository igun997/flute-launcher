import 'package:flutter_test/flutter_test.dart';
import 'package:focus_launcher/email/email_models.dart';

void main() {
  group('EmailAccount', () {
    const account = EmailAccount(
      id: '1700000000000',
      label: 'Work',
      address: 'me@example.com',
      host: 'imap.example.com',
      port: 993,
      ssl: true,
    );

    test('toJson writes exactly the non-secret fields', () {
      expect(account.toJson(), {
        'id': '1700000000000',
        'label': 'Work',
        'address': 'me@example.com',
        'host': 'imap.example.com',
        'port': 993,
        'ssl': true,
      });
    });

    test('toJson never contains a password field', () {
      expect(account.toJson().keys, isNot(contains('password')));
    });

    test('round-trips through JSON', () {
      final restored = EmailAccount.fromJson(account.toJson());

      expect(restored.id, account.id);
      expect(restored.label, account.label);
      expect(restored.address, account.address);
      expect(restored.host, account.host);
      expect(restored.port, account.port);
      expect(restored.ssl, account.ssl);
    });

    test('fromJson defaults ssl to true when the key is absent', () {
      final restored = EmailAccount.fromJson({
        'id': 'x',
        'label': 'Old',
        'address': 'old@example.com',
        'host': 'imap.example.com',
        'port': 993,
      });

      expect(restored.ssl, isTrue);
    });

    test('fromJson accepts a port stored as a number of any type', () {
      final restored = EmailAccount.fromJson({
        'id': 'x',
        'label': 'Port',
        'address': 'p@example.com',
        'host': 'imap.example.com',
        'port': 993.0,
        'ssl': false,
      });

      expect(restored.port, 993);
      expect(restored.ssl, isFalse);
    });
  });

  group('EmailPresets', () {
    test('lark uses the Larksuite IMAP host over SSL', () {
      expect(EmailPresets.lark.host, 'imap.larksuite.com');
      expect(EmailPresets.lark.port, 993);
      expect(EmailPresets.lark.ssl, isTrue);
      expect(EmailPresets.lark.isCustom, isFalse);
    });

    test('lark help points to the third-party client setting', () {
      expect(
        EmailPresets.lark.help,
        contains('Third-party Email Client Sign-in'),
      );
    });

    test('gmail uses the Gmail IMAP host over SSL', () {
      expect(EmailPresets.gmail.host, 'imap.gmail.com');
      expect(EmailPresets.gmail.port, 993);
      expect(EmailPresets.gmail.ssl, isTrue);
      expect(EmailPresets.gmail.isCustom, isFalse);
    });

    test('custom has no fixed host and is the only custom preset', () {
      expect(EmailPresets.custom.isCustom, isTrue);
      expect(EmailPresets.custom.ssl, isTrue);
      expect(
        EmailPresets.all.where((p) => p.isCustom),
        [EmailPresets.custom],
      );
    });

    test('all lists the three presets in display order', () {
      expect(EmailPresets.all, [
        EmailPresets.lark,
        EmailPresets.gmail,
        EmailPresets.custom,
      ]);
    });
  });
}

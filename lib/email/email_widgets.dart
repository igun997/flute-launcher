import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'email_models.dart';
import 'email_service.dart';

const _ink = Color(0xFFEDEDEA);
const _mute = Color(0xFF8E9096);
const _faint = Color(0xFF5B5E66);
const _panel = Color(0xFF15161A);
const _line = Color(0xFF2A2C34);
const _alert = Color(0xFFE39A8C);

String _hhmm(DateTime time) {
  final local = time.toLocal();
  final hour = local.hour.toString().padLeft(2, '0');
  final minute = local.minute.toString().padLeft(2, '0');
  return '$hour:$minute';
}

/// Home-screen summary of all connected inboxes. Shows only unread counts
/// and sender/subject lines, never message bodies.
class EmailCard extends StatefulWidget {
  const EmailCard({super.key});

  @override
  State<EmailCard> createState() => _EmailCardState();
}

class _EmailCardState extends State<EmailCard> {
  @override
  void initState() {
    super.initState();
    unawaited(EmailService.instance.refresh());
  }

  void _openSheet() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const EmailAccountsSheet(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final service = EmailService.instance;
    return ListenableBuilder(
      listenable: service,
      builder: (context, _) {
        if (service.accounts.isEmpty) {
          return _CardFrame(
            onTap: _openSheet,
            child: const Text(
              'Connect an inbox',
              style: TextStyle(color: _ink, fontSize: 17),
            ),
          );
        }

        final summary = service.summary;
        final checking = summary.fetchedAt.millisecondsSinceEpoch == 0;
        return _CardFrame(
          onTap: () => unawaited(service.refresh(force: true)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  const Text(
                    'Email',
                    style: TextStyle(color: _mute, fontSize: 13),
                  ),
                  const Spacer(),
                  Text(
                    checking ? 'Checking...' : 'Updated ${_hhmm(summary.fetchedAt)}',
                    style: const TextStyle(color: _faint, fontSize: 12),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                summary.unread == 0 ? 'No unread' : '${summary.unread} unread',
                style: const TextStyle(color: _ink, fontSize: 22),
              ),
              for (final preview in summary.latest.take(3))
                _PreviewLine(preview),
              if (summary.error != null) ...[
                const SizedBox(height: 10),
                Text(
                  summary.error!,
                  style: const TextStyle(color: _alert, fontSize: 13),
                ),
              ],
              const SizedBox(height: 4),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: _openSheet,
                  child: const Text(
                    'Accounts',
                    style: TextStyle(color: _mute, fontSize: 13),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Bottom sheet listing connected inboxes and a form to add one. The form
/// verifies the account against the server before saving it.
class EmailAccountsSheet extends StatefulWidget {
  const EmailAccountsSheet({super.key});

  @override
  State<EmailAccountsSheet> createState() => _EmailAccountsSheetState();
}

class _EmailAccountsSheetState extends State<EmailAccountsSheet> {
  final _address = TextEditingController();
  final _password = TextEditingController();
  final _host = TextEditingController();
  final _port = TextEditingController(text: '993');

  EmailPreset _preset = EmailPresets.lark;
  bool _adding = EmailService.instance.accounts.isEmpty;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _address.dispose();
    _password.dispose();
    _host.dispose();
    _port.dispose();
    super.dispose();
  }

  void _selectPreset(EmailPreset preset) {
    setState(() {
      _preset = preset;
      _error = null;
    });
  }

  void _cancel() {
    if (EmailService.instance.accounts.isEmpty) {
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      _adding = false;
      _error = null;
    });
  }

  Future<void> _submit() async {
    if (_busy) return;
    final preset = _preset;
    final account = EmailAccount(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      label: preset.isCustom ? '' : preset.name,
      address: _address.text,
      host: preset.isCustom ? _host.text : preset.host,
      port: preset.isCustom
          ? (int.tryParse(_port.text.trim()) ?? 0)
          : preset.port,
      ssl: preset.ssl,
    );

    setState(() {
      _busy = true;
      _error = null;
    });
    final error = await EmailService.instance.addAccount(
      account,
      _password.text.trim(),
    );
    if (!mounted) return;

    setState(() {
      _busy = false;
      _error = error;
      if (error == null) {
        _address.clear();
        _password.clear();
        _host.clear();
        _port.text = '993';
        _preset = EmailPresets.lark;
        _adding = false;
      }
    });
  }

  Future<void> _remove(EmailAccount account) async {
    try {
      await EmailService.instance.removeAccount(account.id);
    } on Object {
      if (!mounted) return;
      setState(() => _error = 'Could not remove the inbox. Try again.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final service = EmailService.instance;
    final maxHeight = MediaQuery.sizeOf(context).height * 0.85;

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: Container(
        decoration: const BoxDecoration(
          color: _panel,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: SafeArea(
          top: false,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: maxHeight),
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(24, 24, 24, 24),
              child: ListenableBuilder(
                listenable: service,
                builder: (context, _) {
                  final accounts = service.accounts;
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text(
                        'Email inboxes',
                        style: TextStyle(color: _ink, fontSize: 20),
                      ),
                      const SizedBox(height: 8),
                      for (final account in accounts) _accountRow(account),
                      if (!_adding) ...[
                        const SizedBox(height: 16),
                        TextButton(
                          onPressed: () => setState(() {
                            _adding = true;
                            _error = null;
                          }),
                          child: const Text(
                            'Add inbox',
                            style: TextStyle(color: _ink, fontSize: 15),
                          ),
                        ),
                      ],
                      if (_adding) _addForm(),
                      const SizedBox(height: 8),
                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton(
                          onPressed: () => Navigator.of(context).pop(),
                          child: const Text(
                            'Done',
                            style: TextStyle(color: _mute, fontSize: 14),
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _accountRow(EmailAccount account) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  account.label,
                  style: const TextStyle(color: _ink, fontSize: 16),
                ),
                const SizedBox(height: 2),
                Text(
                  account.address,
                  style: const TextStyle(color: _mute, fontSize: 13),
                ),
                Text(
                  '${account.host}:${account.port}',
                  style: const TextStyle(color: _faint, fontSize: 12),
                ),
              ],
            ),
          ),
          TextButton(
            onPressed: () => unawaited(_remove(account)),
            child: const Text(
              'Remove',
              style: TextStyle(color: _mute, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }

  Widget _addForm() {
    final preset = _preset;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final option in EmailPresets.all)
              ChoiceChip(
                label: Text(option.name),
                selected: option == preset,
                onSelected: (_) => _selectPreset(option),
              ),
          ],
        ),
        if (preset.help != null) ...[
          const SizedBox(height: 12),
          Text(
            preset.help!,
            style: const TextStyle(color: _mute, fontSize: 13, height: 1.4),
          ),
        ],
        const SizedBox(height: 16),
        _field(
          controller: _address,
          label: 'Email address',
          keyboardType: TextInputType.emailAddress,
        ),
        _field(
          controller: _password,
          label: preset.passwordLabel,
          obscure: true,
        ),
        if (preset.isCustom) ...[
          _field(controller: _host, label: 'IMAP host'),
          _field(
            controller: _port,
            label: 'Port',
            keyboardType: TextInputType.number,
          ),
        ],
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(
            _error!,
            style: const TextStyle(color: _alert, fontSize: 13),
          ),
        ],
        const SizedBox(height: 16),
        Row(
          children: [
            TextButton(
              onPressed: _cancel,
              child: const Text(
                'Cancel',
                style: TextStyle(color: _mute, fontSize: 14),
              ),
            ),
            const Spacer(),
            FilledButton(
              onPressed: _busy ? null : () => unawaited(_submit()),
              style: FilledButton.styleFrom(
                backgroundColor: _ink,
                foregroundColor: _panel,
              ),
              child: _busy
                  ? const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                        SizedBox(width: 8),
                        Text('Checking...'),
                      ],
                    )
                  : const Text('Connect'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _field({
    required TextEditingController controller,
    required String label,
    TextInputType? keyboardType,
    bool obscure = false,
  }) {
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: TextField(
        controller: controller,
        keyboardType: keyboardType,
        obscureText: obscure,
        autocorrect: false,
        enableSuggestions: false,
        style: const TextStyle(color: _ink, fontSize: 16),
        cursorColor: _ink,
        decoration: InputDecoration(
          labelText: label,
          labelStyle: const TextStyle(color: _mute, fontSize: 14),
          enabledBorder: const UnderlineInputBorder(
            borderSide: BorderSide(color: _line),
          ),
          focusedBorder: const UnderlineInputBorder(
            borderSide: BorderSide(color: _mute),
          ),
        ),
      ),
    );
  }
}

class _CardFrame extends StatelessWidget {
  const _CardFrame({required this.onTap, required this.child});

  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: _panel,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: _line),
        ),
        child: child,
      ),
    );
  }
}

class _PreviewLine extends StatelessWidget {
  const _PreviewLine(this.preview);

  final EmailPreview preview;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            preview.from,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: _mute, fontSize: 13),
          ),
          Text(
            preview.subject,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: preview.seen ? _mute : _ink,
              fontSize: 15,
            ),
          ),
        ],
      ),
    );
  }
}

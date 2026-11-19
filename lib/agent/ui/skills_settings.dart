import 'package:flutter/services.dart' show HapticFeedback;
import 'package:material_ui/material_ui.dart';

import '../../app/flute.dart';
import '../../app/theme.dart';
import '../skills/skill.dart';
import 'settings_widgets.dart';

/// Installed skills, a finder for `owner/repo` sources, and update checks.
/// Skills are instructions the agent loads; they never run code.
class SkillsSection extends StatefulWidget {
  const SkillsSection({super.key, required this.flute});
  final Flute flute;

  @override
  State<SkillsSection> createState() => _SkillsSectionState();
}

/// Owner keys for the status lines: the control whose action is running or failed.
const _ownerFind = 'find';
const _ownerOffers = 'offers';
const _ownerUpdates = 'updates';
const _ownerRemove = 'remove';

class _SkillsSectionState extends State<SkillsSection> {
  final _source = TextEditingController();
  String? _busy;
  String? _error;
  String? _notice;
  String? _owner;
  List<SkillOffer>? _offers;
  String _offersFrom = '';
  final Set<String> _picked = {};
  List<String>? _updates;

  @override
  void dispose() {
    _source.dispose();
    super.dispose();
  }

  Future<void> _run(String label, String owner, Future<void> Function() action) async {
    setState(() {
      _busy = label;
      _owner = owner;
      _error = null;
      _notice = null;
    });
    try {
      await action();
    } catch (e) {
      if (mounted) setState(() => _error = readableError(e));
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  Future<void> _find() async {
    final source = _source.text.trim();
    if (source.isEmpty) {
      setState(() {
        _owner = _ownerFind;
        _error = 'Type owner/repo or a GitHub link.';
      });
      return;
    }
    await _run('Looking in $source...', _ownerFind, () async {
      final offers = await widget.flute.skills.list(source);
      if (!mounted) return;
      setState(() {
        _offers = offers;
        _offersFrom = source;
        _picked
          ..clear()
          ..addAll(offers.map((o) => o.name));
        if (offers.isEmpty) _notice = 'No skills found in $source.';
      });
    });
  }

  Future<void> _install() => _run('Installing...', _ownerOffers, () async {
        final added = await widget.flute.skills.add(_offersFrom, names: _picked.toList());
        if (!mounted) return;
        HapticFeedback.lightImpact();
        setState(() {
          _offers = null;
          _picked.clear();
          _source.clear();
          _notice = added.isEmpty
              ? 'Nothing was installed.'
              : 'Installed ${added.map((s) => s.name).join(', ')}. The agent can use them from now on.';
        });
      });

  Future<void> _remove(Skill skill) async {
    final sure = await confirmRemove(
      context,
      title: 'Remove ${skill.name}?',
      message: 'The agent stops using this skill. You can add it again later.',
    );
    if (!sure) return;
    await _run('Removing...', _ownerRemove, () => widget.flute.skills.remove(skill.name));
  }

  Future<void> _check() => _run('Checking for updates...', _ownerUpdates, () async {
        final names = await widget.flute.skills.check();
        if (!mounted) return;
        setState(() {
          _updates = names;
          _notice = names.isEmpty
              ? 'All installed skills are up to date.'
              : 'Updates available: ${names.join(', ')}.';
        });
      });

  Future<void> _update(List<String> names) => _run('Updating...', _ownerUpdates, () async {
        final updated = await widget.flute.skills.update(names);
        if (!mounted) return;
        setState(() {
          _updates = null;
          _notice = 'Updated ${updated.length} ${updated.length == 1 ? 'skill' : 'skills'}.';
        });
      });

  @override
  Widget build(BuildContext context) {
    final skills = widget.flute.skills;
    final offers = _offers;
    final updates = _updates;
    final busy = _busy;
    final owner = _owner;
    final working = busy != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: settingsSpaced([
        ListenableBuilder(
          listenable: skills,
          builder: (context, _) {
            final installed = skills.installed;
            return SettingsSection(
              title: 'Installed',
              children: [
                if (installed.isEmpty)
                  Text(
                    'None yet. A skill is a set of instructions the agent loads when it needs them.',
                    style: FluteText.caption,
                  )
                else
                  SettingsGroup(
                    children: [
                      for (final skill in installed)
                        SettingsRow(
                          leading: const SettingsIconTile(icon: Icons.extension_outlined),
                          title: skill.name,
                          subtitle: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                skill.description,
                                style: FluteText.caption,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                              const SizedBox(height: FluteSpace.xs),
                              Text(
                                skill.ref == null ? skill.source : '${skill.source}@${skill.ref}',
                                style: FluteText.caption.copyWith(color: FluteColors.faint),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
                          trailing: IconButton(
                            tooltip: 'Remove ${skill.name}',
                            icon: const Icon(Icons.delete_outline),
                            onPressed: working ? null : () => _remove(skill),
                          ),
                        ),
                    ],
                  ),
                if (busy != null && owner == _ownerRemove) ProgressLine(busy),
                if (_error != null && owner == _ownerRemove) ErrorLine(_error!),
              ],
            );
          },
        ),
        SettingsSection(
          title: 'Add a skill',
          footer: 'You can also type `skills add owner/repo` in the chat.',
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _source,
                    enabled: !working,
                    autocorrect: false,
                    enableSuggestions: false,
                    textInputAction: TextInputAction.search,
                    onSubmitted: (_) => _find(),
                    decoration: const InputDecoration(
                      labelText: 'Skill source',
                      hintText: 'owner/repo or a GitHub link',
                    ),
                  ),
                ),
                const SizedBox(width: FluteSpace.sm),
                OutlinedButton(onPressed: working ? null : _find, child: const Text('Find')),
              ],
            ),
            if (busy != null && owner == _ownerFind) ProgressLine(busy),
            if (_error != null && owner == _ownerFind) ErrorLine(_error!),
            if (offers != null) _offersView(offers, working, busy, owner),
          ],
        ),
        SettingsSection(
          title: 'Updates',
          children: [
            Wrap(
              spacing: FluteSpace.sm,
              runSpacing: FluteSpace.sm,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                TextButton(onPressed: working ? null : _check, child: const Text('Check for updates')),
                if (updates != null && updates.isNotEmpty)
                  OutlinedButton(
                    onPressed: working ? null : () => _update(updates),
                    child: Text('Update ${updates.length}'),
                  ),
              ],
            ),
            if (busy != null && owner == _ownerUpdates) ProgressLine(busy),
            if (_error != null && owner == _ownerUpdates) ErrorLine(_error!),
          ],
        ),
        if (_notice != null)
          Text(_notice!, style: FluteText.caption.copyWith(color: FluteColors.softText)),
      ]),
    );
  }

  /// The skills a source offers, with a checkbox each, and the install and close actions.
  Widget _offersView(List<SkillOffer> offers, bool working, String? busy, String? owner) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (offers.isNotEmpty) ...[
            const SizedBox(height: FluteSpace.xs),
            Text('Found in $_offersFrom', style: FluteText.caption),
            const SizedBox(height: FluteSpace.sm),
            SettingsGroup(
              children: [
                for (final offer in offers)
                  CheckboxListTile(
                    controlAffinity: ListTileControlAffinity.leading,
                    contentPadding: const EdgeInsets.symmetric(horizontal: FluteSpace.lg),
                    value: _picked.contains(offer.name),
                    title: Text(offer.name, style: FluteText.label.copyWith(color: FluteColors.text)),
                    subtitle: Text(
                      offer.description,
                      style: FluteText.caption,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    onChanged: working
                        ? null
                        : (v) {
                            setState(() {
                              if (v == true) {
                                _picked.add(offer.name);
                              } else {
                                _picked.remove(offer.name);
                              }
                            });
                          },
                  ),
              ],
            ),
          ],
          const SizedBox(height: FluteSpace.sm),
          Row(
            children: [
              TextButton(
                onPressed: working ? null : () => setState(() => _offers = null),
                child: const Text('Close'),
              ),
              const Spacer(),
              if (offers.isNotEmpty)
                FilledButton(
                  onPressed: working || _picked.isEmpty ? null : _install,
                  child: Text('Install ${_picked.length}'),
                ),
            ],
          ),
          if (busy != null && owner == _ownerOffers) ProgressLine(busy),
          if (_error != null && owner == _ownerOffers) ErrorLine(_error!),
        ],
      );
}

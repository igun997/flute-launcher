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

class _SkillsSectionState extends State<SkillsSection> {
  final _source = TextEditingController();
  String? _busy;
  String? _error;
  String? _notice;
  List<SkillOffer>? _offers;
  String _offersFrom = '';
  final Set<String> _picked = {};
  List<String>? _updates;

  @override
  void dispose() {
    _source.dispose();
    super.dispose();
  }

  Future<void> _run(String label, Future<void> Function() action) async {
    setState(() {
      _busy = label;
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
      setState(() => _error = 'Type owner/repo or a GitHub link.');
      return;
    }
    await _run('Looking in $source...', () async {
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

  Future<void> _install() => _run('Installing...', () async {
        final added = await widget.flute.skills.add(_offersFrom, names: _picked.toList());
        if (!mounted) return;
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
    final sure = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Remove ${skill.name}?'),
        content: const Text('The agent stops using this skill. You can add it again later.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Remove')),
        ],
      ),
    );
    if (sure != true) return;
    await _run('Removing...', () => widget.flute.skills.remove(skill.name));
  }

  Future<void> _check() => _run('Checking for updates...', () async {
        final names = await widget.flute.skills.check();
        if (!mounted) return;
        setState(() {
          _updates = names;
          _notice = names.isEmpty
              ? 'All installed skills are up to date.'
              : 'Updates available: ${names.join(', ')}.';
        });
      });

  Future<void> _update(List<String> names) => _run('Updating...', () async {
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
    final working = busy != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ListenableBuilder(
          listenable: skills,
          builder: (context, _) {
            final installed = skills.installed;
            if (installed.isEmpty) {
              return const Padding(
                padding: EdgeInsets.only(bottom: 8),
                child: Text(
                  'No skills installed. A skill is a set of instructions the agent loads when it needs them.',
                  style: settingsMuted,
                ),
              );
            }
            return Column(
              children: [
                for (final skill in installed)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(skill.name),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(skill.description, style: settingsMuted, maxLines: 2, overflow: TextOverflow.ellipsis),
                        Text(
                          skill.ref == null ? skill.source : '${skill.source}@${skill.ref}',
                          style: const TextStyle(color: FluteColors.muted, fontSize: 11),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                    trailing: IconButton(
                      tooltip: 'Remove',
                      icon: const Icon(Icons.delete_outline),
                      onPressed: working ? null : () => _remove(skill),
                    ),
                  ),
              ],
            );
          },
        ),
        const SizedBox(height: 12),
        const Text('Add a skill', style: TextStyle(fontSize: 14)),
        const SizedBox(height: 8),
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
                  hintText: 'owner/repo or a GitHub link',
                  isDense: true,
                ),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(onPressed: working ? null : _find, child: const Text('Find')),
          ],
        ),
        if (offers != null) ...[
          const SizedBox(height: 8),
          if (offers.isNotEmpty) ...[
            Text('Found in $_offersFrom', style: settingsMuted),
            for (final offer in offers)
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                dense: true,
                value: _picked.contains(offer.name),
                title: Text(offer.name),
                subtitle: Text(offer.description, style: settingsMuted, maxLines: 2, overflow: TextOverflow.ellipsis),
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
        ],
        const SizedBox(height: 8),
        Row(
          children: [
            TextButton(onPressed: working ? null : _check, child: const Text('Check for updates')),
            if (updates != null && updates.isNotEmpty) ...[
              const SizedBox(width: 8),
              FilledButton(
                onPressed: working ? null : () => _update(updates),
                child: Text('Update ${updates.length}'),
              ),
            ],
          ],
        ),
        if (busy != null) ProgressLine(busy),
        if (_error != null) ErrorLine(_error!),
        if (_notice != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(_notice!, style: const TextStyle(color: FluteColors.accent, fontSize: 13)),
          ),
        const Text(
          'You can also type `skills add owner/repo` in the chat.',
          style: settingsMuted,
        ),
      ],
    );
  }
}

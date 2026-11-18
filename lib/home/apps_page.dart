import 'package:material_ui/material_ui.dart';

import '../app/flute.dart';
import '../app/theme.dart';
import '../core/mode_engine.dart';
import '../core/models.dart';
import '../native/flute_native.dart';
import 'settings_page.dart';

/// Text-only app list grouped by category, with search.
class AppsPage extends StatefulWidget {
  const AppsPage({super.key, required this.flute});
  final Flute flute;

  @override
  State<AppsPage> createState() => _AppsPageState();
}

class _AppsPageState extends State<AppsPage> {
  final _query = TextEditingController();
  final _collapsed = <AppCategory>{};

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  /// Pure so it can be tested: groups [apps] for display.
  /// Hidden apps are left out unless the user is searching.
  static List<(AppCategory, List<FluteApp>)> group(
    List<FluteApp> apps,
    Rule Function(FluteApp) ruleOf,
    String query,
  ) {
    final q = query.trim().toLowerCase();
    final map = <AppCategory, List<FluteApp>>{};
    for (final a in apps) {
      if (q.isEmpty) {
        if (ruleOf(a) == Rule.hide) continue;
      } else if (!a.label.toLowerCase().contains(q)) {
        continue;
      }
      map.putIfAbsent(a.category, () => []).add(a);
    }
    return [
      for (final c in AppCategory.values)
        if (map[c] != null) (c, map[c]!),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final flute = widget.flute;
    return SafeArea(
      child: ListenableBuilder(
        listenable: Listenable.merge([flute.repo, flute.modes, _query]),
        builder: (context, _) {
          final searching = _query.text.trim().isNotEmpty;
          final groups = group(flute.repo.apps, flute.modes.ruleFor, _query.text);
          // Flat rows (a category header, then its apps) so the list builds lazily.
          final rows = <Object>[
            for (final (cat, apps) in groups) ...[
              cat,
              if (searching || !_collapsed.contains(cat)) ...apps,
            ],
          ];
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 8, 12, 0),
                child: Row(
                  children: [
                    const Text('Apps', style: TextStyle(fontSize: 26, fontWeight: FontWeight.w300)),
                    const Spacer(),
                    TextButton(onPressed: () => openSettings(context, flute), child: const Text('Settings')),
                  ],
                ),
              ),
              Expanded(
                child: groups.isEmpty
                    ? Center(
                        child: Text(
                          flute.repo.loading ? 'Loading apps' : 'No apps found',
                          style: const TextStyle(color: FluteColors.muted),
                        ),
                      )
                    : NotificationListener<OverscrollNotification>(
                        // Dragging down past the top of the list returns to the home page.
                        onNotification: (n) {
                          if (n.overscroll < -8 && n.dragDetails != null) Navigator.of(context).maybePop();
                          return false;
                        },
                        child: ListView.builder(
                          padding: const EdgeInsets.fromLTRB(24, 12, 24, 12),
                          physics: const ClampingScrollPhysics(),
                          itemCount: rows.length,
                          itemBuilder: (context, i) {
                            final row = rows[i];
                            if (row is AppCategory) {
                              final apps = groups.firstWhere((g) => g.$1 == row).$2;
                              return _Header(
                                category: row,
                                count: apps.length,
                                collapsed: !searching && _collapsed.contains(row),
                                rule: flute.modes.current.ruleFor(row),
                                onTap: () => setState(() {
                                  _collapsed.contains(row) ? _collapsed.remove(row) : _collapsed.add(row);
                                }),
                              );
                            }
                            final app = row as FluteApp;
                            return _AppRow(
                              app: app,
                              rule: flute.modes.ruleFor(app),
                              onTap: () => FluteNative.launchApp(app.package),
                              onLongPress: () => showAppSheet(context, flute, app),
                            );
                          },
                        ),
                      ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 4, 24, 16),
                child: TextField(
                  controller: _query,
                  textInputAction: TextInputAction.search,
                  decoration: InputDecoration(
                    hintText: 'Search apps',
                    filled: true,
                    fillColor: FluteColors.surface,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none),
                  ),
                  onSubmitted: (_) {
                    if (groups.isNotEmpty) FluteNative.launchApp(groups.first.$2.first.package);
                  },
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.category, required this.count, required this.collapsed, required this.rule, required this.onTap});
  final AppCategory category;
  final int count;
  final bool collapsed;
  final Rule rule;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final note = switch (rule) {
      Rule.show => '',
      Rule.lock => '  ·  paused',
      Rule.hide => '  ·  hidden',
    };
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(0, 18, 0, 6),
        child: Row(
          children: [
            Text(
              '${category.label.toUpperCase()}  $count$note',
              style: TextStyle(
                color: rule == Rule.show ? FluteColors.muted : FluteColors.warn,
                fontSize: 11,
                letterSpacing: 1.2,
              ),
            ),
            const Spacer(),
            Text(collapsed ? 'show' : '', style: const TextStyle(color: FluteColors.muted, fontSize: 11)),
          ],
        ),
      ),
    );
  }
}

class _AppRow extends StatelessWidget {
  const _AppRow({required this.app, required this.rule, required this.onTap, required this.onLongPress});
  final FluteApp app;
  final Rule rule;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 9),
        child: Text(
          app.label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w300,
            color: rule == Rule.show ? FluteColors.text : FluteColors.muted,
          ),
        ),
      ),
    );
  }
}

Future<void> showAppSheet(BuildContext context, Flute flute, FluteApp app) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (context) => ListenableBuilder(
      listenable: Listenable.merge([flute.repo, flute.modes]),
      builder: (context, _) {
        final current = flute.repo.byPackage(app.package) ?? app;
        final fav = flute.repo.isFavorite(app.package);
        final allowed = flute.modes.allowed.contains(app.package);
        final fixed = ModeEngine.defaultAllowed.contains(app.package);
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 20, 24, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(current.label, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w300)),
                const SizedBox(height: 4),
                Text(current.package, style: const TextStyle(color: FluteColors.muted, fontSize: 12)),
                const SizedBox(height: 18),
                const Text('CATEGORY', style: TextStyle(color: FluteColors.muted, fontSize: 11, letterSpacing: 1.2)),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final c in AppCategory.values)
                      ChoiceChip(
                        label: Text(c.label),
                        selected: current.category == c,
                        onSelected: (_) => flute.repo.setCategory(current, c),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Pin to home'),
                  value: fav,
                  onChanged: (_) async {
                    final ok = await flute.repo.toggleFavorite(app.package);
                    if (!ok && context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Home holds up to 8 apps. Unpin one first.')),
                      );
                    }
                  },
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Always allowed'),
                  subtitle: const Text('Ignores mode rules'),
                  value: allowed || fixed,
                  onChanged: fixed ? null : (v) => flute.modes.setAllowed(app.package, v),
                ),
                TextButton(
                  onPressed: () => FluteNative.openAppInfo(app.package),
                  child: const Text('App info'),
                ),
              ],
            ),
          ),
        );
      },
    ),
  );
}

/// Slides the app list up over the home page. Pops with a drag down at the top of the list,
/// the back button or Home.
Future<void> openApps(BuildContext context, Flute flute) {
  return Navigator.of(context).push<void>(
    PageRouteBuilder<void>(
      opaque: true,
      transitionDuration: const Duration(milliseconds: 260),
      reverseTransitionDuration: const Duration(milliseconds: 200),
      pageBuilder: (context, _, _) => Scaffold(
        backgroundColor: FluteColors.bg,
        body: AppsPage(flute: flute),
      ),
      transitionsBuilder: (context, animation, _, child) {
        final curved = CurvedAnimation(parent: animation, curve: Curves.easeOutCubic, reverseCurve: Curves.easeInCubic);
        return FadeTransition(
          opacity: curved,
          child: SlideTransition(
            position: Tween<Offset>(begin: const Offset(0, 0.08), end: Offset.zero).animate(curved),
            child: child,
          ),
        );
      },
    ),
  );
}

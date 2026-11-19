import 'package:material_ui/material_ui.dart';

import '../dev/bench_page.dart';
import '../app/flute.dart';
import '../app/theme.dart';
import '../core/day_style.dart';
import '../core/default_pins.dart';
import '../core/models.dart';
import '../email/email_widgets.dart';
import '../lock/lock_screen.dart';
import '../native/flute_native.dart';
import '../pets/pet_library.dart';
import '../weather/weather_service.dart';
import '../widgets/weather_chip.dart';
import 'press_scale.dart';

/// Opens Settings as a full page.
Future<void> openSettings(BuildContext context, Flute flute) {
  return Navigator.of(context).push<void>(
    MaterialPageRoute<void>(builder: (_) => SettingsPage(flute: flute)),
  );
}

Duration _motion(BuildContext context, int ms) =>
    MediaQuery.disableAnimationsOf(context) ? Duration.zero : Duration(milliseconds: ms);

const _subtle = TextStyle(color: FluteColors.muted, fontSize: 13);

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key, required this.flute});
  final Flute flute;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: FluteColors.bg,
      appBar: AppBar(
        backgroundColor: FluteColors.bg,
        scrolledUnderElevation: 0,
        title: const Text('Settings', style: TextStyle(fontWeight: FontWeight.w300)),
      ),
      body: ListView(
        padding: EdgeInsets.fromLTRB(24, 0, 24, MediaQuery.paddingOf(context).bottom + 32),
        children: [
          _Section('SETUP', [
            ListenableBuilder(
              listenable: Listenable.merge([flute.notificationAccess, flute.usageAccess, flute.dndAccess, flute.defaultHome]),
              builder: (context, _) => Column(
                children: [
                  _Access(
                    title: 'Default home app',
                    detail: 'Flute is your home screen. The Recents button still works: Android provides it through '
                        "Samsung's launcher, so leave that one enabled.",
                    granted: flute.defaultHome.value,
                    onOpen: FluteNative.openHomeSettings,
                  ),
                  _Access(
                    title: 'Notification access',
                    detail: 'Recent WhatsApp and SMS, and the lockscreen',
                    granted: flute.notificationAccess.value,
                    onOpen: FluteNative.openNotificationAccessSettings,
                  ),
                  _Access(
                    title: 'Usage access',
                    detail: 'Pause screen and time by category',
                    granted: flute.usageAccess.value,
                    onOpen: FluteNative.openUsageAccessSettings,
                  ),
                  FutureBuilder<bool>(
                    future: FluteNative.hasOverlayPermission(),
                    builder: (context, snap) => _Access(
                      title: 'Display over other apps',
                      detail: 'Lets the pause screen and lockscreen appear on top',
                      granted: snap.data ?? false,
                      onOpen: FluteNative.openOverlaySettings,
                    ),
                  ),
                  _Access(
                    title: 'Do Not Disturb access',
                    detail: 'Silences calls and alerts (alarms still ring) in Sleep mode',
                    granted: flute.dndAccess.value,
                    onOpen: FluteNative.openPolicyAccessSettings,
                  ),
                ],
              ),
            ),
          ]),
          _Section('LOCKSCREEN', [
            ListenableBuilder(
              listenable: flute.lockSettings,
              builder: (context, _) => Column(
                children: [
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Flute lockscreen'),
                    subtitle: const Text(
                      'Shows the clock, weather and your inbox when you wake the phone. Your PIN or fingerprint still unlocks it. '
                      'Needs notification access and display over other apps.',
                      style: _subtle,
                    ),
                    value: flute.lockSettings.enabled,
                    onChanged: flute.lockSettings.setEnabled,
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Show message previews'),
                    subtitle: const Text(
                      'Off by default: the lockscreen only shows counts and sender names until you unlock.',
                      style: _subtle,
                    ),
                    value: flute.lockSettings.showPreviews,
                    onChanged: flute.lockSettings.setShowPreviews,
                  ),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Preview lockscreen'),
                    trailing: const Icon(Icons.chevron_right, color: FluteColors.muted),
                    onTap: () => Navigator.of(context).push<void>(
                      MaterialPageRoute<void>(
                        builder: (ctx) => Scaffold(
                          backgroundColor: FluteColors.bg,
                          body: LockScreen(flute: flute, settings: flute.lockSettings, onPreviewClose: () => Navigator.of(ctx).pop()),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ]),
          _Section('HOME', [
            _Pets(flute: flute),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Restore default pins'),
              onTap: () async {
                final pins = resolveDefaultPins({for (final a in flute.repo.apps) a.package});
                await flute.repo.setFavorites(pins);
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Default pins restored')));
                }
              },
            ),
          ]),
          _Section('APPEARANCE', [_Appearance(flute: flute)]),
          _Section('WEATHER', [
            ListenableBuilder(
              listenable: flute.weather,
              builder: (context, _) => Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(flute.weather.city.label),
                    subtitle: Text(
                      flute.weather.followLocation ? 'Following your location' : 'Set by hand',
                      style: _subtle,
                    ),
                    trailing: TextButton(
                      onPressed: () => showWeatherLocation(context, flute.weather),
                      child: const Text('Change'),
                    ),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Follow my location'),
                    subtitle: const Text(
                      'Updates the weather city when you travel more than 5 km. Approximate location, only while Flute is open.',
                      style: _subtle,
                    ),
                    value: flute.weather.followLocation,
                    onChanged: (v) async {
                      await flute.weather.setFollowLocation(v);
                      if (v && !flute.weather.followLocation && context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Could not get your location. Allow it, and check that Location is on.')),
                        );
                      }
                    },
                  ),
                ],
              ),
            ),
          ]),
          _Section('GESTURES', [
            ListenableBuilder(
              listenable: Listenable.merge([flute.accessibilityOn, flute.wakeInfo]),
              builder: (context, _) {
                final wake = flute.wakeInfo.value;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _Access(
                      title: 'Double-tap to lock',
                      detail: 'Double-tap an empty spot on Home to turn the screen off. Needs the Flute lock service in '
                          'Accessibility; it can only lock the screen and cannot read anything on it.',
                      granted: flute.accessibilityOn.value,
                      onOpen: FluteNative.openAccessibilitySettings,
                    ),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Double-tap to wake'),
                      subtitle: Text(
                        wake.systemDoubleTapWake
                            ? "Turned on in your phone's own settings, so tapping the dark screen twice wakes it."
                            : "Turn it on in your phone's own motion settings to wake the screen by tapping it twice.",
                        style: _subtle,
                      ),
                      trailing: wake.systemDoubleTapWake
                          ? const Text('On', style: TextStyle(color: FluteColors.accent, fontSize: 15))
                          : TextButton(onPressed: FluteNative.openMotionSettings, child: const Text('Open')),
                    ),
                    if (wake.hasProximity)
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Wave to wake'),
                        subtitle: const Text(
                          'Backup for a broken power button: cover the top of the phone with your hand twice within two seconds '
                          'while the screen is off. Uses a little battery.',
                          style: _subtle,
                        ),
                        value: wake.waveToWake,
                        onChanged: (v) async {
                          await FluteNative.setWaveToWake(v);
                          await flute.refreshPermissions();
                        },
                      ),
                  ],
                );
              },
            ),
          ]),
          _Section('FOCUS', [
            ListenableBuilder(
              listenable: flute.modes,
              builder: (context, _) => Column(
                children: [
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Do Not Disturb in Sleep mode'),
                    subtitle: const Text(
                      'Alarms only. Your previous setting returns when Sleep ends.',
                      style: _subtle,
                    ),
                    value: flute.modes.dndInSleep,
                    onChanged: flute.modes.setDndInSleep,
                  ),
                  _Stepper(
                    label: 'Pause before opening',
                    value: flute.modes.pauseSeconds,
                    unit: 's',
                    min: 3,
                    max: 30,
                    step: 1,
                    onChanged: (v) => flute.modes.setLockTimings(pause: v),
                  ),
                  _Stepper(
                    label: 'Open anyway lasts',
                    value: flute.modes.graceMinutes,
                    unit: ' min',
                    min: 1,
                    max: 30,
                    step: 1,
                    onChanged: (v) => flute.modes.setLockTimings(grace: v),
                  ),
                ],
              ),
            ),
          ]),
          _Section('SCHEDULES', [_Schedules(flute: flute)]),
          _Section('MAIL & DATA', [
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Email accounts (Lark, Gmail, IMAP)'),
              trailing: const Icon(Icons.chevron_right, color: FluteColors.muted),
              onTap: () => showModalBottomSheet<void>(
                context: context,
                isScrollControlled: true,
                builder: (_) => const EmailAccountsSheet(),
              ),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Clear recent messages'),
              onTap: () async {
                await FluteNative.clearRecentMessages();
                await flute.refreshMessages();
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Recent messages cleared')));
                }
              },
            ),
          ]),
          Padding(
            padding: const EdgeInsets.only(top: 32),
            child: Center(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onLongPress: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const BenchPage())),
                child: const Padding(
                  padding: EdgeInsets.symmetric(vertical: 16, horizontal: 24),
                  child: Text('Flute 0.1.0', style: _subtle),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section(this.title, this.children);
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 28),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                title,
                style: const TextStyle(color: FluteColors.muted, fontSize: 12, letterSpacing: 1.2),
              ),
            ),
            ...children,
          ],
        ),
      );
}

class _Access extends StatelessWidget {
  const _Access({required this.title, required this.detail, required this.granted, required this.onOpen});
  final String title;
  final String detail;
  final Future<void> Function() onOpen;
  final bool granted;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(title),
      subtitle: Text(detail, style: _subtle),
      trailing: AnimatedSwitcher(
        duration: _motion(context, 220),
        child: granted
            ? const Text('On', key: ValueKey('on'), style: TextStyle(color: FluteColors.accent, fontSize: 15))
            : TextButton(key: const ValueKey('allow'), onPressed: onOpen, child: const Text('Allow')),
      ),
    );
  }
}

class _Stepper extends StatelessWidget {
  const _Stepper({
    required this.label,
    required this.value,
    required this.unit,
    required this.min,
    required this.max,
    required this.step,
    required this.onChanged,
  });
  final String label;
  final int value;
  final String unit;
  final int min;
  final int max;
  final int step;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(child: Text(label, style: const TextStyle(fontSize: 16))),
        IconButton(
          tooltip: 'Less',
          onPressed: value > min ? () => onChanged(value - step) : null,
          icon: const Icon(Icons.remove),
        ),
        SizedBox(
          width: 64,
          child: Text('$value$unit', textAlign: TextAlign.center, style: const TextStyle(fontSize: 16)),
        ),
        IconButton(
          tooltip: 'More',
          onPressed: value < max ? () => onChanged(value + step) : null,
          icon: const Icon(Icons.add),
        ),
      ],
    );
  }
}

class _Schedules extends StatelessWidget {
  const _Schedules({required this.flute});
  final Flute flute;

  static const _dayNames = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

  static String fmt(int minute) =>
      '${(minute ~/ 60).toString().padLeft(2, '0')}:${(minute % 60).toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: flute.modes,
      builder: (context, _) {
        final list = flute.modes.schedules;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (list.isEmpty)
              const Padding(
                padding: EdgeInsets.only(bottom: 8),
                child: Text('None yet. A schedule switches mode automatically.', style: _subtle),
              ),
            for (var i = 0; i < list.length; i++)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text('${Mode.byId(list[i].modeId).name}  ${fmt(list[i].startMinute)} to ${fmt(list[i].endMinute)}'),
                subtitle: Text(
                  [for (final d in (list[i].days.toList()..sort())) _dayNames[d - 1]].join(' '),
                  style: _subtle,
                ),
                trailing: IconButton(
                  tooltip: 'Remove schedule',
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: () => flute.modes.setSchedules([...list]..removeAt(i)),
                ),
              ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.add, color: FluteColors.muted),
              title: const Text('Add schedule'),
              onTap: () => _add(context, list),
            ),
          ],
        );
      },
    );
  }

  Future<void> _add(BuildContext context, List<Schedule> existing) async {
    var modeId = Mode.work.id;
    final days = <int>{1, 2, 3, 4, 5};
    var start = const TimeOfDay(hour: 9, minute: 0);
    var end = const TimeOfDay(hour: 17, minute: 0);
    final result = await showDialog<Schedule>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('New schedule'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 8,
                  children: [
                    for (final m in Mode.all.where((m) => m.id != 'free'))
                      ChoiceChip(label: Text(m.name), selected: modeId == m.id, onSelected: (_) => setState(() => modeId = m.id)),
                  ],
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 6,
                  children: [
                    for (var d = 1; d <= 7; d++)
                      FilterChip(
                        label: Text(_dayNames[d - 1]),
                        selected: days.contains(d),
                        onSelected: (v) => setState(() => v ? days.add(d) : days.remove(d)),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    TextButton(
                      onPressed: () async {
                        final t = await showTimePicker(context: context, initialTime: start);
                        if (t != null) setState(() => start = t);
                      },
                      child: Text('From ${fmt(start.hour * 60 + start.minute)}'),
                    ),
                    TextButton(
                      onPressed: () async {
                        final t = await showTimePicker(context: context, initialTime: end);
                        if (t != null) setState(() => end = t);
                      },
                      child: Text('To ${fmt(end.hour * 60 + end.minute)}'),
                    ),
                  ],
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
            FilledButton(
              onPressed: days.isEmpty
                  ? null
                  : () => Navigator.pop(
                        context,
                        Schedule(
                          modeId: modeId,
                          days: {...days},
                          startMinute: start.hour * 60 + start.minute,
                          endMinute: end.hour * 60 + end.minute,
                        ),
                      ),
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    if (result != null) await flute.modes.setSchedules([...existing, result]);
  }
}

/// A label with a dropdown of choices. A null value means the automatic choice.
class _PickRow<T> extends StatelessWidget {
  const _PickRow({required this.label, required this.value, required this.items, required this.onChanged});
  final String label;
  final T? value;
  final List<DropdownMenuItem<T?>> items;
  final ValueChanged<T?> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(child: Text(label, style: const TextStyle(fontSize: 16))),
          DropdownButtonHideUnderline(
            child: DropdownButton<T?>(
              value: value,
              items: items,
              onChanged: onChanged,
              dropdownColor: FluteColors.surfaceHigh,
              icon: const Icon(Icons.expand_more, color: FluteColors.muted),
              style: const TextStyle(color: FluteColors.text, fontSize: 16),
            ),
          ),
        ],
      ),
    );
  }
}

/// Lighting follows the time of day. These choices preview any phase or weather on the spot.
class _Appearance extends StatelessWidget {
  const _Appearance({required this.flute});
  final Flute flute;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: flute.style,
      builder: (context, _) {
        final s = flute.style;
        final until = s.previewUntil;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AnimatedSize(
              duration: _motion(context, 240),
              curve: Curves.easeOutCubic,
              alignment: Alignment.topCenter,
              child: s.previewActive && until != null
                  ? Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              'Preview on, ends at ${until.hour.toString().padLeft(2, '0')}:${until.minute.toString().padLeft(2, '0')}',
                              style: const TextStyle(color: FluteColors.warn, fontSize: 13),
                            ),
                          ),
                          TextButton(onPressed: s.endPreview, child: const Text('End preview')),
                        ],
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
            _PickRow<DayPhase>(
              label: 'Time of day',
              value: s.phasePreview,
              items: [
                const DropdownMenuItem<DayPhase?>(value: null, child: Text('Auto')),
                for (final p in DayPhase.values) DropdownMenuItem<DayPhase?>(value: p, child: Text(p.label)),
              ],
              onChanged: s.previewPhase,
            ),
            _PickRow<WeatherKind>(
              label: 'Weather',
              value: s.kindPreview,
              items: [
                const DropdownMenuItem<WeatherKind?>(value: null, child: Text('Live')),
                for (final k in WeatherKind.values) DropdownMenuItem<WeatherKind?>(value: k, child: Text(k.label)),
              ],
              onChanged: s.previewKind,
            ),
          ],
        );
      },
    );
  }
}

/// Pick which characters live on the home screen.
class _Pets extends StatelessWidget {
  const _Pets({required this.flute});
  final Flute flute;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([flute.pets, flute.petLibrary]),
      builder: (context, _) {
        final lib = flute.petLibrary.value;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Show characters on Home'),
              subtitle: const Text(
                'Your character strolls, sleeps at night and heads indoors when it rains. Tap them, or knock on their house.',
                style: _subtle,
              ),
              value: flute.pets.enabled,
              onChanged: flute.pets.setEnabled,
            ),
            AnimatedSize(
              duration: _motion(context, 240),
              curve: Curves.easeOutCubic,
              alignment: Alignment.topCenter,
              child: lib == null || !flute.pets.enabled
                  ? const SizedBox.shrink()
                  : Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('Choose your character', style: _subtle),
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 10,
                            runSpacing: 10,
                            children: [
                              for (final info in lib.infos)
                                _PetTile(
                                  library: lib,
                                  info: info,
                                  selected: flute.pets.selected.contains(info.id),
                                  onTap: () => flute.pets.select(info.id),
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
            ),
          ],
        );
      },
    );
  }
}

class _PetTile extends StatelessWidget {
  const _PetTile({required this.library, required this.info, required this.selected, required this.onTap});
  final PetLibrary library;
  final PetInfo info;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      label: info.name,
      excludeSemantics: true,
      child: PressScale(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: AnimatedContainer(
          duration: _motion(context, 220),
          width: 92,
          padding: const EdgeInsets.fromLTRB(6, 8, 6, 8),
          decoration: BoxDecoration(
            color: selected ? FluteColors.accent.withValues(alpha: 0.12) : FluteColors.surface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: selected ? FluteColors.accent : FluteColors.line, width: selected ? 1.6 : 1),
          ),
          child: Column(
            children: [
              SizedBox(
                width: 64,
                height: 64,
                child: FutureBuilder<PetSprites?>(
                  future: library.sprites(info.id),
                  builder: (context, snap) {
                    final s = snap.data;
                    return s == null ? const SizedBox.shrink() : CustomPaint(painter: _AvatarPainter(s));
                  },
                ),
              ),
              const SizedBox(height: 4),
              Text(
                info.name,
                style: TextStyle(fontSize: 13, color: selected ? FluteColors.accent : FluteColors.text),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Draws a character's first standing frame from its GPU texture.
class _AvatarPainter extends CustomPainter {
  _AvatarPainter(this.sprites);
  final PetSprites sprites;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawImageRect(
      sprites.sheet,
      sprites.frameRect(PetSprites.idle, 0),
      Offset.zero & size,
      Paint()..filterQuality = FilterQuality.medium,
    );
  }

  @override
  bool shouldRepaint(covariant _AvatarPainter old) => old.sprites != sprites;
}

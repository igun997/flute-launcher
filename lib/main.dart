import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'app/flute.dart';
import 'app/theme.dart';
import 'home/shell.dart';
import 'lock/lock_screen.dart';
import 'native/flute_native.dart';
import 'widgets/sky_ink.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Color(0x00000000),
    systemNavigationBarColor: Color(0x00000000),
    statusBarIconBrightness: Brightness.light,
    systemNavigationBarIconBrightness: Brightness.light,
  ));
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  runApp(const FluteApp());
}

class FluteApp extends StatefulWidget {
  const FluteApp({super.key});

  @override
  State<FluteApp> createState() => _FluteAppState();
}

class _FluteAppState extends State<FluteApp> {
  late final Future<Flute> _flute = Flute.create();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Flute',
      debugShowCheckedModeBanner: false,
      theme: fluteTheme(),
      home: FutureBuilder<Flute>(
        future: _flute,
        builder: (context, snap) {
          if (snap.hasError) {
            return Scaffold(body: Center(child: Text('Could not start: ${snap.error}')));
          }
          final flute = snap.data;
          if (flute == null) return const Scaffold(body: SizedBox.expand());
          return _SurfaceSwitch(flute: flute);
        },
      ),
    );
  }
}

/// One engine serves two Android activities: the launcher and the lockscreen above the keyguard.
/// Native says which one is attached, and this draws the matching UI.
class _SurfaceSwitch extends StatefulWidget {
  const _SurfaceSwitch({required this.flute});
  final Flute flute;

  @override
  State<_SurfaceSwitch> createState() => _SurfaceSwitchState();
}

class _SurfaceSwitchState extends State<_SurfaceSwitch> {
  String _surface = 'home';
  StreamSubscription<NativeEvent>? _events;

  @override
  void initState() {
    super.initState();
    FluteNative.getSurface().then((s) {
      if (mounted) setState(() => _surface = s);
    });
    _events = FluteNative.events.listen((e) {
      if (e.isSurface && mounted) setState(() => _surface = e.surface!);
    });
  }

  @override
  void dispose() {
    _events?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.flute.style,
      builder: (context, _) => SkyInk(style: widget.flute.style.style, child: _surfaceBody()),
    );
  }

  Widget _surfaceBody() {
    if (_surface == 'lock') {
      // Scaffold supplies the Material text style; without it text gets the debug underline.
      return Scaffold(
        backgroundColor: FluteColors.bg,
        body: LockScreen(flute: widget.flute, settings: widget.flute.lockSettings),
      );
    }
    return Shell(flute: widget.flute);
  }
}

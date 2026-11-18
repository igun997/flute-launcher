import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../agent/ui/agent_page.dart';
import '../app/flute.dart';
import '../app/theme.dart';
import '../native/flute_native.dart';
import 'home_page.dart';
import '../widgets/mode_fx.dart';
import 'inbox_page.dart';

/// Ask, Home and Inbox side by side: swipe right for the assistant, left for the inbox. The app
/// list is a route that slides up from Home, so Home itself never has to scroll.
class Shell extends StatefulWidget {
  const Shell({super.key, required this.flute});
  final Flute flute;

  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> with WidgetsBindingObserver {
  static const _homePage = 1;
  final _pages = PageController(initialPage: _homePage);
  final _homeVisible = ValueNotifier<bool>(true);
  StreamSubscription<NativeEvent>? _events;
  bool _wasBackgrounded = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _pages.addListener(() => _homeVisible.value = ((_pages.page ?? _homePage.toDouble()) - _homePage).abs() < 0.98);
    _events = FluteNative.events.listen((e) {
      if (e.isHomePressed) _goHome();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _events?.cancel();
    _pages.dispose();
    _homeVisible.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.hidden || state == AppLifecycleState.paused) {
      _wasBackgrounded = true;
    } else if (state == AppLifecycleState.resumed) {
      // Coming back to the launcher (Home pressed, app closed) always lands on the home page.
      if (_wasBackgrounded) _goHome();
      _wasBackgrounded = false;
      unawaited(widget.flute.onResume());
    }
  }

  /// Back to the home page from anywhere: closes the app list and settings, leaves the inbox.
  void _goHome() {
    if (!mounted) return;
    FocusManager.instance.primaryFocus?.unfocus();
    Navigator.of(context).popUntil((r) => r.isFirst);
    if (_pages.hasClients && ((_pages.page ?? _homePage.toDouble()) - _homePage).abs() > 0.02) {
      _pages.animateToPage(_homePage, duration: const Duration(milliseconds: 280), curve: Curves.easeOutCubic);
    }
  }

  void _openInbox() {
    if (_pages.hasClients) {
      _pages.animateToPage(_homePage + 1, duration: const Duration(milliseconds: 280), curve: Curves.easeOutCubic);
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) => _goHome(),
      child: Scaffold(
        // Supplies the Material ancestor that InkWell, TextField and chips need.
        backgroundColor: FluteColors.bg,
        body: ModeFx(
          modes: widget.flute.modes,
          child: PageView(
            controller: _pages,
            physics: const ClampingScrollPhysics(),
            children: [
              _Backdrop(
                flute: widget.flute,
                child: AgentPage(flute: widget.flute, onClose: _goHome),
              ),
              HomePage(flute: widget.flute, onOpenInbox: _openInbox, visible: _homeVisible),
              _Backdrop(flute: widget.flute, child: InboxPage(flute: widget.flute)),
            ],
          ),
        ),
      ),
    );
  }
}

/// Side pages sit on the same sky as Home so the swipe feels like one surface.
class _Backdrop extends StatelessWidget {
  const _Backdrop({required this.flute, required this.child});
  final Flute flute;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        ListenableBuilder(
          listenable: flute.style,
          builder: (context, _) => DecoratedBox(
            decoration: BoxDecoration(color: flute.style.style.scrim.withValues(alpha: 0.97)),
          ),
        ),
        child,
      ],
    );
  }
}

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

import '../app/theme.dart';
import '../rust/rust_core.dart';
import 'benchmarks.dart';

/// Hidden developer page (long-press the version in Settings): times the heavy workloads on this
/// phone and prints each result to the log as `BENCH name median=... best=... sum=...`.
class BenchPage extends StatefulWidget {
  const BenchPage({super.key});

  @override
  State<BenchPage> createState() => _BenchPageState();
}

class _BenchPageState extends State<BenchPage> {
  final _lines = <String>[];
  bool _running = false;

  Future<void> _run() async {
    setState(() {
      _running = true;
      _lines.clear();
    });
    // Let the spinner paint before the isolate gets busy.
    await Future<void>.delayed(const Duration(milliseconds: 100));
    final fixtures = Fixtures.build();
    void log(String line) {
      debugPrint(line);
      if (mounted) setState(() => _lines.add(line.replaceFirst('BENCH ', '')));
    }

    log('BENCH build=${kReleaseMode ? 'release' : kProfileMode ? 'profile' : 'debug'}');
    await runBenchmarks(fixtures, dartWorkloads, log: (l) => log(l.replaceFirst('BENCH ', 'BENCH dart/')));
    if (RustCore.instance.isStarted) {
      // The search index lives in Rust: fill it first, outside the timed searches.
      await RustCore.instance.setModels(fixtures.models);
      await runBenchmarks(fixtures, rustWorkloads, log: (l) => log(l.replaceFirst('BENCH ', 'BENCH rust/')));
    } else {
      log('BENCH rust: not started');
    }
    debugPrint('BENCH done');
    if (mounted) setState(() => _running = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: FluteColors.bg,
      appBar: AppBar(title: const Text('Benchmark')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const Text(
            'Times the heavy jobs on this phone. Keep the screen on and wait until it says done.',
            style: TextStyle(color: FluteColors.muted),
          ),
          const SizedBox(height: 16),
          FilledButton(onPressed: _running ? null : _run, child: Text(_running ? 'Running...' : 'Run benchmarks')),
          const SizedBox(height: 16),
          for (final l in _lines) Padding(padding: const EdgeInsets.only(bottom: 6), child: Text(l, style: const TextStyle(fontSize: 12, fontFamily: 'monospace'))),
        ],
      ),
    );
  }
}

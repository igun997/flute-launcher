import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart' show sha256;

import '../agent/llm/model_catalog.dart';
import '../agent/llm/model_info.dart';
import '../agent/llm/sse.dart';
import '../core/category_engine.dart';
import '../core/models.dart';

/// One timed workload. [run] does the whole job and returns a checksum the caller compares across
/// implementations (Dart vs Rust), so a fast but wrong answer cannot pass.
class Workload {
  const Workload(this.name, this.describe, this.run);
  final String name;
  final String describe;
  final Future<String> Function(Fixtures f) run;
}

class BenchResult {
  const BenchResult(this.name, this.describe, this.median, this.best, this.checksum, this.runs);
  final String name;
  final String describe;
  final Duration median;
  final Duration best;
  final String checksum;
  final int runs;

  @override
  String toString() =>
      'BENCH $name median=${(median.inMicroseconds / 1000).toStringAsFixed(2)}ms '
      'best=${(best.inMicroseconds / 1000).toStringAsFixed(2)}ms runs=$runs sum=$checksum';
}

/// Deterministic inputs shared by every implementation.
class Fixtures {
  Fixtures._(this.blob, this.zip, this.sseBytes, this.models, this.apps, this.queries);

  /// 5 MB of text-like bytes.
  final Uint8List blob;

  /// A zip of 300 skill-like files (~6 MB uncompressed).
  final Uint8List zip;

  /// A streamed chat reply: 4000 delta events plus usage and [DONE], as one byte buffer.
  final Uint8List sseBytes;

  final List<ModelInfo> models;
  final List<(String, String)> apps;
  final List<String> queries;

  static Fixtures build() {
    final rnd = Random(7);
    const words = ['alpha', 'bravo', 'charlie', 'delta', 'echo', 'flute', 'gateway', 'kernel', 'lunar', 'model'];
    String sentence(int n) => List.generate(n, (_) => words[rnd.nextInt(words.length)]).join(' ');

    final blob = Uint8List.fromList(utf8.encode(List.generate(80000, (_) => sentence(10)).join('\n')).take(5 * 1024 * 1024).toList());

    final archive = Archive();
    for (var i = 0; i < 300; i++) {
      final body = utf8.encode('# skill $i\n${List.generate(400, (_) => sentence(9)).join('\n')}');
      archive.addFile(ArchiveFile('skills/skill$i/SKILL.md', body.length, body));
    }
    final zip = Uint8List.fromList(ZipEncoder().encode(archive));

    final sse = StringBuffer();
    for (var i = 0; i < 4000; i++) {
      sse.write('data: {"id":"c$i","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":"${words[i % 10]} "},"finish_reason":null}]}\n\n');
    }
    sse.write('data: {"choices":[],"usage":{"prompt_tokens":120,"completion_tokens":4000}}\n\ndata: [DONE]\n\n');

    const owners = ['openai', 'anthropic', 'google', 'meta', 'mistral', 'cx', 'local'];
    final models = [
      for (var i = 0; i < 5000; i++)
        ModelInfo(
          id: '${owners[i % owners.length]}/${words[i % 10]}-${i % 97}-${words[(i * 7) % 10]}',
          name: '${words[i % 10]} ${i % 97} ${words[(i * 3) % 10]}',
          ownedBy: owners[i % owners.length],
        ),
    ];

    final apps = [
      for (var i = 0; i < 3000; i++) ('com.vendor${i % 300}.${words[i % 10]}${i % 53}', '${words[(i * 3) % 10]} ${words[(i * 7) % 10]} app'),
    ];

    return Fixtures._(blob, zip, Uint8List.fromList(utf8.encode(sse.toString())), models, apps, const ['cx', 'flute 12', 'gateway kernel', 'lunar-4', 'zzz', 'model delta 9']);
  }
}

/// The Dart implementations: the baseline every Rust port is compared with.
final List<Workload> dartWorkloads = [
  Workload('sha256_5mb', 'SHA-256 of a 5 MB buffer', (f) async => sha256.convert(f.blob).toString().substring(0, 16)),
  Workload('zip_extract_hash', 'Unzip 300 files and hash their contents (skill install)', (f) async {
    final files = ZipDecoder().decodeBytes(f.zip).files.where((e) => e.isFile).toList()..sort((a, b) => a.name.compareTo(b.name));
    final out = BytesBuilder(copy: false);
    for (final e in files) {
      out.add(utf8.encode(e.name));
      out.addByte(0);
      out.add(e.content as List<int>);
    }
    return '${files.length}:${sha256.convert(out.takeBytes()).toString().substring(0, 16)}';
  }),
  Workload('sse_json_4000', 'Parse a 4000-event chat stream and collect the text', (f) async {
    final text = StringBuffer();
    var usage = 0;
    // Delivered in 1 KB chunks, like a socket would.
    Stream<List<int>> chunks() async* {
      for (var i = 0; i < f.sseBytes.length; i += 1024) {
        yield Uint8List.sublistView(f.sseBytes, i, min(i + 1024, f.sseBytes.length));
      }
    }

    await for (final e in parseSse(chunks())) {
      if (e.data == '[DONE]') break;
      final j = jsonDecode(e.data) as Map<String, dynamic>;
      final choices = j['choices'] as List;
      if (choices.isNotEmpty) {
        text.write(((choices.first as Map)['delta'] as Map)['content']);
      } else {
        usage = (j['usage'] as Map)['completion_tokens'] as int;
      }
    }
    return '${text.length}:$usage';
  }),
  Workload('model_search_5000', 'Six searches over 5000 models', (f) async {
    var total = 0;
    for (final q in f.queries) {
      total += ModelCatalog.search(f.models, q).length;
    }
    return '$total';
  }),
  Workload('categorize_3000', 'Categorize 3000 installed apps by keywords', (f) async {
    final engine = CategoryEngine({});
    final counts = List.filled(AppCategory.values.length, 0);
    for (final (pkg, label) in f.apps) {
      counts[engine.categorize(pkg, label).index]++;
    }
    return counts.join(',');
  }),
];

/// Runs [workloads] [rounds] times after one warm-up and reports median and best.
Future<List<BenchResult>> runBenchmarks(
  Fixtures f,
  List<Workload> workloads, {
  int rounds = 7,
  void Function(String line)? log,
}) async {
  final results = <BenchResult>[];
  for (final w in workloads) {
    await w.run(f); // warm-up: JIT-free, but fills caches and lazy statics
    final times = <Duration>[];
    var sum = '';
    for (var i = 0; i < rounds; i++) {
      final sw = Stopwatch()..start();
      sum = await w.run(f);
      sw.stop();
      times.add(sw.elapsed);
    }
    times.sort();
    final r = BenchResult(w.name, w.describe, times[times.length ~/ 2], times.first, sum, rounds);
    results.add(r);
    log?.call(r.toString());
  }
  return results;
}

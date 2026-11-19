import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:focus_launcher/agent/sandbox/sandbox_outputs.dart';

void main() {
  test('the type comes from the extension, case-insensitively, and unknown ones are binary', () {
    expect(SandboxOutputs.mimeFor('chart.PNG'), 'image/png');
    expect(SandboxOutputs.mimeFor('/out/report.csv'), 'text/csv');
    expect(SandboxOutputs.mimeFor('a.tar.gz'), 'application/octet-stream');
    expect(SandboxOutputs.mimeFor('noext'), 'application/octet-stream');
    expect(SandboxOutputs.mimeFor('trailing.'), 'application/octet-stream');
  });

  test('names are the last segment with unsafe characters replaced and a bounded length', () {
    expect(SandboxOutputs.safeName('/home/user/my chart (1).png'), 'my chart _1_.png');
    expect(SandboxOutputs.safeName('../../etc/passwd'), 'passwd');
    expect(SandboxOutputs.safeName('.hidden'), '_hidden');
    expect(SandboxOutputs.safeName('/'), 'file');
    final long = SandboxOutputs.safeName('${'a' * 200}.png');
    expect(long.length, 80);
    expect(long, endsWith('.png'));
  });

  group('save', () {
    late Directory dir;
    setUp(() async => dir = await Directory.systemTemp.createTemp('flute_outputs'));
    tearDown(() => dir.delete(recursive: true));

    test('stores the bytes under a unique name and describes the file', () async {
      final outputs = SandboxOutputs(directory: () async => dir);
      final a = await outputs.save('/out/chart.png', [1, 2, 3]);
      final b = await outputs.save('/out/chart.png', [4]);

      expect(a.name, 'chart.png');
      expect(a.mime, 'image/png');
      expect(a.isImage, isTrue);
      expect(a.bytes, 3);
      expect(File(a.path).readAsBytesSync(), [1, 2, 3]);
      expect(a.path, isNot(b.path));
      expect(a.path.startsWith(dir.path), isTrue);
    });

    test('a file over the limit is refused without writing anything', () async {
      final outputs = SandboxOutputs(directory: () async => dir);
      await expectLater(
        outputs.save('/out/big.bin', List.filled(SandboxOutputs.maxFileBytes + 1, 0)),
        throwsA(isA<FileSystemException>()),
      );
      expect(dir.listSync(), isEmpty);
    });
  });
}

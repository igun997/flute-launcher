import 'package:flutter_test/flutter_test.dart';
import 'package:focus_launcher/agent/ui/chat_bubbles.dart';

void main() {
  group('formatBytes', () {
    test('counts below one kilobyte stay whole', () {
      expect(formatBytes(0), '0 B');
      expect(formatBytes(512), '512 B');
      expect(formatBytes(1023), '1023 B');
    });

    test('kilobytes and megabytes show one decimal', () {
      expect(formatBytes(1024), '1.0 KB');
      expect(formatBytes(1536), '1.5 KB');
      expect(formatBytes(1024 * 1024), '1.0 MB');
      expect(formatBytes(1258291), '1.2 MB');
    });

    test('a negative count reads as zero', () {
      expect(formatBytes(-5), '0 B');
    });
  });
}

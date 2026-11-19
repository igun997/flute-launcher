import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:focus_launcher/agent/tools/agent_tool.dart';
import 'package:focus_launcher/agent/ui/image_canvas.dart';
import 'package:material_ui/material_ui.dart';

/// A 320 x 240 picture, like the small charts the Python sandbox draws.
Future<File> _smallPng(Directory dir) async {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawRect(const Rect.fromLTWH(0, 0, 320, 240), Paint()..color = const Color(0xFF3366CC));
  final image = await recorder.endRecording().toImage(320, 240);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  final file = File('${dir.path}/chart.png');
  await file.writeAsBytes(data!.buffer.asUint8List());
  return file;
}

void main() {
  testWidgets('a small picture is shown large and centred in the full-screen viewer', (tester) async {
    tester.view.physicalSize = const Size(720, 1600);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    final dir = await tester.runAsync(() => Directory.systemTemp.createTemp('viewer'));
    addTearDown(() => dir!.deleteSync(recursive: true));
    final png = (await tester.runAsync(() => _smallPng(dir!)))!;
    final file = ToolFile(path: png.path, name: 'chart.png', mime: 'image/png', bytes: png.lengthSync());

    await tester.pumpWidget(MaterialApp(home: Scaffold(body: GeneratedImage(file: file))));
    // The picture decodes on a real thread; give it time, then show the frame.
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pump(const Duration(milliseconds: 500));
    // Invoke the handler directly: the thumbnail's hit box depends on decode timing in tests.
    tester.widget<GestureDetector>(find.descendant(of: find.byType(GeneratedImage), matching: find.byType(GestureDetector)).first).onTap!();
    await tester.pumpAndSettle();

    final viewer = find.byType(InteractiveViewer);
    expect(viewer, findsOneWidget);
    final picture = find.descendant(of: viewer, matching: find.byType(Image));
    final box = tester.getRect(picture);
    // The viewport is 360 x 800 logical px: the picture fills it and sits in the middle.
    expect(box.width, 360);
    expect(box.height, 800);
    expect(box.center.dy, closeTo(400, 1));
    expect(find.descendant(of: picture, matching: find.byType(RawImage)), findsOneWidget);
    // The close, save and share buttons stay on the top edge, not in the middle of the screen.
    expect(tester.getTopLeft(find.byTooltip('Close')).dy, lessThan(100));
  });
}

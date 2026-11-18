import 'package:flutter_test/flutter_test.dart';
import 'package:focus_launcher/app/flute.dart';

void main() {
  testWidgets('external flow stays active during the run and for 2 s after it ends', (tester) async {
    expect(Flute.inExternalFlow, isFalse);

    var duringRun = false;
    await Flute.externalFlow(() async {
      duringRun = Flute.inExternalFlow;
    });

    expect(duringRun, isTrue);
    expect(Flute.inExternalFlow, isTrue);

    await tester.pump(const Duration(milliseconds: 1999));
    expect(Flute.inExternalFlow, isTrue);

    await tester.pump(const Duration(milliseconds: 2));
    expect(Flute.inExternalFlow, isFalse);
  });
}

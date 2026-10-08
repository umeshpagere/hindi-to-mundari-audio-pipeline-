// Stage-1 smoke test: verifies the app renders the STT test screen.
// A full integration test (with a real model + WAV) is out of scope for Stage 1.

import 'package:flutter_test/flutter_test.dart';

import 'package:mundari_pipeline/main.dart';

void main() {
  testWidgets('STT test screen renders', (WidgetTester tester) async {
    await tester.pumpWidget(const MundariPipelineApp());
    // The screen title should be visible.
    expect(find.text('Hindi STT Live Lab'), findsOneWidget);
  });
}

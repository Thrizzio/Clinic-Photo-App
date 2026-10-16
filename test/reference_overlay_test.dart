import 'dart:typed_data';

import 'package:clinic_photos/widgets/reference_overlay.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('reference overlay is translucent, adjustable, and clearable', (
    tester,
  ) async {
    double? changedOpacity;
    var clearCount = 0;
    final bytes = Uint8List.fromList(const <int>[
      0x89,
      0x50,
      0x4E,
      0x47,
      0x0D,
      0x0A,
      0x1A,
      0x0A,
    ]);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ReferenceOverlay(
            imageBytes: bytes,
            opacity: 0.35,
            onOpacityChanged: (value) => changedOpacity = value,
            onClear: () => clearCount++,
          ),
        ),
      ),
    );

    expect(
      find.byWidgetPredicate(
        (widget) => widget is IgnorePointer && widget.ignoring,
      ),
      findsOneWidget,
    );
    final opacity = tester.widget<Opacity>(find.byType(Opacity));
    expect(opacity.opacity, 0.35);

    final slider = find.byKey(const Key('reference_opacity_slider'));
    expect(slider, findsOneWidget);
    await tester.tap(slider);
    expect(changedOpacity, isNotNull);

    await tester.tap(find.byKey(const Key('clear_reference_button')));
    expect(clearCount, 1);
  });
}

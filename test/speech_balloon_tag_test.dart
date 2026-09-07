import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shopitem_curator/core/models/curator_item.dart';
import 'package:shopitem_curator/ui/widgets/speech_balloon_tag.dart';

void main() {
  testWidgets('honors compact width without overflowing and closes by button',
      (tester) async {
    var dismissCount = 0;
    await tester.pumpWidget(
      _host(
        SpeechBalloonTag(
          item: _item(),
          width: 190,
          tailAlignment: 0.8,
          tailOnTop: true,
          onDismiss: () => dismissCount++,
        ),
      ),
    );
    await tester.pump();

    expect(tester.getSize(find.byType(SpeechBalloonTag)).width, 190);
    expect(tester.takeException(), isNull);

    await tester.tap(
      find.byKey(const ValueKey('speech_balloon_close_button')),
    );
    expect(dismissCount, 1);
  });

  testWidgets('Escape dismisses while focus is inside the balloon',
      (tester) async {
    var dismissCount = 0;
    await tester.pumpWidget(
      _host(
        SpeechBalloonTag(
          item: _item(),
          onDismiss: () => dismissCount++,
        ),
      ),
    );
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);

    expect(dismissCount, 1);
  });
}

Widget _host(Widget child) {
  return MaterialApp(
    home: Scaffold(
      body: Center(child: child),
    ),
  );
}

CuratorItem _item() {
  return CuratorItem(
    id: 'balloon-item',
    name: 'A school supply with a long product name',
    category: 'test',
    isPersonal: false,
    quantity: 1,
    price: 0,
    priceCurrency: 'USD',
    description:
        'A longer description verifies that the compact presentation truncates safely.',
    targetUrl: '',
    imageUrl: '',
    bounds: const ItemLayoutBounds(x: 0, y: 0, width: 20, height: 20),
    polygon: const [
      CuratorPoint(0, 0),
      CuratorPoint(20, 0),
      CuratorPoint(20, 20),
      CuratorPoint(0, 20),
    ],
    centroid: const CuratorPoint(10, 10),
  );
}

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shopitem_curator/core/models/curator_item.dart';
import 'package:shopitem_curator/ui/widgets/curator_canvas.dart';
import 'package:shopitem_curator/ui/widgets/speech_balloon_tag.dart';

void main() {
  testWidgets('only the segmented silhouette accepts item taps',
      (tester) async {
    String? selectedItemId;
    var dismissCount = 0;

    final item = CuratorItem(
      id: 'triangle',
      name: 'Triangle',
      category: 'test',
      isPersonal: false,
      quantity: 1,
      price: 1,
      priceCurrency: 'USD',
      description: 'Triangular silhouette',
      targetUrl: '',
      imageUrl: '',
      bounds: const ItemLayoutBounds(x: 0, y: 0, width: 100, height: 100),
      polygon: [
        const CuratorPoint(0, 0),
        const CuratorPoint(100, 0),
        const CuratorPoint(0, 100),
      ],
      centroid: const CuratorPoint(33.3, 33.3),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 200,
              height: 200,
              child: CuratorCanvas(
                manifest: CuratorManifest(
                  canvasWidth: 100,
                  canvasHeight: 100,
                  items: [item],
                ),
                hoveredItemId: null,
                selectedItemId: null,
                onHoverItem: (_) {},
                onSelectItem: (id) => selectedItemId = id,
                onDismissSelection: () => dismissCount++,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final itemRect = tester.getRect(
      find.byKey(const ValueKey('curator_canvas_item_triangle')),
    );

    // Bottom-right belongs to the rectangular bounds, but not the triangle.
    await tester.tapAt(itemRect.bottomRight - const Offset(8, 8));
    await tester.pump();
    expect(selectedItemId, isNull);
    expect(dismissCount, 1);

    // Top-left is inside the segmented triangle and selects the item.
    await tester.tapAt(itemRect.topLeft + const Offset(24, 24));
    await tester.pump();
    expect(selectedItemId, 'triangle');
  });

  testWidgets('each disconnected contour accepts taps but the gap does not',
      (tester) async {
    String? selectedItemId;
    var dismissCount = 0;
    const left = [
      CuratorPoint(0, 0),
      CuratorPoint(30, 0),
      CuratorPoint(30, 30),
      CuratorPoint(0, 30),
    ];
    const right = [
      CuratorPoint(70, 0),
      CuratorPoint(100, 0),
      CuratorPoint(100, 30),
      CuratorPoint(70, 30),
    ];
    final item = _item(
      id: 'compound',
      polygon: left,
      contours: const [left, right],
    );

    await tester.pumpWidget(
      _host(
        CuratorCanvas(
          manifest: CuratorManifest(
            canvasWidth: 100,
            canvasHeight: 100,
            items: [item],
          ),
          hoveredItemId: null,
          selectedItemId: null,
          onHoverItem: (_) {},
          onSelectItem: (id) => selectedItemId = id,
          onDismissSelection: () => dismissCount++,
        ),
      ),
    );
    await tester.pump();
    final itemRect = tester.getRect(
      find.byKey(const ValueKey('curator_canvas_item_compound')),
    );

    await tester.tapAt(itemRect.topLeft + const Offset(30, 30));
    await tester.pump();
    expect(selectedItemId, 'compound');

    selectedItemId = null;
    await tester.tapAt(itemRect.topLeft + const Offset(100, 30));
    await tester.pump();
    expect(selectedItemId, isNull);
    expect(dismissCount, greaterThan(0));

    await tester.tapAt(itemRect.topLeft + const Offset(170, 30));
    await tester.pump();
    expect(selectedItemId, 'compound');
  });

  testWidgets(
      'uses the flattened canvas until a custom layout, then resets on a new manifest',
      (tester) async {
    final item = _item(
      id: 'editable',
      imageUrl: _onePixelPngDataUri,
      polygon: const [
        CuratorPoint(0, 0),
        CuratorPoint(100, 0),
        CuratorPoint(100, 100),
        CuratorPoint(0, 100),
      ],
    );

    CuratorCanvas canvasFor(String sourceImage) => CuratorCanvas(
          manifest: CuratorManifest(
            sourceImage: sourceImage,
            canvasImage: _onePixelPngDataUri,
            canvasWidth: 100,
            canvasHeight: 100,
            items: [item],
          ),
          hoveredItemId: null,
          selectedItemId: null,
          onHoverItem: (_) {},
          onSelectItem: (_) {},
          onDismissSelection: () {},
        );

    await tester.pumpWidget(_host(canvasFor('first.jpg')));
    await tester.pump();
    expect(
      find.byKey(const ValueKey('curator_canvas_flattened_base')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('curator_canvas_item_image_editable')),
      findsNothing,
    );

    final itemRect = tester.getRect(
      find.byKey(const ValueKey('curator_canvas_item_editable')),
    );
    await tester.dragFrom(itemRect.center, const Offset(40, 0));
    await tester.pump();

    expect(
      find.byKey(const ValueKey('curator_canvas_flattened_base')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('curator_canvas_item_image_editable')),
      findsOneWidget,
    );

    expect(
      find.byKey(const ValueKey('curator_canvas_reset_layout')),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(const ValueKey('curator_canvas_reset_layout')),
    );
    await tester.pump();
    expect(
      find.byKey(const ValueKey('curator_canvas_flattened_base')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('curator_canvas_item_image_editable')),
      findsNothing,
    );

    final resetItemRect = tester.getRect(
      find.byKey(const ValueKey('curator_canvas_item_editable')),
    );
    await tester.dragFrom(resetItemRect.center, const Offset(40, 0));
    await tester.pump();

    await tester.pumpWidget(_host(canvasFor('replacement.jpg')));
    await tester.pump();
    expect(
      find.byKey(const ValueKey('curator_canvas_flattened_base')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('curator_canvas_item_image_editable')),
      findsNothing,
    );
  });

  testWidgets('clamps large drags and enlarged items inside the canvas',
      (tester) async {
    final item = _item(
      id: 'bounded',
      bounds: const ItemLayoutBounds(x: 70, y: 70, width: 20, height: 20),
      centroid: const CuratorPoint(80, 80),
      polygon: const [
        CuratorPoint(70, 70),
        CuratorPoint(90, 70),
        CuratorPoint(90, 90),
        CuratorPoint(70, 90),
      ],
    );

    await tester.pumpWidget(
      _host(
        CuratorCanvas(
          manifest: CuratorManifest(
            canvasWidth: 100,
            canvasHeight: 100,
            items: [item],
          ),
          hoveredItemId: 'bounded',
          selectedItemId: null,
          onHoverItem: (_) {},
          onSelectItem: (_) {},
          onDismissSelection: () {},
        ),
      ),
    );
    await tester.pump();

    Rect canvasRect() => tester.getRect(
          find.byKey(const ValueKey('curator_canvas_surface')),
        );
    Rect itemRect() => tester.getRect(
          find.byKey(const ValueKey('curator_canvas_item_bounded')),
        );

    await tester.dragFrom(itemRect().center, const Offset(1000, 1000));
    await tester.pumpAndSettle();
    expect(itemRect().right, lessThanOrEqualTo(canvasRect().right + 0.01));
    expect(itemRect().bottom, lessThanOrEqualTo(canvasRect().bottom + 0.01));

    final boundedFocus = tester.widget<Focus>(
      find.byKey(const ValueKey('curator_canvas_item_focus_bounded')),
    );
    boundedFocus.focusNode!.requestFocus();
    await tester.pump();
    for (var index = 0; index < 20; index++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.equal);
    }
    await tester.pump();
    expect(itemRect().right, lessThanOrEqualTo(canvasRect().right + 0.01));
    expect(itemRect().bottom, lessThanOrEqualTo(canvasRect().bottom + 0.01));

    await tester.dragFrom(itemRect().center, const Offset(-1000, -1000));
    await tester.pumpAndSettle();
    expect(itemRect().left, greaterThanOrEqualTo(canvasRect().left - 0.01));
    expect(itemRect().top, greaterThanOrEqualTo(canvasRect().top - 0.01));
  });

  testWidgets('positions the balloon at the scaled item centroid',
      (tester) async {
    final item = _item(
      id: 'anchor',
      bounds: const ItemLayoutBounds(x: 260, y: 250, width: 100, height: 100),
      centroid: const CuratorPoint(280, 280),
      polygon: const [
        CuratorPoint(260, 250),
        CuratorPoint(360, 250),
        CuratorPoint(360, 350),
        CuratorPoint(260, 350),
      ],
    );

    await tester.pumpWidget(
      _sizedHost(
        width: 600,
        height: 400,
        child: CuratorCanvas(
          manifest: CuratorManifest(
            canvasWidth: 600,
            canvasHeight: 400,
            items: [item],
          ),
          hoveredItemId: null,
          selectedItemId: 'anchor',
          onHoverItem: (_) {},
          onSelectItem: (_) {},
          onDismissSelection: () {},
        ),
      ),
    );
    await tester.pump();
    final anchorFocus = tester.widget<Focus>(
      find.byKey(const ValueKey('curator_canvas_item_focus_anchor')),
    );
    anchorFocus.focusNode!.requestFocus();
    await tester.pump();
    for (var index = 0; index < 5; index++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.equal);
    }
    await tester.pump();

    final canvasRect = tester.getRect(
      find.byKey(const ValueKey('curator_canvas_surface')),
    );
    final balloonRect = tester.getRect(
      find.byKey(const ValueKey('curator_canvas_speech_balloon_anchor')),
    );
    // x = bounds.x + (centroid.x - bounds.x) * 1.5
    expect(balloonRect.center.dx - canvasRect.left, closeTo(290, 0.01));
  });

  testWidgets('keeps a compact balloon within narrow canvas side margins',
      (tester) async {
    final item = _item(
      id: 'narrow',
      bounds: const ItemLayoutBounds(x: 75, y: 60, width: 20, height: 20),
      centroid: const CuratorPoint(90, 70),
      polygon: const [
        CuratorPoint(75, 60),
        CuratorPoint(95, 60),
        CuratorPoint(95, 80),
        CuratorPoint(75, 80),
      ],
    );

    await tester.pumpWidget(
      _sizedHost(
        width: 220,
        height: 220,
        child: CuratorCanvas(
          manifest: CuratorManifest(
            canvasWidth: 100,
            canvasHeight: 100,
            items: [item],
          ),
          hoveredItemId: null,
          selectedItemId: 'narrow',
          onHoverItem: (_) {},
          onSelectItem: (_) {},
          onDismissSelection: () {},
        ),
      ),
    );
    await tester.pump();

    final canvasRect = tester.getRect(
      find.byKey(const ValueKey('curator_canvas_surface')),
    );
    final balloonFinder =
        find.byKey(const ValueKey('curator_canvas_speech_balloon_narrow'));
    final balloonRect = tester.getRect(balloonFinder);
    final balloon = tester.widget<SpeechBalloonTag>(balloonFinder);

    expect(balloon.width, lessThanOrEqualTo(canvasRect.width - 16));
    expect(balloonRect.left, greaterThanOrEqualTo(canvasRect.left + 8 - 0.01));
    expect(balloonRect.right, lessThanOrEqualTo(canvasRect.right - 8 + 0.01));
    expect(
      find.ancestor(of: balloonFinder, matching: find.byType(ClipRRect)),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('does not scale the active overlay above a flattened base',
      (tester) async {
    final item = _item(
      id: 'flat-active',
      imageUrl: _onePixelPngDataUri,
      polygon: const [
        CuratorPoint(0, 0),
        CuratorPoint(100, 0),
        CuratorPoint(100, 100),
        CuratorPoint(0, 100),
      ],
    );

    await tester.pumpWidget(
      _host(
        CuratorCanvas(
          manifest: CuratorManifest(
            canvasImage: _onePixelPngDataUri,
            canvasWidth: 100,
            canvasHeight: 100,
            items: [item],
          ),
          hoveredItemId: 'flat-active',
          selectedItemId: null,
          onHoverItem: (_) {},
          onSelectItem: (_) {},
          onDismissSelection: () {},
        ),
      ),
    );
    await tester.pump();

    AnimatedScale activeScale() => tester.widget<AnimatedScale>(
          find.descendant(
            of: find.byKey(
              const ValueKey('curator_canvas_item_flat-active'),
            ),
            matching: find.byType(AnimatedScale),
          ),
        );
    expect(activeScale().scale, 1);

    final itemRect = tester.getRect(
      find.byKey(const ValueKey('curator_canvas_item_flat-active')),
    );
    await tester.dragFrom(itemRect.center, const Offset(40, 0));
    await tester.pump();
    expect(activeScale().scale, 1.05);
  });

  testWidgets('supports keyboard selection, dismissal, and scaling',
      (tester) async {
    final selectedIds = <String>[];
    var dismissCount = 0;
    final item = _item(
      id: 'keyboard',
      polygon: const [
        CuratorPoint(0, 0),
        CuratorPoint(100, 0),
        CuratorPoint(100, 100),
        CuratorPoint(0, 100),
      ],
    );

    await tester.pumpWidget(
      _host(
        CuratorCanvas(
          manifest: CuratorManifest(
            canvasWidth: 100,
            canvasHeight: 100,
            items: [item],
          ),
          hoveredItemId: null,
          selectedItemId: null,
          onHoverItem: (_) {},
          onSelectItem: (id) {
            if (id != null) selectedIds.add(id);
          },
          onDismissSelection: () => dismissCount++,
        ),
      ),
    );
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(selectedIds, ['keyboard']);

    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    expect(selectedIds, ['keyboard', 'keyboard']);

    await tester.sendKeyEvent(LogicalKeyboardKey.equal);
    await tester.pump();
    expect(
      find.byKey(const ValueKey('curator_canvas_reset_layout')),
      findsOneWidget,
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    expect(dismissCount, 1);
  });
}

Widget _host(Widget child) {
  return _sizedHost(width: 200, height: 200, child: child);
}

Widget _sizedHost({
  required double width,
  required double height,
  required Widget child,
}) {
  return MaterialApp(
    home: Scaffold(
      body: Center(child: SizedBox(width: width, height: height, child: child)),
    ),
  );
}

CuratorItem _item({
  required String id,
  required List<CuratorPoint> polygon,
  List<List<CuratorPoint>>? contours,
  String imageUrl = '',
  ItemLayoutBounds bounds =
      const ItemLayoutBounds(x: 0, y: 0, width: 100, height: 100),
  CuratorPoint? centroid,
}) {
  return CuratorItem(
    id: id,
    name: id,
    category: 'test',
    isPersonal: false,
    quantity: 1,
    price: 1,
    priceCurrency: 'USD',
    description: '',
    targetUrl: '',
    imageUrl: imageUrl,
    bounds: bounds,
    polygon: polygon,
    contours: contours,
    centroid: centroid ??
        CuratorPoint(
          bounds.x + (bounds.width / 2),
          bounds.y + (bounds.height / 2),
        ),
  );
}

const _onePixelPngDataUri =
    'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwC'
    'AAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=';

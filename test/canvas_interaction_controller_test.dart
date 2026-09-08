import 'package:shopitem_curator/core/models/curator_item.dart';
import 'package:shopitem_curator/core/services/canvas_interaction_controller.dart';
import 'package:test/test.dart';

void main() {
  group('CanvasInteractionController (Pure Dart UI-Logic Separation)', () {
    late CanvasInteractionController controller;
    final item1 = CuratorItem(
      id: 'item_1',
      name: 'Pencils',
      category: 'Writing',
      isPersonal: false,
      quantity: 1,
      price: 2.99,
      priceCurrency: 'USD',
      description: 'Pack of 12 pencils',
      targetUrl: 'https://www.target.com/p/-/A-12345678',
      imageUrl: 'https://target.scene7.com/is/image/Target/GUEST_1111',
      bounds: const ItemLayoutBounds(x: 50, y: 50, width: 100, height: 100),
      polygon: const [],
      contours: const [],
      centroid: const CuratorPoint(100, 100),
    );

    final item2 = CuratorItem(
      id: 'item_2',
      name: 'Notebook',
      category: 'Paper',
      isPersonal: true,
      quantity: 2,
      price: 1.50,
      priceCurrency: 'USD',
      description: 'Spiral notebook',
      targetUrl: 'https://www.target.com/p/-/A-87654321',
      imageUrl: 'https://target.scene7.com/is/image/Target/GUEST_2222',
      bounds: const ItemLayoutBounds(x: 200, y: 150, width: 150, height: 200),
      polygon: const [],
      contours: const [],
      centroid: const CuratorPoint(275, 250),
    );

    setUp(() {
      controller = CanvasInteractionController(
        canvasWidth: 1200,
        canvasHeight: 820,
        initialItems: [item1, item2],
      );
    });

    test('initializes with default state', () {
      expect(controller.canvasWidth, 1200);
      expect(controller.canvasHeight, 820);
      expect(controller.renderOrder, ['item_1', 'item_2']);
      expect(controller.dragOffset('item_1'), CanvasOffset.zero);
      expect(controller.itemScale('item_1'), 1.0);
      expect(controller.hasCustomLayout, isFalse);
    });

    test('clamps drag offsets strictly inside canvas boundaries', () {
      // Trying to drag item1 off the left/top edge
      controller.moveItem(item1, const CanvasOffset(-100, -100));
      expect(
          controller.dragOffset('item_1').dx, -50.0); // left bound clamped at 0
      expect(
          controller.dragOffset('item_1').dy, -50.0); // top bound clamped at 0
      expect(controller.hasCustomLayout, isTrue);

      // Trying to drag item1 beyond the right/bottom edge
      controller.moveItem(item1, const CanvasOffset(2000, 2000));
      expect(controller.dragOffset('item_1').dx, 1200 - 100 - 50.0); // 1050
      expect(controller.dragOffset('item_1').dy, 820 - 100 - 50.0); // 670
    });

    test('clamps scale within allowed minimum (0.4x) and maximum limits', () {
      // Shrink below minimum
      controller.changeScale(item1, -0.8);
      expect(controller.itemScale('item_1'), 0.4);

      // Expand towards maximum
      controller.changeScale(item1, 5.0);
      expect(controller.itemScale('item_1'), lessThanOrEqualTo(2.5));
    });

    test('manages z-order on drag and bringToTop', () {
      controller.bringToTop('item_1');
      expect(controller.renderOrder, ['item_2', 'item_1']);

      controller.startDragging('item_2');
      expect(controller.draggingItemId, 'item_2');
      expect(controller.renderOrder, ['item_1', 'item_2']);

      controller.finishDragging();
      expect(controller.draggingItemId, isNull);
    });

    test(
        'corner resize is proportional, anchored and clamps to available space',
        () {
      controller.resizeFromCorner(item2, const CanvasOffset(75, 100));
      expect(controller.itemScale(item2.id), 1.5);
      expect(controller.dragOffset(item2.id), CanvasOffset.zero);
      controller.resizeFromCorner(item2, const CanvasOffset(-75, -100));
      expect(controller.itemScale(item2.id), 1);
      controller.moveItem(item2, const CanvasOffset(800, 400));
      final anchor = controller.dragOffset(item2.id);
      controller.resizeFromCorner(item2, const CanvasOffset(5000, 5000));
      final exported = controller.generateExportList([item1, item2]).last;
      expect(exported.x + exported.width * exported.scale,
          lessThanOrEqualTo(1200));
      expect(exported.y + exported.height * exported.scale,
          lessThanOrEqualTo(820));
      expect(controller.dragOffset(item2.id), anchor);
      controller.resizeFromCorner(item2, const CanvasOffset(-5000, -5000));
      expect(controller.itemScale(item2.id), 0.4);
      controller.resizeFromCorner(item2, const CanvasOffset(double.nan, 20));
      expect(controller.itemScale(item2.id), 0.4);
    });

    test('resets layout to initial state', () {
      controller.moveItem(item1, const CanvasOffset(100, 100));
      controller.changeScale(item1, 0.5);
      controller.bringToTop('item_1');
      expect(controller.hasCustomLayout, isTrue);

      controller.resetLayout([item1, item2]);
      expect(controller.hasCustomLayout, isFalse);
      expect(controller.dragOffset('item_1'), CanvasOffset.zero);
      expect(controller.itemScale('item_1'), 1.0);
      expect(controller.renderOrder, ['item_1', 'item_2']);
    });

    test('generates PositionedItemExportData accurately', () {
      controller.moveItem(item1, const CanvasOffset(20, 30));
      controller.changeScale(item1, 0.2);

      final exportList = controller.generateExportList([item1, item2]);
      expect(exportList.length, 2);

      final exported1 = exportList.firstWhere((it) => it.item.id == 'item_1');
      expect(exported1.x, 70.0);
      expect(exported1.y, 80.0);
      expect(exported1.scale, 1.2);
    });
  });
}

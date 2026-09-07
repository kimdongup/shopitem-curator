import 'dart:convert';

import 'package:shopitem_curator/core/repositories/item_repository.dart';
import 'package:test/test.dart';

void main() {
  group('DefaultItemRepository manifest validation', () {
    const repository = DefaultItemRepository();

    test('loads a valid manifest', () async {
      final manifest = await repository.loadManifest(_manifestJson());

      expect(manifest.canvasWidth, 1200);
      expect(manifest.canvasHeight, 820);
      expect(manifest.items.single.id, 'item_1');
      expect(manifest.items.single.isPreciselySegmented, isTrue);
    });

    test('preserves an explicit segmentation fallback marker', () async {
      final manifest = await repository.loadManifest(
        _manifestJson(isPreciselySegmented: false),
      );

      expect(manifest.items.single.isPreciselySegmented, isFalse);
    });

    for (final invalidCanvas in <String, (num, num)>{
      'zero width': (0, 820),
      'negative height': (1200, -1),
    }.entries) {
      test('rejects ${invalidCanvas.key}', () async {
        await expectLater(
          repository.loadManifest(
            _manifestJson(
              canvasWidth: invalidCanvas.value.$1,
              canvasHeight: invalidCanvas.value.$2,
            ),
          ),
          throwsA(isA<FormatException>()),
        );
      });
    }

    test('rejects duplicate item ids', () async {
      await expectLater(
        repository.loadManifest(
          _manifestJson(itemIds: const ['duplicate', 'duplicate']),
        ),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('Duplicate item id'),
          ),
        ),
      );
    });

    for (final invalidBounds in <String, (num, num)>{
      'zero-width bounds': (0, 100),
      'negative-height bounds': (100, -1),
    }.entries) {
      test('rejects ${invalidBounds.key}', () async {
        await expectLater(
          repository.loadManifest(
            _manifestJson(
              boundsWidth: invalidBounds.value.$1,
              boundsHeight: invalidBounds.value.$2,
            ),
          ),
          throwsA(isA<FormatException>()),
        );
      });
    }
  });
}

String _manifestJson({
  num canvasWidth = 1200,
  num canvasHeight = 820,
  num boundsWidth = 100,
  num boundsHeight = 100,
  List<String> itemIds = const ['item_1'],
  bool? isPreciselySegmented,
}) {
  return jsonEncode({
    'source_image': 'assets/images/new.jpg',
    'canvas_image': '',
    'canvas_width': canvasWidth,
    'canvas_height': canvasHeight,
    'items': [
      for (final id in itemIds)
        {
          'id': id,
          'name': 'Test item',
          'category': 'test',
          'is_personal': false,
          'quantity': 1,
          'price': 1.0,
          'price_currency': 'USD',
          'description': 'Repository validation fixture',
          'target_url': 'https://www.target.com/p/test/-/A-1',
          'image_url': 'assets/items/test.png',
          'bounds': {
            'x': 0,
            'y': 0,
            'width': boundsWidth,
            'height': boundsHeight,
          },
          'polygon': const [
            [0, 0],
            [100, 0],
            [100, 100],
            [0, 100],
          ],
          'centroid': const [50, 50],
          'is_approved': true,
          if (isPreciselySegmented != null)
            'is_precisely_segmented': isPreciselySegmented,
        },
    ],
  });
}

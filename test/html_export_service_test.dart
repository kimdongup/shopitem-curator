import 'dart:typed_data';

import 'package:shopitem_curator/core/models/curator_item.dart';
import 'package:shopitem_curator/core/services/binary_resource_loader.dart';
import 'package:shopitem_curator/core/services/html_export_service.dart';
import 'package:shopitem_curator/core/services/html_imagemap_exporter.dart';
import 'package:test/test.dart';

void main() {
  test('deduplicates image loads and embeds bytes through a Pure Dart port',
      () async {
    var loadCount = 0;
    final progress = <(int, int)>[];
    final loader = CallbackBinaryResourceLoader((source) async {
      loadCount++;
      expect(source, 'assets/items/shared.png');
      return Uint8List.fromList(const [
        0x89,
        0x50,
        0x4E,
        0x47,
        0x0D,
        0x0A,
        0x1A,
        0x0A,
        0x01,
      ]);
    });
    final service = HtmlExportService(resourceLoader: loader);

    final html = await service.generate(
      canvasWidth: 200,
      canvasHeight: 100,
      items: [
        _exportData(_item('one'), x: 0),
        _exportData(_item('two'), x: 100),
      ],
      onProgress: (completed, total) => progress.add((completed, total)),
    );

    expect(loadCount, 1);
    expect(progress, [(0, 1), (1, 1)]);
    expect(
      RegExp(r'data:image/png;base64,').allMatches(html),
      hasLength(greaterThanOrEqualTo(2)),
    );
  });

  test('one failed image load does not abort the complete export', () async {
    final service = HtmlExportService(
      resourceLoader: CallbackBinaryResourceLoader(
        (_) async => throw StateError('unavailable'),
      ),
    );

    final html = await service.generate(
      canvasWidth: 100,
      canvasHeight: 100,
      items: [_exportData(_item('failed'), x: 0)],
    );

    expect(html, contains('data-item-id="failed"'));
    expect(html, contains('class="image-map-hit-layer"'));
  });
}

CuratorItem _item(String id) => CuratorItem(
      id: id,
      name: 'Item $id',
      category: 'Common',
      isPersonal: false,
      quantity: 1,
      price: 1,
      priceCurrency: 'USD',
      description: 'Description',
      targetUrl: 'https://www.target.com/p/item-$id/-/A-12345678',
      imageUrl: 'assets/items/shared.png',
      bounds: const ItemLayoutBounds(x: 0, y: 0, width: 80, height: 80),
      polygon: const [],
      centroid: const CuratorPoint(40, 40),
    );

PositionedItemExportData _exportData(CuratorItem item, {required double x}) =>
    PositionedItemExportData(
      item: item,
      x: x,
      y: 0,
      width: 80,
      height: 80,
    );

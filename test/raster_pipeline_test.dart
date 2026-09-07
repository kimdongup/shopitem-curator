import 'dart:convert';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:shopitem_curator/core/models/curator_item.dart';
import 'package:shopitem_curator/core/services/binary_resource_loader.dart';
import 'package:shopitem_curator/core/services/canvas_compositor_service.dart';
import 'package:shopitem_curator/core/services/contour_segmenter_service.dart';
import 'package:shopitem_curator/core/services/curation_pipeline_service.dart';
import 'package:shopitem_curator/core/services/demo_item_extraction_gateway.dart';
import 'package:shopitem_curator/core/services/raster_foreground_mask.dart';
import 'package:shopitem_curator/core/services/target_fetcher_service.dart';
import 'package:test/test.dart';

void main() {
  group('Pure Dart raster curation pipeline', () {
    test('compositor returns deterministic, real grayscale PNG bytes',
        () async {
      final imageBytes = _transparentLShapePng();
      final loader = CallbackBinaryResourceLoader(
        (_) async => Uint8List.fromList(imageBytes),
      );
      final service = CanvasCompositorService(resourceLoader: loader);
      final products = [_product()];

      final first = await service.compositeItemsToCanvas(
        products: products,
        sourceImagePath: 'source.jpg',
      );
      final second = await service.compositeItemsToCanvas(
        products: products,
        sourceImagePath: 'source.jpg',
      );

      expect(first.canvasPngBytes, isNotNull);
      expect(
        first.canvasPngBytes!.take(8),
        orderedEquals(const [137, 80, 78, 71, 13, 10, 26, 10]),
      );
      expect(first.canvasPngBytes, orderedEquals(second.canvasPngBytes!));

      final decoded = img.decodePng(first.canvasPngBytes!);
      expect(decoded, isNotNull);
      expect(decoded!.width, 1200);
      expect(decoded.height, 820);

      // The square source is contained in the first 300x420 slot, producing
      // an exact 300x300 destination at (80, 300).
      final placement = first.placedItems.single;
      expect(placement.containBounds!.x, 80);
      expect(placement.containBounds!.y, 300);
      expect(placement.containBounds!.width, 300);
      expect(placement.containBounds!.height, 300);
      expect(placement.imageBytes, isNotNull);
      expect(placement.imageWidth, 8);
      expect(placement.imageHeight, 8);

      final foreground = decoded.getPixel(136, 431);
      expect(foreground.r, lessThan(250));
      expect(foreground.r, closeTo(foreground.g, 1));
      expect(foreground.g, closeTo(foreground.b, 1));

      // Transparent pixels do not paint an item-sized white rectangle over
      // the canvas; they leave the canvas background untouched.
      final transparentCorner = decoded.getPixel(90, 310);
      expect(transparentCorner.r, 255);
      expect(transparentCorner.g, 255);
      expect(transparentCorner.b, 255);
    });

    test('alpha contour preserves an L-shaped concavity and canvas mapping',
        () async {
      final loader = CallbackBinaryResourceLoader(
        (_) async => Uint8List.fromList(_transparentLShapePng()),
      );
      final compositor = CanvasCompositorService(resourceLoader: loader);
      final composite = await compositor.compositeItemsToCanvas(
        products: [_product()],
        sourceImagePath: 'source.jpg',
      );

      final items = await const ContourSegmenterService()
          .segmentPlacedItems(composite.placedItems);
      final item = items.single;

      expect(item.isPreciselySegmented, isTrue);
      expect(item.polygon.length, greaterThanOrEqualTo(6));
      final minX =
          item.polygon.map((point) => point.x).reduce((a, b) => a < b ? a : b);
      final maxX =
          item.polygon.map((point) => point.x).reduce((a, b) => a > b ? a : b);
      final minY =
          item.polygon.map((point) => point.y).reduce((a, b) => a < b ? a : b);
      final maxY =
          item.polygon.map((point) => point.y).reduce((a, b) => a > b ? a : b);

      expect(minX, closeTo(117.5, 0.001));
      expect(maxX, closeTo(342.5, 0.001));
      expect(minY, closeTo(337.5, 0.001));
      expect(maxY, closeTo(562.5, 0.001));

      final polygonArea = _polygonArea(item.polygon).abs();
      final boundingArea = (maxX - minX) * (maxY - minY);
      expect(polygonArea / boundingArea, closeTo(20 / 36, 0.02));
      expect(item.centroid.x, closeTo(200, 0.001));
      expect(item.centroid.y, closeTo(480, 0.001));
    });

    test('opaque JPEG uses edge background flood fill before contouring',
        () async {
      const bounds = ItemLayoutBounds(x: 10, y: 20, width: 160, height: 160);
      final placement = PlacedTargetItem(
        product: _product(),
        bounds: bounds,
        containBounds: bounds,
        imageBytes: _opaqueLShapeJpeg(),
        imageWidth: 16,
        imageHeight: 16,
      );
      final item = (await const ContourSegmenterService()
              .segmentPlacedItems([placement]))
          .single;

      final minX =
          item.polygon.map((point) => point.x).reduce((a, b) => a < b ? a : b);
      final maxX =
          item.polygon.map((point) => point.x).reduce((a, b) => a > b ? a : b);
      final minY =
          item.polygon.map((point) => point.y).reduce((a, b) => a < b ? a : b);
      final maxY =
          item.polygon.map((point) => point.y).reduce((a, b) => a > b ? a : b);
      final areaRatio =
          _polygonArea(item.polygon).abs() / ((maxX - minX) * (maxY - minY));

      expect(item.polygon.length, greaterThan(4));
      expect(areaRatio, lessThan(0.85));
    });

    test('RGBA alpha noise does not disable opaque background flood fill', () {
      final image = img.Image(width: 16, height: 16, numChannels: 4);
      img.fill(image, color: img.ColorRgba8(255, 255, 255, 255));
      for (var y = 4; y <= 11; y++) {
        for (var x = 4; x <= 6; x++) {
          image.setPixelRgba(x, y, 20, 50, 220, 255);
        }
      }
      // Nominally opaque RGBA encoders can produce a near-opaque fringe.
      image.setPixelRgba(0, 0, 255, 255, 255, 254);

      final mask = RasterForegroundMask.fromImage(image);

      expect(mask.usesSourceAlpha, isFalse);
      expect(mask.isForeground(1, 1), isFalse);
      expect(mask.isForeground(5, 7), isTrue);
    });

    test('single-pixel foreground remains a four-point contour after RDP',
        () async {
      final image = img.Image(width: 3, height: 3, numChannels: 4);
      img.fill(image, color: img.ColorRgba8(0, 0, 0, 0));
      image.setPixelRgba(1, 1, 255, 0, 0, 255);
      const bounds = ItemLayoutBounds(x: 0, y: 0, width: 30, height: 30);
      final placement = PlacedTargetItem(
        product: _product(),
        bounds: bounds,
        containBounds: bounds,
        imageBytes: Uint8List.fromList(img.encodePng(image)),
        imageWidth: 3,
        imageHeight: 3,
      );

      final item = (await const ContourSegmenterService()
              .segmentPlacedItems([placement]))
          .single;

      expect(item.polygon, hasLength(4));
      expect(item.centroid.x, closeTo(15, 0.001));
      expect(item.centroid.y, closeTo(15, 0.001));
    });

    test('retains every disconnected foreground contour and global centroid',
        () async {
      final image = img.Image(width: 10, height: 10, numChannels: 4);
      img.fill(image, color: img.ColorRgba8(0, 0, 0, 0));
      for (var y = 1; y <= 3; y++) {
        for (var x = 1; x <= 2; x++) {
          image.setPixelRgba(x, y, 255, 0, 0, 255);
        }
      }
      image.setPixelRgba(8, 8, 0, 0, 255, 255);
      const bounds = ItemLayoutBounds(x: 0, y: 0, width: 100, height: 100);
      final placement = PlacedTargetItem(
        product: _product(),
        bounds: bounds,
        containBounds: bounds,
        imageBytes: Uint8List.fromList(img.encodePng(image)),
        imageWidth: 10,
        imageHeight: 10,
      );

      final item = (await const ContourSegmenterService()
              .segmentPlacedItems([placement]))
          .single;

      expect(item.contours, hasLength(2));
      expect(item.contours.every((contour) => contour.length >= 4), isTrue);
      expect(
        item.polygon.map((point) => point.toJson()).toList(),
        equals(item.contours.first.map((point) => point.toJson()).toList()),
      );
      expect(
        _polygonArea(item.contours.first).abs(),
        greaterThan(_polygonArea(item.contours.last).abs()),
      );
      // Six pixels in the large component and one distant pixel contribute
      // to the anchor, instead of anchoring only to the largest component.
      expect(item.centroid.x, closeTo(29.2857, 0.001));
      expect(item.centroid.y, closeTo(33.5714, 0.001));
    });

    test('uniform opaque raster is retained when no background is separable',
        () {
      final image = img.Image(width: 4, height: 4, numChannels: 3);
      img.fill(image, color: img.ColorRgb8(255, 255, 255));

      final mask = RasterForegroundMask.fromImage(image);

      for (var y = 0; y < image.height; y++) {
        for (var x = 0; x < image.width; x++) {
          expect(mask.isForeground(x, y), isTrue);
        }
      }
    });

    test('pipeline exposes only generated PNG bytes as a data URI', () async {
      final loader = CallbackBinaryResourceLoader(
        (_) async => Uint8List.fromList(_transparentLShapePng()),
      );
      final targetFetcher = TargetFetcherService();
      addTearDown(targetFetcher.close);
      final pipeline = CurationPipelineService(
        ocrService: const DemoItemExtractionGateway(),
        targetFetcherService: targetFetcher,
        resourceLoader: loader,
      );

      final manifest = await pipeline.runPipeline(
        sourceImagePath: 'assets/images/new.jpg',
      );

      const prefix = 'data:image/png;base64,';
      expect(manifest.canvasImage, startsWith(prefix));
      final decodedBytes =
          base64Decode(manifest.canvasImage.substring(prefix.length));
      expect(
        decodedBytes.take(8),
        orderedEquals(const [137, 80, 78, 71, 13, 10, 26, 10]),
      );
      expect(manifest.items, hasLength(3));
      expect(manifest.items.every((item) => item.polygon.length >= 6), isTrue);
    });

    test('missing loader preserves the original layout-only fallback',
        () async {
      const compositor = CanvasCompositorService();
      final result = await compositor.compositeItemsToCanvas(
        products: [_product()],
        sourceImagePath: 'source.jpg',
      );

      expect(result.canvasPngBytes, isNull);
      expect(result.placedItems.single.imageBytes, isNull);
      expect(result.placedItems.single.renderedBounds,
          same(result.placedItems.single.bounds));

      final fallbackItem = (await const ContourSegmenterService()
              .segmentPlacedItems(result.placedItems))
          .single;
      expect(fallbackItem.isPreciselySegmented, isFalse);
    });

    test('one undecodable item disables the partial flattened canvas',
        () async {
      final validBytes = Uint8List.fromList(_transparentLShapePng());
      final loader = CallbackBinaryResourceLoader(
        (source) async => source == 'memory://valid'
            ? validBytes
            : Uint8List.fromList(const [0x00, 0x01, 0x02]),
      );
      final compositor = CanvasCompositorService(resourceLoader: loader);

      final result = await compositor.compositeItemsToCanvas(
        products: [
          _product(id: 'valid', imageUrl: 'memory://valid'),
          _product(id: 'corrupt', imageUrl: 'memory://corrupt'),
        ],
        sourceImagePath: 'source.jpg',
      );

      expect(result.placedItems, hasLength(2));
      expect(result.placedItems.first.imageBytes, isNotNull);
      expect(result.placedItems.last.imageBytes, isNull);
      expect(
        result.canvasPngBytes,
        isNull,
        reason: 'A partial flattened layer would make the failed item vanish.',
      );
    });
  });
}

TargetProductData _product({
  String id = 'item_l',
  String imageUrl = 'memory://l-shape',
}) {
  return TargetProductData(
    id: id,
    name: 'L-shaped product',
    category: 'test',
    isPersonal: false,
    quantity: 1,
    price: 1,
    priceCurrency: 'USD',
    description: 'Synthetic product',
    targetUrl: 'https://www.target.com/p/test/-/A-1',
    imageUrl: imageUrl,
  );
}

Uint8List _transparentLShapePng() {
  final image = img.Image(width: 8, height: 8, numChannels: 4);
  img.fill(image, color: img.ColorRgba8(0, 0, 0, 0));
  for (var y = 1; y <= 6; y++) {
    for (var x = 1; x <= 2; x++) {
      image.setPixelRgba(x, y, 240, 30, 20, 255);
    }
  }
  for (var y = 5; y <= 6; y++) {
    for (var x = 1; x <= 6; x++) {
      image.setPixelRgba(x, y, 240, 30, 20, 255);
    }
  }
  return Uint8List.fromList(img.encodePng(image));
}

Uint8List _opaqueLShapeJpeg() {
  final image = img.Image(width: 16, height: 16, numChannels: 3);
  img.fill(image, color: img.ColorRgb8(255, 255, 255));
  for (var y = 3; y <= 12; y++) {
    for (var x = 3; x <= 5; x++) {
      image.setPixelRgb(x, y, 20, 50, 220);
    }
  }
  for (var y = 10; y <= 12; y++) {
    for (var x = 3; x <= 12; x++) {
      image.setPixelRgb(x, y, 20, 50, 220);
    }
  }
  return Uint8List.fromList(img.encodeJpg(image, quality: 100));
}

double _polygonArea(List<CuratorPoint> polygon) {
  var areaTwice = 0.0;
  for (var i = 0; i < polygon.length; i++) {
    final current = polygon[i];
    final next = polygon[(i + 1) % polygon.length];
    areaTwice += (current.x * next.y) - (next.x * current.y);
  }
  return areaTwice / 2;
}

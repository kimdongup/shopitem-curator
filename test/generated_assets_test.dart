import 'dart:io';

import 'package:image/image.dart' as img;
import 'package:shopitem_curator/core/models/curator_item.dart';
import 'package:shopitem_curator/core/models/target_purchase_url.dart';
import 'package:shopitem_curator/core/repositories/item_repository.dart';
import 'package:test/test.dart';

void main() {
  const generatedAssets = <String, int>{
    'assets/items/manifest_new.json': 3,
    'assets/items/manifest_media_1787068853075.json': 25,
  };

  test('public bundle includes only reviewed sample manifests and their assets',
      () async {
    final expected = <String>{...generatedAssets.keys};
    for (final path in generatedAssets.keys) {
      final manifest = await const DefaultItemRepository()
          .loadManifest(await File(path).readAsString());
      expected.addAll([
        manifest.sourceImage,
        manifest.canvasImage,
        ...manifest.items.map((item) => item.imageUrl),
      ]);
    }
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final bundled = RegExp(r'^    - (assets/[^\r\n]+)$', multiLine: true)
        .allMatches(pubspec)
        .map((match) => match.group(1)!)
        .toSet();
    expect(bundled, expected);
    final ignore = File('.gitignore').readAsLinesSync();
    expect(
        ignore,
        containsAll([
          '/assets/images/*',
          '/assets/items/*',
          '/assets/.document_trash/',
          '/shopitem_curator_map.html',
          '.env',
        ]));
    for (final path in bundled) {
      expect(ignore, contains('!/$path'));
      expect(File(path).existsSync(), isTrue);
    }
  });

  for (final entry in generatedAssets.entries) {
    test('${entry.key} contains complete, renderable product data', () async {
      final manifest = await const DefaultItemRepository().loadManifest(
        await File(entry.key).readAsString(),
      );

      expect(manifest.items, hasLength(entry.value));
      expect(manifest.canvasImage, startsWith('assets/items/canvas_'));
      expect(
          manifest.items,
          everyElement(predicate<CuratorItem>((item) {
            return item.polygon.length >= 3 &&
                item.contours.isNotEmpty &&
                item.contours.every((contour) => contour.length >= 3) &&
                TargetPurchaseUrl.isValid(item.targetUrl);
          }, 'has silhouettes and a validated Target PDP URL')));

      final canvasBytes = await File(manifest.canvasImage).readAsBytes();
      final canvas = img.decodePng(canvasBytes);
      expect(canvas, isNotNull);
      expect(canvas!.width, manifest.canvasWidth.round());
      expect(canvas.height, manifest.canvasHeight.round());

      // The persisted base layer must truly be grayscale; color is supplied
      // only by the clipped hover/touch overlay at runtime.
      for (var y = 0; y < canvas.height; y += 7) {
        for (var x = 0; x < canvas.width; x += 7) {
          final pixel = canvas.getPixel(x, y);
          expect(pixel.r, pixel.g);
          expect(pixel.g, pixel.b);
        }
      }
    });
  }
}

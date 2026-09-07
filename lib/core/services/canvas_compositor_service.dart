// Pure Dart Service (Zero Flutter Dependencies)

import 'dart:math';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import '../contracts/catalog_gateways.dart';
import '../models/curator_item.dart';
import 'binary_resource_loader.dart';
import 'raster_foreground_mask.dart';

class PlacedTargetItem {
  const PlacedTargetItem({
    required this.product,
    required this.bounds,
    this.containBounds,
    this.imageBytes,
    this.imageWidth,
    this.imageHeight,
    this.foregroundMask,
  });

  final TargetProductData product;

  /// The layout slot allocated by the organic placement algorithm.
  final ItemLayoutBounds bounds;

  /// The exact aspect-preserving destination rectangle inside [bounds].
  ///
  /// It equals [bounds] when the resource cannot be loaded or decoded.
  final ItemLayoutBounds? containBounds;

  /// Normalized RGBA PNG bytes used by both compositing and segmentation.
  /// Background pixels have already been made transparent.
  final Uint8List? imageBytes;
  final int? imageWidth;
  final int? imageHeight;

  /// Precomputed foreground mask to avoid redundant decoding during contour segmentation.
  final RasterForegroundMask? foregroundMask;

  ItemLayoutBounds get renderedBounds => containBounds ?? bounds;
  bool get hasDecodedImage =>
      imageBytes != null && imageWidth != null && imageHeight != null;
}

class DynamicCanvasLayoutResult {
  const DynamicCanvasLayoutResult({
    required this.canvasWidth,
    required this.canvasHeight,
    required this.placedItems,
    this.canvasPngBytes,
  });

  final double canvasWidth;
  final double canvasHeight;
  final List<PlacedTargetItem> placedItems;

  /// Flattened grayscale PNG generated from all successfully decoded items.
  ///
  /// This remains null when no loader is configured or no image can be
  /// decoded, preserving the pre-existing layout-only fallback behaviour.
  final Uint8List? canvasPngBytes;
}

/// Computes an organic layout and, when a [BinaryResourceLoader] is supplied,
/// decodes and alpha-composites the placed product images into one PNG.
class CanvasCompositorService {
  const CanvasCompositorService({
    this.resourceLoader,
    this.canvasWidth = 1200.0,
    this.canvasHeight = 820.0,
  })  : assert(canvasWidth > 0),
        assert(canvasHeight > 0);

  final BinaryResourceLoader? resourceLoader;
  final double canvasWidth;
  final double canvasHeight;

  Future<DynamicCanvasLayoutResult> compositeItemsToCanvas({
    required List<TargetProductData> products,
    required String sourceImagePath,
  }) async {
    final slots = _computeLayoutSlots(products.length);
    final loader = resourceLoader;

    if (loader == null) {
      return DynamicCanvasLayoutResult(
        canvasWidth: canvasWidth,
        canvasHeight: canvasHeight,
        placedItems: [
          for (var i = 0; i < products.length; i++)
            PlacedTargetItem(product: products[i], bounds: slots[i]),
        ],
      );
    }

    // Decode and composite sequentially. This bounds peak memory for a large
    // checklist while retaining deterministic product/z-order.
    final placedItems = <PlacedTargetItem>[];
    img.Image? canvas;
    var allImagesDecoded = true;
    for (var i = 0; i < products.length; i++) {
      final prepared = await _loadAndPrepare(products[i], slots[i], loader);
      placedItems.add(prepared.placed);
      final raster = prepared.raster;
      if (raster == null) {
        allImagesDecoded = false;
        continue;
      }

      canvas ??= _createCanvas();
      final destination = prepared.placed.renderedBounds;
      final resized = img.copyResize(
        raster,
        width: destination.width.round(),
        height: destination.height.round(),
        interpolation: img.Interpolation.average,
      );
      img.grayscale(resized);
      img.compositeImage(
        canvas,
        resized,
        dstX: destination.x.round(),
        dstY: destination.y.round(),
      );
    }

    return DynamicCanvasLayoutResult(
      canvasWidth: canvasWidth,
      canvasHeight: canvasHeight,
      placedItems: placedItems,
      // A partial flattened layer would hide every failed item in the normal
      // inactive state. Fall back to individual UI layers unless all product
      // images participated in the composite.
      canvasPngBytes: !allImagesDecoded || canvas == null
          ? null
          : Uint8List.fromList(img.encodePng(canvas)),
    );
  }

  img.Image _createCanvas() {
    final canvas = img.Image(
      width: canvasWidth.round(),
      height: canvasHeight.round(),
      numChannels: 4,
    );
    return img.fill(canvas, color: img.ColorRgba8(255, 255, 255, 255));
  }

  Future<_PreparedPlacement> _loadAndPrepare(
    TargetProductData product,
    ItemLayoutBounds slot,
    BinaryResourceLoader loader,
  ) async {
    try {
      final sourceBytes = await loader.load(product.imageUrl);
      final decodedSource = img.decodeImage(sourceBytes);
      if (decodedSource == null ||
          decodedSource.width == 0 ||
          decodedSource.height == 0) {
        return _PreparedPlacement(
          placed: PlacedTargetItem(product: product, bounds: slot),
        );
      }

      final decoded = img.bakeOrientation(decodedSource);
      final mask = RasterForegroundMask.fromImage(decoded);
      final raster = mask.applyTo(decoded);
      final destination = _containRect(
        slot: slot,
        sourceWidth: raster.width,
        sourceHeight: raster.height,
      );
      final normalizedBytes = Uint8List.fromList(img.encodePng(raster));

      return _PreparedPlacement(
        placed: PlacedTargetItem(
          product: product,
          bounds: slot,
          containBounds: destination,
          imageBytes: normalizedBytes,
          imageWidth: raster.width,
          imageHeight: raster.height,
          foregroundMask: mask,
        ),
        raster: raster,
      );
    } catch (_) {
      // Loading is an optional enhancement. A missing/corrupt resource must
      // not break the existing layout-only pipeline.
      return _PreparedPlacement(
        placed: PlacedTargetItem(product: product, bounds: slot),
      );
    }
  }

  ItemLayoutBounds _containRect({
    required ItemLayoutBounds slot,
    required int sourceWidth,
    required int sourceHeight,
  }) {
    final scale = min(
      slot.width / sourceWidth,
      slot.height / sourceHeight,
    );
    final destinationWidth =
        max(1, min(slot.width.floor(), (sourceWidth * scale).round()));
    final destinationHeight =
        max(1, min(slot.height.floor(), (sourceHeight * scale).round()));
    final destinationX =
        (slot.x + ((slot.width - destinationWidth) / 2)).round();
    final destinationY =
        (slot.y + ((slot.height - destinationHeight) / 2)).round();

    return ItemLayoutBounds(
      x: destinationX.toDouble(),
      y: destinationY.toDouble(),
      width: destinationWidth.toDouble(),
      height: destinationHeight.toDouble(),
    );
  }

  List<ItemLayoutBounds> _computeLayoutSlots(int itemCount) {
    final placed = <ItemLayoutBounds>[];
    final rng = Random(42);

    if (itemCount <= 3) {
      final layouts = [
        ItemLayoutBounds(
          x: canvasWidth * (80 / 1200),
          y: canvasHeight * (240 / 820),
          width: canvasWidth * (300 / 1200),
          height: canvasHeight * (420 / 820),
        ),
        ItemLayoutBounds(
          x: canvasWidth * (390 / 1200),
          y: canvasHeight * (90 / 820),
          width: canvasWidth * (380 / 1200),
          height: canvasHeight * (520 / 820),
        ),
        ItemLayoutBounds(
          x: canvasWidth * (780 / 1200),
          y: canvasHeight * (260 / 820),
          width: canvasWidth * (310 / 1200),
          height: canvasHeight * (400 / 820),
        ),
      ];
      for (var i = 0; i < itemCount; i++) {
        placed.add(
          i < layouts.length
              ? layouts[i]
              : _randomBounds(rng, canvasWidth, canvasHeight),
        );
      }
      return placed;
    }

    // Scale the grid with the item count. The previous fixed 4x3 zones wrapped
    // after item 12, so a 25-item checklist placed multiple products in the
    // same cells. Each item now owns a non-overlapping cell while small size
    // and alignment variations retain an organic collage feel.
    final columns = max(
      2,
      min(
        itemCount,
        sqrt(itemCount * (canvasWidth / canvasHeight)).floor(),
      ),
    );
    final rows = (itemCount / columns).ceil();
    final cellWidth = canvasWidth / columns;
    final cellHeight = canvasHeight / rows;
    final baseSize = min(cellWidth, cellHeight);

    for (var i = 0; i < itemCount; i++) {
      final row = i ~/ columns;
      final column = i % columns;
      final itemsInRow = min(columns, itemCount - (row * columns));
      final rowOffset = (canvasWidth - (itemsInRow * cellWidth)) / 2;
      final itemSize = baseSize * (0.68 + (rng.nextDouble() * 0.10));
      final freeX = cellWidth - itemSize;
      final freeY = cellHeight - itemSize;
      final x = rowOffset +
          (column * cellWidth) +
          (freeX * (0.35 + (rng.nextDouble() * 0.30)));
      final y =
          (row * cellHeight) + (freeY * (0.35 + (rng.nextDouble() * 0.30)));

      placed.add(
        ItemLayoutBounds(
          x: x,
          y: y,
          width: itemSize,
          height: itemSize,
        ),
      );
    }
    return placed;
  }

  ItemLayoutBounds _randomBounds(
    Random rng,
    double targetCanvasWidth,
    double targetCanvasHeight,
  ) {
    final width = 180 * (targetCanvasWidth / 1200);
    final height = 200 * (targetCanvasHeight / 820);
    return ItemLayoutBounds(
      x: rng.nextDouble() * (targetCanvasWidth - width),
      y: rng.nextDouble() * (targetCanvasHeight - height),
      width: width,
      height: height,
    );
  }
}

final class _PreparedPlacement {
  const _PreparedPlacement({required this.placed, this.raster});

  final PlacedTargetItem placed;
  final img.Image? raster;
}

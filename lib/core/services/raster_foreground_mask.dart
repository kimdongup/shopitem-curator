// Pure Dart Raster Utility (Zero Flutter Dependencies)

import 'dart:collection';

import 'package:image/image.dart' as img;

/// Binary foreground mask shared by compositing and contour extraction.
///
/// Images with useful transparency use their alpha channel directly. Fully
/// opaque images (notably JPEG product photos) use an edge-connected flood
/// fill, comparing pixels with the median border colour and near-white.
final class RasterForegroundMask {
  RasterForegroundMask._({
    required this.width,
    required this.height,
    required List<bool> foreground,
    required this.usesSourceAlpha,
  }) : _foreground = foreground;

  final int width;
  final int height;
  final List<bool> _foreground;
  final bool usesSourceAlpha;

  bool get isEmpty => !_foreground.any((value) => value);

  bool isForeground(int x, int y) {
    if (x < 0 || x >= width || y < 0 || y >= height) return false;
    return _foreground[(y * width) + x];
  }

  factory RasterForegroundMask.fromImage(
    img.Image image, {
    int alphaThreshold = 16,
    int backgroundTolerance = 42,
    int nearWhiteThreshold = 238,
  }) {
    assert(alphaThreshold >= 0 && alphaThreshold <= 255);
    assert(backgroundTolerance >= 0);
    assert(nearWhiteThreshold >= 0 && nearWhiteThreshold <= 255);

    final width = image.width;
    final height = image.height;
    final foreground = List<bool>.filled(width * height, false);
    if (width == 0 || height == 0) {
      return RasterForegroundMask._(
        width: width,
        height: height,
        foreground: foreground,
        usesSourceAlpha: false,
      );
    }

    final effectiveAlphaThreshold = alphaThreshold < 1 ? 1 : alphaThreshold;
    var transparentPixelCount = 0;
    for (final pixel in image) {
      if ((pixel.aNormalized * 255).round() < effectiveAlphaThreshold) {
        transparentPixelCount++;
      }
    }
    final minimumTransparentPixels =
        ((width * height) * 0.001).ceil().clamp(1, width * height);
    final hasUsefulTransparency =
        transparentPixelCount >= minimumTransparentPixels;

    if (hasUsefulTransparency) {
      for (final pixel in image) {
        foreground[(pixel.y * width) + pixel.x] =
            (pixel.aNormalized * 255) >= effectiveAlphaThreshold;
      }
      return RasterForegroundMask._(
        width: width,
        height: height,
        foreground: foreground,
        usesSourceAlpha: true,
      );
    }

    final borderColours = <(int, int, int)>[];
    for (var x = 0; x < width; x++) {
      final top = image.getPixel(x, 0);
      borderColours.add((top.r.toInt(), top.g.toInt(), top.b.toInt()));
      if (height > 1) {
        final bottom = image.getPixel(x, height - 1);
        borderColours
            .add((bottom.r.toInt(), bottom.g.toInt(), bottom.b.toInt()));
      }
    }
    for (var y = 1; y < height - 1; y++) {
      final left = image.getPixel(0, y);
      borderColours.add((left.r.toInt(), left.g.toInt(), left.b.toInt()));
      if (width > 1) {
        final right = image.getPixel(width - 1, y);
        borderColours.add((right.r.toInt(), right.g.toInt(), right.b.toInt()));
      }
    }

    int median(Iterable<int> values) {
      final sorted = values.toList()..sort();
      return sorted[sorted.length ~/ 2];
    }

    final backgroundR = median(borderColours.map((colour) => colour.$1));
    final backgroundG = median(borderColours.map((colour) => colour.$2));
    final backgroundB = median(borderColours.map((colour) => colour.$3));
    final toleranceSquared = backgroundTolerance * backgroundTolerance;

    bool resemblesBackground(int x, int y) {
      final pixel = image.getPixel(x, y);
      final r = pixel.r.toInt();
      final g = pixel.g.toInt();
      final b = pixel.b.toInt();
      final dr = r - backgroundR;
      final dg = g - backgroundG;
      final db = b - backgroundB;
      final distanceSquared = (dr * dr) + (dg * dg) + (db * db);
      final nearWhite = r >= nearWhiteThreshold &&
          g >= nearWhiteThreshold &&
          b >= nearWhiteThreshold;
      return distanceSquared <= toleranceSquared || nearWhite;
    }

    final background = List<bool>.filled(width * height, false);
    final queue = ListQueue<int>();

    void enqueueIfBackground(int x, int y) {
      final index = (y * width) + x;
      if (background[index] || !resemblesBackground(x, y)) return;
      background[index] = true;
      queue.add(index);
    }

    for (var x = 0; x < width; x++) {
      enqueueIfBackground(x, 0);
      if (height > 1) enqueueIfBackground(x, height - 1);
    }
    for (var y = 1; y < height - 1; y++) {
      enqueueIfBackground(0, y);
      if (width > 1) enqueueIfBackground(width - 1, y);
    }

    const neighbours = <(int, int)>[(1, 0), (-1, 0), (0, 1), (0, -1)];
    while (queue.isNotEmpty) {
      final index = queue.removeFirst();
      final x = index % width;
      final y = index ~/ width;
      for (final neighbour in neighbours) {
        final nx = x + neighbour.$1;
        final ny = y + neighbour.$2;
        if (nx < 0 || nx >= width || ny < 0 || ny >= height) continue;
        enqueueIfBackground(nx, ny);
      }
    }

    for (var i = 0; i < foreground.length; i++) {
      foreground[i] = !background[i];
    }

    // A uniform opaque image has no distinguishable edge background. Keeping
    // the full raster is safer than silently making the product disappear.
    if (!foreground.any((value) => value)) {
      foreground.fillRange(0, foreground.length, true);
      return RasterForegroundMask._(
        width: width,
        height: height,
        foreground: foreground,
        usesSourceAlpha: false,
      );
    }

    return RasterForegroundMask._(
      width: width,
      height: height,
      foreground: foreground,
      usesSourceAlpha: false,
    );
  }

  /// Returns an RGBA copy with all classified background pixels transparent.
  img.Image applyTo(img.Image source) {
    final result = source.convert(numChannels: 4);
    for (final pixel in result) {
      if (!isForeground(pixel.x, pixel.y)) {
        pixel.a = 0;
      }
    }
    return result;
  }
}

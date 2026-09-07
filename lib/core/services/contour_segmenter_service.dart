// Pure Dart Service (Zero Flutter Dependencies)

import 'dart:math';

import 'package:image/image.dart' as img;

import '../models/curator_item.dart';
import 'canvas_compositor_service.dart';
import 'raster_foreground_mask.dart';

/// Extracts a pixel-derived silhouette from each placed product image.
///
/// Transparent images are segmented by alpha. Fully opaque images use the
/// edge-background flood-fill fallback implemented by [RasterForegroundMask].
class ContourSegmenterService {
  const ContourSegmenterService({
    this.alphaThreshold = 16,
    this.simplificationTolerance = 1.25,
    this.minimumContourAreaRatio = 0.001,
  })  : assert(alphaThreshold >= 0 && alphaThreshold <= 255),
        assert(simplificationTolerance >= 0),
        assert(minimumContourAreaRatio >= 0 && minimumContourAreaRatio < 1);

  final int alphaThreshold;

  /// Ramer-Douglas-Peucker tolerance measured in source-image pixels.
  final double simplificationTolerance;

  /// Drops antialiasing/shadow speckles relative to the primary component
  /// while retaining meaningful disconnected pieces of a product.
  final double minimumContourAreaRatio;

  Future<List<CuratorItem>> segmentPlacedItems(
    List<PlacedTargetItem> placedItems,
  ) async {
    final curatedItems = <CuratorItem>[];

    for (final placed in placedItems) {
      final product = placed.product;
      final bounds = placed.renderedBounds;
      final segmentation = _segment(placed, bounds);

      curatedItems.add(
        CuratorItem(
          id: product.id,
          name: product.name,
          category: product.category,
          isPersonal: product.isPersonal,
          quantity: product.quantity,
          price: product.price,
          priceCurrency: product.priceCurrency,
          description: product.description,
          targetUrl: product.targetUrl,
          imageUrl: product.imageUrl,
          bounds: bounds,
          polygon: segmentation.polygon,
          contours: segmentation.contours,
          centroid: segmentation.centroid,
          isPreciselySegmented: segmentation.isPrecise,
        ),
      );
    }

    return curatedItems;
  }

  _SegmentationResult _segment(
    PlacedTargetItem placed,
    ItemLayoutBounds bounds,
  ) {
    final precomputedMask = placed.foregroundMask;
    if (precomputedMask != null && !precomputedMask.isEmpty) {
      final loops = _traceBoundaryLoops(precomputedMask);
      if (loops.isNotEmpty) {
        return _buildSegmentationFromLoops(loops, precomputedMask, bounds);
      }
    }

    final bytes = placed.imageBytes;
    if (bytes == null || bytes.isEmpty) return _fallback(bounds);

    try {
      final decodedSource = img.decodeImage(bytes);
      if (decodedSource == null ||
          decodedSource.width == 0 ||
          decodedSource.height == 0) {
        return _fallback(bounds);
      }

      final decoded = img.bakeOrientation(decodedSource);
      final mask = RasterForegroundMask.fromImage(
        decoded,
        alphaThreshold: alphaThreshold,
      );
      if (mask.isEmpty) return _fallback(bounds);

      final loops = _traceBoundaryLoops(mask);
      if (loops.isEmpty) return _fallback(bounds);

      return _buildSegmentationFromLoops(loops, mask, bounds);
    } catch (_) {
      return _fallback(bounds);
    }
  }

  _SegmentationResult _buildSegmentationFromLoops(
    List<List<_RasterPoint>> loops,
    RasterForegroundMask mask,
    ItemLayoutBounds bounds,
  ) {
    loops.sort(
      (a, b) => _signedArea(b).abs().compareTo(_signedArea(a).abs()),
    );
    final minimumArea = max(
      1.0,
      _signedArea(loops.first).abs() * minimumContourAreaRatio,
    );
    loops.removeWhere((loop) => _signedArea(loop).abs() < minimumArea);
    final contours = <List<CuratorPoint>>[
      for (final loop in loops)
        [
          for (final point in _displayLoop(loop))
            _mapToCanvas(
              point,
              sourceWidth: mask.width,
              sourceHeight: mask.height,
              bounds: bounds,
            ),
        ],
    ];
    if (contours.isEmpty) return _fallback(bounds);

    final sourceCentroid = _foregroundCentroid(mask);
    final centroid = _mapToCanvas(
      sourceCentroid,
      sourceWidth: mask.width,
      sourceHeight: mask.height,
      bounds: bounds,
    );

    return _SegmentationResult(
      polygon: contours.first,
      contours: contours,
      centroid: centroid,
      isPrecise: true,
    );
  }

  List<_RasterPoint> _displayLoop(List<_RasterPoint> loop) {
    final simplified = _simplifyClosed(loop, simplificationTolerance);
    return simplified.length >= 3 ? simplified : loop;
  }

  _RasterPoint _foregroundCentroid(RasterForegroundMask mask) {
    var foregroundCount = 0;
    var xTotal = 0.0;
    var yTotal = 0.0;
    for (var y = 0; y < mask.height; y++) {
      for (var x = 0; x < mask.width; x++) {
        if (!mask.isForeground(x, y)) continue;
        foregroundCount++;
        xTotal += x + 0.5;
        yTotal += y + 0.5;
      }
    }
    if (foregroundCount == 0) return const _RasterPoint(0, 0);
    return _RasterPoint(
      xTotal / foregroundCount,
      yTotal / foregroundCount,
    );
  }

  List<List<_RasterPoint>> _traceBoundaryLoops(RasterForegroundMask mask) {
    final vertexStride = mask.width + 1;
    final edges = <_BoundaryEdge>[];
    final outgoing = <int, List<int>>{};

    int vertexKey(int x, int y) => (y * vertexStride) + x;

    void addEdge(
      int startX,
      int startY,
      int endX,
      int endY,
      int direction,
    ) {
      final edge = _BoundaryEdge(
        start: vertexKey(startX, startY),
        end: vertexKey(endX, endY),
        direction: direction,
      );
      final edgeIndex = edges.length;
      edges.add(edge);
      outgoing.putIfAbsent(edge.start, () => <int>[]).add(edgeIndex);
    }

    for (var y = 0; y < mask.height; y++) {
      for (var x = 0; x < mask.width; x++) {
        if (!mask.isForeground(x, y)) continue;
        if (!mask.isForeground(x, y - 1)) {
          addEdge(x, y, x + 1, y, 0);
        }
        if (!mask.isForeground(x + 1, y)) {
          addEdge(x + 1, y, x + 1, y + 1, 1);
        }
        if (!mask.isForeground(x, y + 1)) {
          addEdge(x + 1, y + 1, x, y + 1, 2);
        }
        if (!mask.isForeground(x - 1, y)) {
          addEdge(x, y + 1, x, y, 3);
        }
      }
    }

    final used = List<bool>.filled(edges.length, false);
    final loops = <List<_RasterPoint>>[];

    for (var initialIndex = 0; initialIndex < edges.length; initialIndex++) {
      if (used[initialIndex]) continue;

      final initial = edges[initialIndex];
      var currentIndex = initialIndex;
      var current = initial;
      final loop = <_RasterPoint>[
        _pointFromKey(initial.start, vertexStride),
      ];
      var closed = false;

      for (var guard = 0; guard <= edges.length; guard++) {
        if (used[currentIndex]) break;
        used[currentIndex] = true;
        loop.add(_pointFromKey(current.end, vertexStride));

        if (current.end == initial.start) {
          closed = true;
          break;
        }

        final candidates = (outgoing[current.end] ?? const <int>[])
            .where((index) => !used[index])
            .toList(growable: false);
        if (candidates.isEmpty) break;

        candidates.sort((a, b) {
          final aRank = _turnRank(
            current.direction,
            edges[a].direction,
          );
          final bRank = _turnRank(
            current.direction,
            edges[b].direction,
          );
          return aRank.compareTo(bRank);
        });
        currentIndex = candidates.first;
        current = edges[currentIndex];
      }

      if (closed && loop.length >= 4) {
        if (loop.first == loop.last) loop.removeLast();
        final compact = _removeCollinear(loop);
        if (compact.length >= 3) loops.add(compact);
      }
    }

    return loops;
  }

  int _turnRank(int fromDirection, int toDirection) {
    final clockwiseTurn = (toDirection - fromDirection + 4) % 4;
    return switch (clockwiseTurn) {
      1 => 0, // keep foreground on the right at ambiguous vertices
      0 => 1,
      3 => 2,
      _ => 3,
    };
  }

  _RasterPoint _pointFromKey(int key, int stride) {
    return _RasterPoint(
      (key % stride).toDouble(),
      (key ~/ stride).toDouble(),
    );
  }

  List<_RasterPoint> _removeCollinear(List<_RasterPoint> points) {
    if (points.length <= 3) return List<_RasterPoint>.of(points);
    var current = List<_RasterPoint>.of(points);
    var changed = true;

    while (changed && current.length > 3) {
      changed = false;
      final next = <_RasterPoint>[];
      for (var i = 0; i < current.length; i++) {
        final previous = current[(i - 1 + current.length) % current.length];
        final point = current[i];
        final following = current[(i + 1) % current.length];
        final cross = ((point.x - previous.x) * (following.y - point.y)) -
            ((point.y - previous.y) * (following.x - point.x));
        if (cross.abs() <= 1e-9) {
          changed = true;
        } else {
          next.add(point);
        }
      }
      if (next.length < 3) break;
      current = next;
    }
    return current;
  }

  List<_RasterPoint> _simplifyClosed(
    List<_RasterPoint> points,
    double epsilon,
  ) {
    final compact = _removeCollinear(points);
    if (compact.length <= 3 || epsilon == 0) return compact;

    var firstIndex = 0;
    var secondIndex = _farthestIndex(compact, firstIndex);
    firstIndex = _farthestIndex(compact, secondIndex);
    secondIndex = _farthestIndex(compact, firstIndex);

    List<_RasterPoint> cyclicArc(int start, int end) {
      final result = <_RasterPoint>[compact[start]];
      var index = start;
      while (index != end) {
        index = (index + 1) % compact.length;
        result.add(compact[index]);
      }
      return result;
    }

    final firstArc = _simplifyOpen(
      cyclicArc(firstIndex, secondIndex),
      epsilon,
    );
    final secondArc = _simplifyOpen(
      cyclicArc(secondIndex, firstIndex),
      epsilon,
    );
    final combined = <_RasterPoint>[
      ...firstArc,
      ...secondArc.skip(1),
    ];
    if (combined.first == combined.last) combined.removeLast();
    return _removeCollinear(combined);
  }

  int _farthestIndex(List<_RasterPoint> points, int fromIndex) {
    var result = fromIndex;
    var greatestDistance = -1.0;
    final from = points[fromIndex];
    for (var i = 0; i < points.length; i++) {
      final dx = points[i].x - from.x;
      final dy = points[i].y - from.y;
      final distance = (dx * dx) + (dy * dy);
      if (distance > greatestDistance) {
        greatestDistance = distance;
        result = i;
      }
    }
    return result;
  }

  List<_RasterPoint> _simplifyOpen(
    List<_RasterPoint> points,
    double epsilon,
  ) {
    if (points.length <= 2) return List<_RasterPoint>.of(points);

    final keep = List<bool>.filled(points.length, false)
      ..first = true
      ..last = true;
    final ranges = <(int, int)>[(0, points.length - 1)];

    while (ranges.isNotEmpty) {
      final range = ranges.removeLast();
      var greatestDistance = -1.0;
      var splitIndex = -1;
      for (var i = range.$1 + 1; i < range.$2; i++) {
        final distance = _perpendicularDistance(
          points[i],
          points[range.$1],
          points[range.$2],
        );
        if (distance > greatestDistance) {
          greatestDistance = distance;
          splitIndex = i;
        }
      }
      if (greatestDistance <= epsilon || splitIndex < 0) continue;
      keep[splitIndex] = true;
      ranges
        ..add((range.$1, splitIndex))
        ..add((splitIndex, range.$2));
    }

    return [
      for (var i = 0; i < points.length; i++)
        if (keep[i]) points[i]
    ];
  }

  double _perpendicularDistance(
    _RasterPoint point,
    _RasterPoint lineStart,
    _RasterPoint lineEnd,
  ) {
    final dx = lineEnd.x - lineStart.x;
    final dy = lineEnd.y - lineStart.y;
    if (dx == 0 && dy == 0) {
      return sqrt(
        pow(point.x - lineStart.x, 2) + pow(point.y - lineStart.y, 2),
      );
    }
    return ((dy * point.x) -
                (dx * point.y) +
                (lineEnd.x * lineStart.y) -
                (lineEnd.y * lineStart.x))
            .abs() /
        sqrt((dx * dx) + (dy * dy));
  }

  double _signedArea(List<_RasterPoint> polygon) {
    var areaTwice = 0.0;
    for (var i = 0; i < polygon.length; i++) {
      final current = polygon[i];
      final next = polygon[(i + 1) % polygon.length];
      areaTwice += (current.x * next.y) - (next.x * current.y);
    }
    return areaTwice / 2;
  }

  CuratorPoint _mapToCanvas(
    _RasterPoint point, {
    required int sourceWidth,
    required int sourceHeight,
    required ItemLayoutBounds bounds,
  }) {
    return CuratorPoint(
      bounds.x + ((point.x / sourceWidth) * bounds.width),
      bounds.y + ((point.y / sourceHeight) * bounds.height),
    );
  }

  _SegmentationResult _fallback(ItemLayoutBounds bounds) {
    final polygon = <CuratorPoint>[
      CuratorPoint(bounds.x + (bounds.width * 0.15), bounds.y),
      CuratorPoint(bounds.x + (bounds.width * 0.85), bounds.y),
      CuratorPoint(
        bounds.x + bounds.width,
        bounds.y + (bounds.height * 0.15),
      ),
      CuratorPoint(
        bounds.x + bounds.width,
        bounds.y + (bounds.height * 0.85),
      ),
      CuratorPoint(
        bounds.x + (bounds.width * 0.85),
        bounds.y + bounds.height,
      ),
      CuratorPoint(
        bounds.x + (bounds.width * 0.15),
        bounds.y + bounds.height,
      ),
      CuratorPoint(bounds.x, bounds.y + (bounds.height * 0.85)),
      CuratorPoint(bounds.x, bounds.y + (bounds.height * 0.15)),
    ];
    return _SegmentationResult(
      polygon: polygon,
      contours: [polygon],
      centroid: CuratorPoint(
        bounds.x + (bounds.width / 2),
        bounds.y + (bounds.height / 2),
      ),
      isPrecise: false,
    );
  }
}

final class _BoundaryEdge {
  const _BoundaryEdge({
    required this.start,
    required this.end,
    required this.direction,
  });

  final int start;
  final int end;
  final int direction;
}

final class _RasterPoint {
  const _RasterPoint(this.x, this.y);

  final double x;
  final double y;

  @override
  bool operator ==(Object other) =>
      other is _RasterPoint && other.x == x && other.y == y;

  @override
  int get hashCode => Object.hash(x, y);
}

final class _SegmentationResult {
  const _SegmentationResult({
    required this.polygon,
    required this.contours,
    required this.centroid,
    required this.isPrecise,
  });

  final List<CuratorPoint> polygon;
  final List<List<CuratorPoint>> contours;
  final CuratorPoint centroid;
  final bool isPrecise;
}

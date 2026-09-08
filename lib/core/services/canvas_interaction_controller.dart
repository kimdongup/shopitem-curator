// Pure Dart Service (Zero Flutter Dependencies)

import 'dart:math' as math;

import '../models/curator_item.dart';
import 'html_imagemap_exporter.dart';

/// 2D 좌표/오프셋 표현을 위한 순수 Dart 불변 값 객체
class CanvasOffset {
  const CanvasOffset(this.dx, this.dy);
  final double dx;
  final double dy;

  static const CanvasOffset zero = CanvasOffset(0.0, 0.0);

  CanvasOffset operator +(CanvasOffset other) =>
      CanvasOffset(dx + other.dx, dy + other.dy);

  CanvasOffset operator -(CanvasOffset other) =>
      CanvasOffset(dx - other.dx, dy - other.dy);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CanvasOffset &&
          runtimeType == other.runtimeType &&
          dx == other.dx &&
          dy == other.dy;

  @override
  int get hashCode => Object.hash(dx, dy);

  @override
  String toString() => 'CanvasOffset($dx, $dy)';
}

/// [CanvasInteractionController]
/// Flutter UI에 종속되지 않는 순수 Dart 캔버스 상호작용 및 지오메트리 계산 엔진.
/// - 드래그 이동 및 캔버스 경계 클램핑 (Boundary Clamping)
/// - 마우스 휠 및 키보드 크기 조절 (Scale Limits)
/// - 레이어 z-order 순서 관리
/// - HTML 이미지맵 내보내기 데이터 자동 변환
class CanvasInteractionController {
  CanvasInteractionController({
    required this.canvasWidth,
    required this.canvasHeight,
    List<CuratorItem> initialItems = const [],
  }) {
    setItems(initialItems);
  }

  double canvasWidth;
  double canvasHeight;

  final Map<String, CanvasOffset> _dragOffsets = {};
  final Map<String, double> _itemScales = {};
  List<String> _renderOrder = [];
  String? _focusedItemId;
  String? _draggingItemId;
  bool _hasCustomLayout = false;

  Map<String, CanvasOffset> get dragOffsets => Map.unmodifiable(_dragOffsets);
  Map<String, double> get itemScales => Map.unmodifiable(_itemScales);
  List<String> get renderOrder => List.unmodifiable(_renderOrder);
  String? get focusedItemId => _focusedItemId;
  String? get draggingItemId => _draggingItemId;
  bool get hasCustomLayout => _hasCustomLayout;

  void setItems(List<CuratorItem> items) {
    _dragOffsets.clear();
    _itemScales.clear();
    _focusedItemId = null;
    _draggingItemId = null;
    _hasCustomLayout = false;
    _renderOrder = items.map((item) => item.id).toList();
  }

  CanvasOffset dragOffset(String id) => _dragOffsets[id] ?? CanvasOffset.zero;

  double itemScale(String id) => _itemScales[id] ?? 1.0;

  void setFocusedItem(String? id) {
    _focusedItemId = id;
  }

  void startDragging(String id) {
    _draggingItemId = id;
    _hasCustomLayout = true;
    bringToTop(id);
  }

  void finishDragging() {
    _draggingItemId = null;
  }

  void bringToTop(String id) {
    if (_renderOrder.contains(id)) {
      _renderOrder.remove(id);
      _renderOrder.add(id);
    }
  }

  double maximumScaleFor(CuratorItem item) {
    final widthScale =
        item.bounds.width <= 0 ? 2.5 : canvasWidth / item.bounds.width;
    final heightScale =
        item.bounds.height <= 0 ? 2.5 : canvasHeight / item.bounds.height;
    return math.max(0.01, math.min(2.5, math.min(widthScale, heightScale)));
  }

  CanvasOffset clampOffset({
    required CuratorItem item,
    required CanvasOffset proposedOffset,
    required double scale,
  }) {
    final scaledWidth = math.max(0.0, item.bounds.width * scale);
    final scaledHeight = math.max(0.0, item.bounds.height * scale);
    final maximumX = math.max(0.0, canvasWidth - scaledWidth);
    final maximumY = math.max(0.0, canvasHeight - scaledHeight);

    final left = (item.bounds.x + proposedOffset.dx).clamp(0.0, maximumX);
    final top = (item.bounds.y + proposedOffset.dy).clamp(0.0, maximumY);

    return CanvasOffset(
      left - item.bounds.x,
      top - item.bounds.y,
    );
  }

  void moveItem(CuratorItem item, CanvasOffset delta) {
    final current = dragOffset(item.id);
    final proposed = current + delta;
    _dragOffsets[item.id] = clampOffset(
      item: item,
      proposedOffset: proposed,
      scale: itemScale(item.id),
    );
    _hasCustomLayout = true;
  }

  void changeScale(CuratorItem item, double delta) {
    final current = itemScale(item.id);
    final maximumScale = maximumScaleFor(item);
    final minimumScale = math.min(0.4, maximumScale);
    final newScale =
        (current + delta).clamp(minimumScale, maximumScale).toDouble();

    _itemScales[item.id] = newScale;
    _dragOffsets[item.id] = clampOffset(
      item: item,
      proposedOffset: dragOffset(item.id),
      scale: newScale,
    );
    _hasCustomLayout = true;
  }

  /// Bottom-right handle: keep the top-left anchored and preserve aspect ratio.
  /// [delta] is expressed in canvas coordinates, not screen pixels.
  void resizeFromCorner(CuratorItem item, CanvasOffset delta) {
    final width = item.bounds.width, height = item.bounds.height;
    if (width <= 0 || height <= 0 || !delta.dx.isFinite || !delta.dy.isFinite) {
      return;
    }
    final offset = dragOffset(item.id);
    final left = item.bounds.x + offset.dx, top = item.bounds.y + offset.dy;
    final maxScale = math.min(maximumScaleFor(item),
        math.min((canvasWidth - left) / width, (canvasHeight - top) / height));
    if (maxScale <= 0) return;
    final change = (delta.dx * width + delta.dy * height) /
        (width * width + height * height);
    _itemScales[item.id] = (itemScale(item.id) + change)
        .clamp(math.min(0.4, maxScale), maxScale)
        .toDouble();
    _hasCustomLayout = true;
  }

  void resetLayout(List<CuratorItem> items) {
    _dragOffsets.clear();
    _itemScales.clear();
    _draggingItemId = null;
    _focusedItemId = null;
    _hasCustomLayout = false;
    _renderOrder = items.map((item) => item.id).toList();
  }

  List<PositionedItemExportData> generateExportList(List<CuratorItem> items) {
    final itemById = {for (final item in items) item.id: item};
    return _renderOrder.map((id) {
      final item = itemById[id] ??
          items.firstWhere(
            (it) => it.id == id,
            orElse: () => throw StateError('Item $id not found'),
          );
      final offset = dragOffset(id);
      final scale = itemScale(id);
      return PositionedItemExportData(
        item: item,
        x: item.bounds.x + offset.dx,
        y: item.bounds.y + offset.dy,
        width: item.bounds.width,
        height: item.bounds.height,
        scale: scale,
      );
    }).toList(growable: false);
  }
}

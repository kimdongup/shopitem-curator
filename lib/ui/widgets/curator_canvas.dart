import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../core/models/curator_item.dart';
import '../../core/services/canvas_interaction_controller.dart';
import '../../core/services/html_imagemap_exporter.dart';
import 'product_image.dart';
import 'speech_balloon_tag.dart';

/// Grayscale Color Filter Matrix
const ColorFilter _grayscaleFilter = ColorFilter.matrix(<double>[
  0.2126,
  0.7152,
  0.0722,
  0,
  0,
  0.2126,
  0.7152,
  0.0722,
  0,
  0,
  0.2126,
  0.7152,
  0.0722,
  0,
  0,
  0,
  0,
  0,
  1,
  0,
]);

/// Single Composited Dynamic Canvas layer:
/// - Clean Pure White background (#FFFFFF).
/// - Transparent hover interaction (no hazy white background or glow).
/// - Dynamic Item Resizing via mouse wheel scroll or +/- floating buttons.
/// - Free-form dragging and positioning.
/// - Speech balloon price tags with Target purchase links.
class CuratorCanvas extends StatefulWidget {
  const CuratorCanvas({
    super.key,
    required this.manifest,
    required this.hoveredItemId,
    required this.selectedItemId,
    required this.onHoverItem,
    required this.onSelectItem,
    required this.onDismissSelection,
    this.onItemsLayoutChanged,
  });

  final CuratorManifest manifest;
  final String? hoveredItemId;
  final String? selectedItemId;
  final ValueChanged<String?> onHoverItem;
  final ValueChanged<String?> onSelectItem;
  final VoidCallback onDismissSelection;
  final ValueChanged<List<PositionedItemExportData>>? onItemsLayoutChanged;

  @override
  State<CuratorCanvas> createState() => _CuratorCanvasState();
}

class _CuratorCanvasState extends State<CuratorCanvas> {
  late final CanvasInteractionController _controller;
  final Map<String, FocusNode> _itemFocusNodes = {};

  @override
  void initState() {
    super.initState();
    _controller = CanvasInteractionController(
      canvasWidth: widget.manifest.canvasWidth,
      canvasHeight: widget.manifest.canvasHeight,
      initialItems: widget.manifest.items,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) => _notifyLayoutChanged());
  }

  @override
  void dispose() {
    for (final node in _itemFocusNodes.values) {
      node.dispose();
    }
    super.dispose();
  }

  @override
  void didUpdateWidget(CuratorCanvas oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_manifestGeometryChanged(oldWidget.manifest, widget.manifest)) {
      _controller.canvasWidth = widget.manifest.canvasWidth;
      _controller.canvasHeight = widget.manifest.canvasHeight;
      _controller.setItems(widget.manifest.items);

      final retainedIds = widget.manifest.items.map((item) => item.id).toSet();
      final removedIds = _itemFocusNodes.keys
          .where((itemId) => !retainedIds.contains(itemId))
          .toList(growable: false);
      for (final itemId in removedIds) {
        _itemFocusNodes.remove(itemId)?.dispose();
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        for (final node in _itemFocusNodes.values) {
          node.unfocus();
        }
        _notifyLayoutChanged();
      });
    }
  }

  bool _manifestGeometryChanged(
    CuratorManifest previous,
    CuratorManifest current,
  ) {
    if (previous.sourceImage != current.sourceImage ||
        previous.canvasImage != current.canvasImage ||
        previous.canvasWidth != current.canvasWidth ||
        previous.canvasHeight != current.canvasHeight ||
        previous.items.length != current.items.length) {
      return true;
    }

    for (var index = 0; index < current.items.length; index++) {
      final before = previous.items[index];
      final after = current.items[index];
      if (before.id != after.id ||
          before.imageUrl != after.imageUrl ||
          before.bounds.x != after.bounds.x ||
          before.bounds.y != after.bounds.y ||
          before.bounds.width != after.bounds.width ||
          before.bounds.height != after.bounds.height ||
          !_sameContours(before.contours, after.contours)) {
        return true;
      }
    }
    return false;
  }

  bool _sameContours(
    List<List<CuratorPoint>> previous,
    List<List<CuratorPoint>> current,
  ) {
    if (previous.length != current.length) return false;
    for (var contourIndex = 0; contourIndex < current.length; contourIndex++) {
      final before = previous[contourIndex];
      final after = current[contourIndex];
      if (before.length != after.length) return false;
      for (var pointIndex = 0; pointIndex < after.length; pointIndex++) {
        if (before[pointIndex].x != after[pointIndex].x ||
            before[pointIndex].y != after[pointIndex].y) {
          return false;
        }
      }
    }
    return true;
  }

  void _bringToTop(String id) {
    setState(() => _controller.bringToTop(id));
    _notifyLayoutChanged();
  }

  Offset _dragOffset(String id) {
    final offset = _controller.dragOffset(id);
    return Offset(offset.dx, offset.dy);
  }

  double _itemScale(String id) => _controller.itemScale(id);

  FocusNode _itemFocusNode(String id) => _itemFocusNodes.putIfAbsent(
        id,
        () => FocusNode(debugLabel: 'Curator canvas item: $id'),
      );

  CuratorItem? _itemById(String id) =>
      widget.manifest.items.where((item) => item.id == id).firstOrNull;

  void _changeScale(String id, double delta) {
    final item = _itemById(id);
    if (item == null) return;
    setState(() => _controller.changeScale(item, delta));
    _notifyLayoutChanged();
  }

  void _resetLayout() {
    for (final node in _itemFocusNodes.values) {
      node.unfocus();
    }
    setState(() => _controller.resetLayout(widget.manifest.items));
    widget.onHoverItem(null);
    _notifyLayoutChanged();
  }

  void _toggleItemSelection(CuratorItem item) {
    if (item.id == widget.selectedItemId) {
      widget.onDismissSelection();
    } else {
      widget.onSelectItem(item.id);
    }
  }

  KeyEventResult _handleItemKeyEvent(CuratorItem item, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.space) {
      _toggleItemSelection(item);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape) {
      widget.onDismissSelection();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.add ||
        key == LogicalKeyboardKey.numpadAdd ||
        key == LogicalKeyboardKey.equal) {
      _changeScale(item.id, 0.1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.minus ||
        key == LogicalKeyboardKey.numpadSubtract) {
      _changeScale(item.id, -0.1);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _notifyLayoutChanged() {
    if (widget.onItemsLayoutChanged == null) return;

    final exportList = widget.manifest.items.map((item) {
      final off = _dragOffset(item.id);
      final scale = _itemScale(item.id);
      return PositionedItemExportData(
        item: item,
        x: item.bounds.x + off.dx,
        y: item.bounds.y + off.dy,
        width: item.bounds.width,
        height: item.bounds.height,
        scale: scale,
      );
    }).toList();

    widget.onItemsLayoutChanged!(exportList);
  }

  @override
  Widget build(BuildContext context) {
    final selectedItem = widget.manifest.items
        .where((it) => it.id == widget.selectedItemId)
        .firstOrNull;

    return LayoutBuilder(
      builder: (context, constraints) {
        final double canvasW = widget.manifest.canvasWidth;
        final double canvasH = widget.manifest.canvasHeight;
        final double aspectRatio = canvasW / canvasH;

        double renderWidth = constraints.maxWidth;
        double renderHeight = renderWidth / aspectRatio;
        if (renderHeight > constraints.maxHeight &&
            constraints.maxHeight.isFinite) {
          renderHeight = constraints.maxHeight;
          renderWidth = renderHeight * aspectRatio;
        }

        final double scaleX = renderWidth / canvasW;
        final double scaleY = renderHeight / canvasH;
        final useFlattenedCanvas = !_controller.hasCustomLayout &&
            widget.manifest.canvasImage.trim().isNotEmpty;

        final itemWidgets = _controller.renderOrder
            .map((id) =>
                widget.manifest.items.where((it) => it.id == id).firstOrNull)
            .whereType<CuratorItem>()
            .map(
              (item) => _buildDraggableItem(
                item,
                scaleX,
                scaleY,
                renderWidth,
                renderHeight,
                useFlattenedCanvas: useFlattenedCanvas,
              ),
            )
            .toList();

        return Center(
          child: SizedBox(
            key: const ValueKey('curator_canvas_surface'),
            width: renderWidth,
            height: renderHeight,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.white, // Clean Pure White Background
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: const Color(0xFFE2E8F0),
                  width: 1.5,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withAlpha(25),
                    blurRadius: 30,
                    offset: const Offset(0, 12),
                  ),
                ],
              ),
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Positioned.fill(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(20),
                      child: GestureDetector(
                        onTapDown: (_) => widget.onDismissSelection(),
                        child: Stack(
                          clipBehavior: Clip.none,
                          children: [
                            // Very subtle warm dot pattern on pure white canvas (Isolated with RepaintBoundary)
                            const RepaintBoundary(
                              child: CustomPaint(
                                size: Size.infinite,
                                painter: _LightDotGridPainter(),
                              ),
                            ),

                            if (useFlattenedCanvas)
                              Positioned.fill(
                                child: RepaintBoundary(
                                  child: IgnorePointer(
                                    child: ProductImage(
                                      key: const ValueKey(
                                        'curator_canvas_flattened_base',
                                      ),
                                      source: widget.manifest.canvasImage,
                                      fit: BoxFit.fill,
                                      semanticLabel: '그레이스케일 합성 캔버스',
                                      placeholderBuilder: (_) =>
                                          const SizedBox.expand(),
                                    ),
                                  ),
                                ),
                              ),

                            // All item widgets in z-order
                            ...itemWidgets,
                          ],
                        ),
                      ),
                    ),
                  ),

                  // The balloon is deliberately outside ClipRRect so a compact
                  // canvas never cuts off its shadow, tail, or content.
                  if (selectedItem != null)
                    _buildPositionedSpeechBalloon(
                      selectedItem: selectedItem,
                      scaleX: scaleX,
                      scaleY: scaleY,
                      canvasW: renderWidth,
                      canvasH: renderHeight,
                    ),

                  if (_controller.hasCustomLayout)
                    Positioned(
                      top: 8,
                      right: 8,
                      child: Material(
                        color: const Color(0xFF0F172A).withAlpha(220),
                        shape: const CircleBorder(),
                        elevation: 3,
                        child: IconButton(
                          key: const ValueKey('curator_canvas_reset_layout'),
                          onPressed: _resetLayout,
                          tooltip: '레이아웃 초기화',
                          icon: const Icon(
                            Icons.restart_alt,
                            size: 19,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildDraggableItem(
    CuratorItem item,
    double scaleX,
    double scaleY,
    double canvasW,
    double canvasH, {
    required bool useFlattenedCanvas,
  }) {
    final isHovered = item.id == widget.hoveredItemId;
    final isSelected = item.id == widget.selectedItemId;
    final isFocused = item.id == _controller.focusedItemId;
    final isActive = isHovered || isSelected || isFocused;
    final isDragging = item.id == _controller.draggingItemId;
    final currentScale = _itemScale(item.id);

    final double baseLeft = (item.bounds.x + _dragOffset(item.id).dx) * scaleX;
    final double baseTop = (item.bounds.y + _dragOffset(item.id).dy) * scaleY;
    final double itemW = item.bounds.width * scaleX * currentScale;
    final double itemH = item.bounds.height * scaleY * currentScale;

    return Positioned(
      key: ValueKey('curator_canvas_item_${item.id}'),
      left: baseLeft,
      top: baseTop,
      width: itemW,
      height: itemH,
      child: RepaintBoundary(
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned.fill(
              child: ClipPath(
                clipper: _ItemSilhouetteClipper(
                  contours: item.contours,
                  bounds: item.bounds,
                ),
              child: Listener(
                onPointerSignal: (pointerSignal) {
                  if (pointerSignal is PointerScrollEvent) {
                    final scrollDelta = pointerSignal.scrollDelta.dy;
                    if (scrollDelta < 0) {
                      _changeScale(item.id, 0.08);
                    } else if (scrollDelta > 0) {
                      _changeScale(item.id, -0.08);
                    }
                  }
                },
                child: MouseRegion(
                  cursor: isDragging
                      ? SystemMouseCursors.grabbing
                      : SystemMouseCursors.grab,
                  onEnter: (_) {
                    widget.onHoverItem(item.id);
                    _bringToTop(item.id);
                  },
                  onExit: (_) {
                    if (!isDragging) widget.onHoverItem(null);
                  },
                  child: Focus(
                    key: ValueKey('curator_canvas_item_focus_${item.id}'),
                    focusNode: _itemFocusNode(item.id),
                    onFocusChange: (hasFocus) {
                      if (hasFocus && _controller.focusedItemId != item.id) {
                        setState(() => _controller.setFocusedItem(item.id));
                      } else if (!hasFocus &&
                          _controller.focusedItemId == item.id) {
                        setState(() => _controller.setFocusedItem(null));
                      }
                    },
                    onKeyEvent: (_, event) => _handleItemKeyEvent(item, event),
                    child: Semantics(
                      button: true,
                      label: '${item.name}, ${item.formattedPrice}',
                      hint: 'Enter 또는 Space로 선택, +와 -로 크기 조절',
                      onTap: () => _toggleItemSelection(item),
                      onIncrease: () => _changeScale(item.id, 0.1),
                      onDecrease: () => _changeScale(item.id, -0.1),
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTapDown: (_) =>
                            _itemFocusNode(item.id).requestFocus(),
                        onTapUp: (_) {
                          if (!isDragging) _toggleItemSelection(item);
                        },
                        onPanStart: (_) {
                          _itemFocusNode(item.id).requestFocus();
                          setState(() => _controller.startDragging(item.id));
                          widget.onHoverItem(item.id);
                        },
                        onPanUpdate: (details) {
                          setState(() {
                            _controller.moveItem(
                              item,
                              CanvasOffset(
                                details.delta.dx / scaleX,
                                details.delta.dy / scaleY,
                              ),
                            );
                          });
                          _notifyLayoutChanged();
                        },
                        onPanEnd: (_) => _finishDrag(),
                        onPanCancel: _finishDrag,
                        child: AnimatedScale(
                          // The flattened base already contains this item at
                          // 1:1. Scaling only the colour overlay reveals the
                          // grayscale copy underneath as a visible ghost.
                          scale: isActive && !useFlattenedCanvas ? 1.05 : 1.0,
                          duration: const Duration(milliseconds: 180),
                          curve: Curves.easeOutCubic,
                          child: ColorFiltered(
                            colorFilter: isActive
                                ? const ColorFilter.mode(
                                    Colors.transparent,
                                    BlendMode.dst,
                                  )
                                : _grayscaleFilter,
                            child: !useFlattenedCanvas || isActive
                                ? ProductImage(
                                    key: ValueKey(
                                      'curator_canvas_item_image_${item.id}',
                                    ),
                                    source: item.imageUrl,
                                    semanticLabel: item.name,
                                  )
                                : const SizedBox.expand(),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          if (isActive)
            Positioned(
              top: -6,
              right: -6,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                decoration: BoxDecoration(
                  color: const Color(0xFF0F172A).withAlpha(220),
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: const [
                    BoxShadow(
                      color: Colors.black26,
                      blurRadius: 6,
                      offset: Offset(0, 2),
                    ),
                  ],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _buildMiniScaleBtn(
                      key: ValueKey('curator_canvas_scale_down_${item.id}'),
                      icon: Icons.remove,
                      tooltip: '크기 축소 (휠 아래로)',
                      onTap: () => _changeScale(item.id, -0.1),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 3),
                      child: Text(
                        '${(currentScale * 100).toInt()}%',
                        style: const TextStyle(
                          fontSize: 9,
                          color: Colors.white70,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    _buildMiniScaleBtn(
                      key: ValueKey('curator_canvas_scale_up_${item.id}'),
                      icon: Icons.add,
                      tooltip: '크기 확대 (휠 위로)',
                      onTap: () => _changeScale(item.id, 0.1),
                    ),
                  ],
                ),
              ),
            ),
        ],
        ),
      ),
    );
  }

  void _finishDrag() {
    if (_controller.draggingItemId == null) return;
    setState(() => _controller.finishDragging());
    widget.onHoverItem(null);
    _notifyLayoutChanged();
  }

  Widget _buildMiniScaleBtn({
    required Key key,
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
  }) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        key: key,
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.all(2),
          child: Icon(icon, size: 13, color: Colors.white),
        ),
      ),
    );
  }

  Widget _buildPositionedSpeechBalloon({
    required CuratorItem selectedItem,
    required double scaleX,
    required double scaleY,
    required double canvasW,
    required double canvasH,
  }) {
    const margin = 8.0;
    final dragOff = _dragOffset(selectedItem.id);
    final scale = _itemScale(selectedItem.id);
    final itemLeft = selectedItem.bounds.x + dragOff.dx;
    final itemTop = selectedItem.bounds.y + dragOff.dy;
    final centerX = (itemLeft +
            ((selectedItem.centroid.x - selectedItem.bounds.x) * scale)) *
        scaleX;
    final centerY = (itemTop +
            ((selectedItem.centroid.y - selectedItem.bounds.y) * scale)) *
        scaleY;
    final itemTopPx = itemTop * scaleY;
    final itemBottomPx =
        itemTopPx + (selectedItem.bounds.height * scaleY * scale);

    final availableWidth = math.max(1.0, canvasW - (margin * 2));
    final balloonW = math.min(310.0, availableWidth);
    final balloonH = SpeechBalloonTag.estimatedHeightForWidth(balloonW);
    final maximumLeft = math.max(margin, canvasW - margin - balloonW);
    final left =
        (centerX - (balloonW / 2)).clamp(margin, maximumLeft).toDouble();

    final aboveTop = centerY - balloonH - 14;
    final belowTop = itemBottomPx + 10;
    final roomAbove = itemTopPx;
    final roomBelow = canvasH - itemBottomPx;
    var tailOnTop = false;
    double top;
    if (aboveTop >= margin) {
      top = aboveTop;
    } else if (belowTop + balloonH <= canvasH - margin) {
      top = belowTop;
      tailOnTop = true;
    } else {
      tailOnTop = roomBelow >= roomAbove;
      top = tailOnTop ? belowTop : aboveTop;
      final maximumTop = math.max(margin, canvasH - margin - balloonH);
      top = top.clamp(margin, maximumTop).toDouble();
    }

    final tailAlignment =
        ((centerX - left) / balloonW).clamp(0.12, 0.88).toDouble();

    return Positioned(
      left: left,
      top: top,
      child: SpeechBalloonTag(
        key: ValueKey('curator_canvas_speech_balloon_${selectedItem.id}'),
        item: selectedItem,
        onDismiss: widget.onDismissSelection,
        width: balloonW,
        tailAlignment: tailAlignment,
        tailOnTop: tailOnTop,
      ),
    );
  }
}

/// Maps canvas-space silhouette contours into local widget bounds.
///
/// An even-odd path retains disconnected product pieces and cuts enclosed
/// holes out of both painting and pointer hit testing. Returning the full
/// rectangle keeps malformed legacy manifests usable.
class _ItemSilhouetteClipper extends CustomClipper<Path> {
  _ItemSilhouetteClipper({
    required this.contours,
    required this.bounds,
  });

  final List<List<CuratorPoint>> contours;
  final ItemLayoutBounds bounds;
  Path? _cachedPath;
  Size? _cachedSize;

  @override
  Path getClip(Size size) {
    if (_cachedPath != null && _cachedSize == size) {
      return _cachedPath!;
    }

    final usableContours = contours
        .where((contour) => contour.length >= 3)
        .toList(growable: false);
    if (usableContours.isEmpty ||
        bounds.width <= 0 ||
        bounds.height <= 0 ||
        size.isEmpty) {
      final fallback = Path()..addRect(Offset.zero & size);
      _cachedPath = fallback;
      _cachedSize = size;
      return fallback;
    }

    Offset localPoint(CuratorPoint point) => Offset(
          ((point.x - bounds.x) / bounds.width) * size.width,
          ((point.y - bounds.y) / bounds.height) * size.height,
        );

    final path = Path()..fillType = PathFillType.evenOdd;
    for (final contour in usableContours) {
      final first = localPoint(contour.first);
      path.moveTo(first.dx, first.dy);
      for (final point in contour.skip(1)) {
        final local = localPoint(point);
        path.lineTo(local.dx, local.dy);
      }
      path.close();
    }
    _cachedPath = path;
    _cachedSize = size;
    return path;
  }

  @override
  bool shouldReclip(covariant _ItemSilhouetteClipper oldClipper) {
    if (bounds.x != oldClipper.bounds.x ||
        bounds.y != oldClipper.bounds.y ||
        bounds.width != oldClipper.bounds.width ||
        bounds.height != oldClipper.bounds.height ||
        contours.length != oldClipper.contours.length) {
      return true;
    }

    for (var contourIndex = 0; contourIndex < contours.length; contourIndex++) {
      final contour = contours[contourIndex];
      final oldContour = oldClipper.contours[contourIndex];
      if (contour.length != oldContour.length) return true;
      for (var pointIndex = 0; pointIndex < contour.length; pointIndex++) {
        if (contour[pointIndex].x != oldContour[pointIndex].x ||
            contour[pointIndex].y != oldContour[pointIndex].y) {
          return true;
        }
      }
    }
    return false;
  }
}

/// Very light, elegant dot-grid pattern on white canvas
class _LightDotGridPainter extends CustomPainter {
  const _LightDotGridPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xFFCBD5E1).withAlpha(70)
      ..style = PaintingStyle.fill;

    const double step = 32.0;
    const double dotR = 1.0;
    for (double x = step; x < size.width; x += step) {
      for (double y = step; y < size.height; y += step) {
        canvas.drawCircle(Offset(x, y), dotR, paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

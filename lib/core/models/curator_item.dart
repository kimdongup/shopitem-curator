// Pure Dart Domain Model (Zero Flutter Dependencies)

/// Represents a 2D coordinate point on the canvas.
class CuratorPoint {
  const CuratorPoint(this.x, this.y);

  final double x;
  final double y;

  factory CuratorPoint.fromJson(List<dynamic> json) {
    return CuratorPoint(
      (json[0] as num).toDouble(),
      (json[1] as num).toDouble(),
    );
  }

  List<double> toJson() => [x, y];

  @override
  String toString() => 'CuratorPoint($x, $y)';
}

/// Represents dynamic layout coordinates (x, y, width, height) of an item on the canvas.
class ItemLayoutBounds {
  const ItemLayoutBounds({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
  });

  final double x;
  final double y;
  final double width;
  final double height;

  factory ItemLayoutBounds.fromJson(Map<String, dynamic> json) {
    return ItemLayoutBounds(
      x: (json['x'] as num).toDouble(),
      y: (json['y'] as num).toDouble(),
      width: (json['width'] as num).toDouble(),
      height: (json['height'] as num).toDouble(),
    );
  }

  Map<String, dynamic> toJson() => {
        'x': x,
        'y': y,
        'width': width,
        'height': height,
      };
}

/// Represents an alternative Target product candidate detected during web inspection / review.
class TargetProductCandidate {
  const TargetProductCandidate({
    required this.id,
    required this.name,
    required this.price,
    required this.imageUrl,
    required this.targetUrl,
    required this.description,
  });

  final String id;
  final String name;
  final double price;
  final String imageUrl;
  final String targetUrl;
  final String description;

  String get formattedPrice =>
      price <= 0 ? '가격 확인 필요' : '\$${price.toStringAsFixed(2)}';
}

/// Represents a single curated school supply item fetched from Target.
class CuratorItem {
  CuratorItem({
    required this.id,
    required this.name,
    required this.category,
    required this.isPersonal,
    required this.quantity,
    required this.price,
    required this.priceCurrency,
    required this.description,
    required this.targetUrl,
    required this.imageUrl,
    required this.bounds,
    required List<CuratorPoint> polygon,
    List<List<CuratorPoint>>? contours,
    required this.centroid,
    this.isApproved = true,
    this.isPreciselySegmented = true,
  })  : polygon = List.unmodifiable(polygon),
        contours = _freezeContours(polygon, contours);

  final String id;
  final String name;
  final String category;
  final bool isPersonal;
  final int quantity;
  final double price;
  final String priceCurrency;
  final String description;
  final String targetUrl;
  final String imageUrl;
  final ItemLayoutBounds bounds;

  /// The primary (largest) silhouette retained for legacy consumers.
  final List<CuratorPoint> polygon;

  /// Every disconnected silhouette component and enclosed boundary.
  ///
  /// Older manifests only contain [polygon]. Those manifests transparently
  /// expose it as a single contour, so UI and exporters can migrate without a
  /// data conversion step.
  final List<List<CuratorPoint>> contours;
  final CuratorPoint centroid;
  final bool isApproved;

  /// True when [contours] were derived from decoded image pixels.
  ///
  /// False means the item is still usable with safe fallback geometry, but
  /// should not be presented as having an exact silhouette.
  final bool isPreciselySegmented;

  factory CuratorItem.fromJson(Map<String, dynamic> json) {
    final rawPolygon = (json['polygon'] as List<dynamic>?) ?? [];
    var polygonPoints = rawPolygon
        .map((pt) => CuratorPoint.fromJson(pt as List<dynamic>))
        .toList();
    final rawContours = (json['contours'] as List<dynamic>?) ?? [];
    final contourPoints = rawContours
        .map(
          (rawContour) => (rawContour as List<dynamic>)
              .map((pt) => CuratorPoint.fromJson(pt as List<dynamic>))
              .toList(),
        )
        .where((contour) => contour.isNotEmpty)
        .toList();
    if (polygonPoints.isEmpty && contourPoints.isNotEmpty) {
      polygonPoints = List<CuratorPoint>.of(contourPoints.first);
    }

    CuratorPoint calculatedCentroid;
    if (json['centroid'] != null) {
      calculatedCentroid =
          CuratorPoint.fromJson(json['centroid'] as List<dynamic>);
    } else if (polygonPoints.isNotEmpty) {
      final sumX = polygonPoints.fold<double>(0.0, (acc, p) => acc + p.x);
      final sumY = polygonPoints.fold<double>(0.0, (acc, p) => acc + p.y);
      calculatedCentroid = CuratorPoint(
        sumX / polygonPoints.length,
        sumY / polygonPoints.length,
      );
    } else {
      calculatedCentroid = const CuratorPoint(0, 0);
    }

    final rawBounds = json['bounds'] as Map<String, dynamic>?;
    final bounds = rawBounds != null
        ? ItemLayoutBounds.fromJson(rawBounds)
        : const ItemLayoutBounds(x: 0, y: 0, width: 200, height: 200);

    return CuratorItem(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      category: json['category'] as String? ?? '',
      isPersonal: json['is_personal'] as bool? ?? false,
      quantity: (json['quantity'] as num?)?.toInt() ?? 1,
      price: (json['price'] as num?)?.toDouble() ?? 0.0,
      priceCurrency: json['price_currency'] as String? ?? 'USD',
      description: json['description'] as String? ?? '',
      targetUrl: json['target_url'] as String? ?? '',
      imageUrl:
          json['image_url'] as String? ?? json['item_image'] as String? ?? '',
      bounds: bounds,
      polygon: polygonPoints,
      contours: contourPoints.isEmpty ? null : contourPoints,
      centroid: calculatedCentroid,
      isApproved: json['is_approved'] as bool? ?? true,
      // Checked-in manifests created before this field already contain exact
      // pixel-derived contours, so the backward-compatible default is true.
      isPreciselySegmented: json['is_precisely_segmented'] as bool? ?? true,
    );
  }

  CuratorItem copyWith({
    String? id,
    String? name,
    String? category,
    bool? isPersonal,
    int? quantity,
    double? price,
    String? priceCurrency,
    String? description,
    String? targetUrl,
    String? imageUrl,
    ItemLayoutBounds? bounds,
    List<CuratorPoint>? polygon,
    List<List<CuratorPoint>>? contours,
    CuratorPoint? centroid,
    bool? isApproved,
    bool? isPreciselySegmented,
  }) {
    return CuratorItem(
      id: id ?? this.id,
      name: name ?? this.name,
      category: category ?? this.category,
      isPersonal: isPersonal ?? this.isPersonal,
      quantity: quantity ?? this.quantity,
      price: price ?? this.price,
      priceCurrency: priceCurrency ?? this.priceCurrency,
      description: description ?? this.description,
      targetUrl: targetUrl ?? this.targetUrl,
      imageUrl: imageUrl ?? this.imageUrl,
      bounds: bounds ?? this.bounds,
      polygon: polygon ?? this.polygon,
      // Replacing only the legacy primary polygon deliberately resets the
      // compound geometry. Keeping the old contours here would leave stale
      // hit regions after an image/geometry fallback replacement.
      contours: contours ?? (polygon == null ? this.contours : [polygon]),
      centroid: centroid ?? this.centroid,
      isApproved: isApproved ?? this.isApproved,
      isPreciselySegmented: isPreciselySegmented ?? this.isPreciselySegmented,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'category': category,
        'is_personal': isPersonal,
        'quantity': quantity,
        'price': price,
        'price_currency': priceCurrency,
        'description': description,
        'target_url': targetUrl,
        'image_url': imageUrl,
        'bounds': bounds.toJson(),
        'polygon': polygon.map((p) => p.toJson()).toList(),
        'contours': contours
            .map(
              (contour) => contour.map((point) => point.toJson()).toList(),
            )
            .toList(),
        'centroid': centroid.toJson(),
        'is_approved': isApproved,
        'is_precisely_segmented': isPreciselySegmented,
      };

  String get formattedPrice {
    return price <= 0 ? '가격 확인 필요' : '\$${price.toStringAsFixed(2)}';
  }

  @override
  String toString() =>
      'CuratorItem(id: $id, name: $name, price: $formattedPrice)';
}

List<List<CuratorPoint>> _freezeContours(
  List<CuratorPoint> polygon,
  List<List<CuratorPoint>>? contours,
) {
  final source = contours == null || contours.isEmpty
      ? (polygon.isEmpty ? const <List<CuratorPoint>>[] : [polygon])
      : contours;
  return List<List<CuratorPoint>>.unmodifiable(
    source.map(List<CuratorPoint>.unmodifiable),
  );
}

/// Represents the dynamic canvas manifest containing all composited items.
class CuratorManifest {
  CuratorManifest({
    this.sourceImage = '',
    this.canvasImage = '',
    required this.canvasWidth,
    required this.canvasHeight,
    required List<CuratorItem> items,
  }) : items = List.unmodifiable(items);

  final String sourceImage;
  final String canvasImage;
  final double canvasWidth;
  final double canvasHeight;
  final List<CuratorItem> items;

  CuratorManifest copyWith({
    String? sourceImage,
    String? canvasImage,
    double? canvasWidth,
    double? canvasHeight,
    List<CuratorItem>? items,
  }) {
    return CuratorManifest(
      sourceImage: sourceImage ?? this.sourceImage,
      canvasImage: canvasImage ?? this.canvasImage,
      canvasWidth: canvasWidth ?? this.canvasWidth,
      canvasHeight: canvasHeight ?? this.canvasHeight,
      items: items ?? this.items,
    );
  }

  factory CuratorManifest.fromJson(Map<String, dynamic> json) {
    final rawItems = (json['items'] as List<dynamic>?) ?? [];
    return CuratorManifest(
      sourceImage: json['source_image'] as String? ?? '',
      canvasImage: json['canvas_image'] as String? ?? '',
      canvasWidth: (json['canvas_width'] as num?)?.toDouble() ?? 1200.0,
      canvasHeight: (json['canvas_height'] as num?)?.toDouble() ?? 896.0,
      items: rawItems
          .map((it) => CuratorItem.fromJson(it as Map<String, dynamic>))
          .toList(),
    );
  }

  Map<String, dynamic> toJson() => {
        'source_image': sourceImage,
        'canvas_image': canvasImage,
        'canvas_width': canvasWidth,
        'canvas_height': canvasHeight,
        'items': items.map((item) => item.toJson()).toList(),
      };
}

// Pure Dart catalog ports and transport-neutral DTOs.

/// One checklist entry extracted from the source image.
final class ExtractedItemEntry {
  const ExtractedItemEntry({
    required this.rawName,
    required this.cleanName,
    required this.isPersonal,
    required this.quantity,
  });

  final String rawName;
  final String cleanName;
  final bool isPersonal;
  final int quantity;
}

/// Extracts checklist entries without exposing the OCR transport to callers.
abstract interface class ItemExtractionGateway {
  Future<List<ExtractedItemEntry>> extractItemsFromImage(
    String imagePath, {
    List<int>? imageBytes,
  });
}

/// Complete product metadata consumed by the canvas pipeline.
final class TargetProductData {
  const TargetProductData({
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
  });

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
}

/// Resolves extracted entries into catalog products.
abstract interface class TargetProductGateway {
  Future<List<TargetProductData>> fetchTargetProducts(
    List<ExtractedItemEntry> entries, {
    void Function(int completed, int total, ExtractedItemEntry currentItem)?
        onProgress,
  });
}

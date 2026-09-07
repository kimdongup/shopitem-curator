// Pure Dart application ports (Zero Flutter Dependencies)

import '../models/curator_item.dart';

typedef PipelineProgressCallback = void Function(
  String stepDescription,
  double progress,
);

/// Runs the end-to-end extraction, catalog, composition, and segmentation
/// workflow without exposing its concrete implementation to the BLoC.
abstract interface class CurationPipeline {
  Future<CuratorManifest> runPipeline({
    required String sourceImagePath,
    List<int>? imageBytes,
    PipelineProgressCallback? onProgress,
  });
}

/// Rebuilds the flattened canvas and interaction geometry after catalog data
/// changes without coupling the BLoC to raster or segmentation services.
abstract interface class ManifestRebuilder {
  Future<CuratorManifest> rebuildManifest(CuratorManifest manifest);
}

/// Product lookup operations needed by the review workflow.
abstract interface class ProductReviewGateway {
  Future<List<TargetProductCandidate>> fetchLiveCandidates(CuratorItem item);

  Future<TargetProductCandidate?> fetchProductByTargetUrl(String url);
}

typedef CatalogRescrapeProgressCallback = void Function(
  int completed,
  int total,
  CuratorItem currentItem,
);

final class CatalogRescrapeResult {
  CatalogRescrapeResult({
    required List<CuratorItem> items,
    required this.successfulItemCount,
    required this.failedItemCount,
  }) : items = List.unmodifiable(items);

  final List<CuratorItem> items;
  final int successfulItemCount;
  final int failedItemCount;

  int get totalItemCount => successfulItemCount + failedItemCount;
  bool get isComplete => failedItemCount == 0;
  bool get isTotalFailure => successfulItemCount == 0 && failedItemCount > 0;
}

/// Refreshes existing item metadata. The BLoC observes progress but does not
/// know about Target search pages, PDP parsing, image CDNs, or HTTP details.
abstract interface class CatalogRescraper {
  Future<CatalogRescrapeResult> rescrapeAll({
    required List<CuratorItem> items,
    CatalogRescrapeProgressCallback? onProgress,
  });
}

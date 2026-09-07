// Pure Dart Service (Zero Flutter Dependencies)

import '../contracts/curator_use_cases.dart';
import '../models/curator_item.dart';
import 'scraper/concurrency/concurrent_executor.dart';
import 'target_fetcher_service.dart';

/// Target-specific implementation of the catalog refresh use case.
///
/// Keeping the two-step search/PDP algorithm here leaves [CuratorBloc]
/// responsible only for event-to-state transitions.
final class TargetCatalogRescraper implements CatalogRescraper {
  const TargetCatalogRescraper(
    this._targetFetcherService, {
    ConcurrentExecutor executor = const ConcurrentExecutor(),
    this.maxConcurrency = 3,
  })  : assert(maxConcurrency > 0),
        _executor = executor;

  final TargetFetcherService _targetFetcherService;
  final ConcurrentExecutor _executor;
  final int maxConcurrency;

  @override
  Future<CatalogRescrapeResult> rescrapeAll({
    required List<CuratorItem> items,
    CatalogRescrapeProgressCallback? onProgress,
  }) async {
    final outcomes = await _executor.execute<CuratorItem, _RefreshOutcome>(
      items: items,
      maxConcurrency: maxConcurrency,
      task: (item, _) => _refreshItem(item),
      onProgress: onProgress,
    );
    final successfulItemCount =
        outcomes.where((outcome) => outcome.succeeded).length;
    final refreshedItems =
        outcomes.map((outcome) => outcome.item).toList(growable: false);

    return CatalogRescrapeResult(
      items: refreshedItems,
      successfulItemCount: successfulItemCount,
      failedItemCount: outcomes.length - successfulItemCount,
    );
  }

  Future<_RefreshOutcome> _refreshItem(CuratorItem item) async {
    try {
      final resolution =
          await _targetFetcherService.resolveTargetProductPdpUrl(item.name);
      if (resolution == null) return _RefreshOutcome.failed(item);

      final fallbackImageUrl = resolution.primaryGuestId == null
          ? null
          : 'https://target.scene7.com/is/image/Target/'
              'GUEST_${resolution.primaryGuestId}'
              '?wid=1200&hei=1200&qlt=85&fmt=pjpeg';
      final liveImageUrl = await _targetFetcherService.adoptMainImageFromPdp(
        resolution.pdpUrl,
        fallbackImageUrl: fallbackImageUrl,
      );

      // Metadata and imagery are adopted as one unit. A failed item is kept
      // intact and marked for review instead of aborting the whole batch.
      if (liveImageUrl == null) return _RefreshOutcome.failed(item);
      return _RefreshOutcome.succeeded(
        item.copyWith(
          name: resolution.name,
          imageUrl: liveImageUrl,
          targetUrl: resolution.pdpUrl,
          price: resolution.price,
          description: resolution.description ?? item.description,
          isApproved: false,
        ),
      );
    } on Exception {
      return _RefreshOutcome.failed(item);
    }
  }
}

final class _RefreshOutcome {
  const _RefreshOutcome._(this.item, this.succeeded);

  factory _RefreshOutcome.succeeded(CuratorItem item) =>
      _RefreshOutcome._(item, true);

  factory _RefreshOutcome.failed(CuratorItem item) =>
      _RefreshOutcome._(item.copyWith(isApproved: false), false);

  final CuratorItem item;
  final bool succeeded;
}

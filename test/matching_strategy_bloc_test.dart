import 'dart:async';
import 'package:test/test.dart';
import 'package:shopitem_curator/core/bloc/curator_bloc.dart';
import 'package:shopitem_curator/core/bloc/curator_event.dart';
import 'package:shopitem_curator/core/bloc/curator_state.dart';
import 'package:shopitem_curator/core/contracts/curator_use_cases.dart';
import 'package:shopitem_curator/core/contracts/matching_strategy_provider.dart';
import 'package:shopitem_curator/core/models/matching_options.dart';
import 'package:shopitem_curator/core/models/curator_item.dart';
import 'package:shopitem_curator/core/repositories/item_repository.dart';

void main() {
  test(
      'strategy selection does not run OCR; explicit run uses a scoped pipeline and review',
      () async {
    final fallback = _Ports();
    final scoped = _Ports();
    final snapshots = <String>[];
    final bloc = CuratorBloc(
        itemRepository: const DefaultItemRepository(),
        pipelineService: fallback,
        manifestRebuilder: fallback,
        productReviewGateway: fallback,
        catalogRescraper: fallback,
        matchingStrategyProvider: CallbackMatchingStrategyProvider(
            loadCapabilities: () async => [
                  const MatchingCapability(
                      strategy: MatchingStrategy.randomDelay, available: true),
                  const MatchingCapability(
                      strategy: MatchingStrategy.proxyPool, available: false)
                ],
            createServices: (options) {
              snapshots.add(options.key);
              return MatchingServices(
                  pipeline: scoped, review: scoped, rescraper: scoped);
            }));
    addTearDown(bloc.close);
    Future<CuratorLoadedState> send(CuratorEvent event,
        [bool Function(CuratorLoadedState)? predicate]) {
      final future = bloc.stateStream
          .where((s) =>
              s is CuratorLoadedState && (predicate == null || predicate(s)))
          .cast<CuratorLoadedState>()
          .first
          .timeout(const Duration(seconds: 3));
      bloc.add(event);
      return future;
    }

    await send(const SelectSourceImageEvent('assets/images/new.jpg'));
    expect(scoped.pipelineCalls, 0);
    await send(const RefreshMatchingCapabilitiesEvent());
    await send(
        const SetMatchingStrategyEvent(MatchingStrategy.randomDelay, true));
    expect(scoped.pipelineCalls, 0);
    bloc.add(const SetMatchingStrategyEvent(MatchingStrategy.proxyPool, true));
    await Future<void>.delayed(Duration.zero);
    expect(
        (bloc.state as CuratorLoadedState)
            .matchingOptions
            .has(MatchingStrategy.proxyPool),
        isFalse);
    final result =
        await send(const RunMatchingEvent(), (s) => s.allItems.isNotEmpty);
    expect(scoped.pipelineCalls, 1);
    expect(fallback.pipelineCalls, 0);
    expect(snapshots.last, 'random_delay');
    expect(result.matchingStatus, contains('전체 파이프라인'));
    await send(const StartItemReviewEvent('item_1'));
    await send(const FetchLiveCandidatesEvent('item_1'),
        (s) => s.reviewStatus == ReviewStatus.empty);
    expect(scoped.reviewCalls, 2, reason: 'opening review searches once; explicit refresh searches again');
    expect(fallback.reviewCalls, 0);
    await send(const RescrapeAllEvent(), (s) => !s.isRescraping);
    expect(scoped.rescrapeCalls, 1);
    expect(fallback.rescrapeCalls, 0);
    await send(
        const SelectSourceImageEvent('assets/images/media_1787068853075.jpg'));
    expect(scoped.pipelineCalls, 1,
        reason: 'new document waits for explicit Run');
  });
}

final class _Ports
    implements
        CurationPipeline,
        ManifestRebuilder,
        ProductReviewGateway,
        CatalogRescraper {
  int pipelineCalls = 0, reviewCalls = 0, rescrapeCalls = 0;
  @override
  Future<CuratorManifest> runPipeline(
      {required String sourceImagePath,
      List<int>? imageBytes,
      PipelineProgressCallback? onProgress}) async {
    pipelineCalls++;
    return CuratorManifest(
        sourceImage: sourceImagePath,
        canvasWidth: 400,
        canvasHeight: 400,
        items: [
          CuratorItem(
              id: 'item_1',
              name: 'Notebook',
              category: 'Other',
              isPersonal: false,
              quantity: 1,
              price: 0,
              priceCurrency: 'USD',
              description: '',
              targetUrl: 'https://www.target.com/p/-/A-12345678',
              imageUrl: '',
              bounds: const ItemLayoutBounds(x: 0, y: 0, width: 10, height: 10),
              polygon: const [],
              centroid: const CuratorPoint(5, 5))
        ]);
  }

  @override
  Future<CuratorManifest> rebuildManifest(CuratorManifest manifest) async =>
      manifest;
  @override
  Future<List<TargetProductCandidate>> fetchLiveCandidates(
      CuratorItem item) async {
    reviewCalls++;
    return [];
  }

  @override
  Future<TargetProductCandidate?> fetchProductByTargetUrl(String url) async =>
      null;
  @override
  Future<CatalogRescrapeResult> rescrapeAll(
      {required List<CuratorItem> items,
      CatalogRescrapeProgressCallback? onProgress}) async {
    rescrapeCalls++;
    return CatalogRescrapeResult(
        items: items, successfulItemCount: items.length, failedItemCount: 0);
  }
}

import 'dart:async';

import 'package:shopitem_curator/core/bloc/curator_bloc.dart';
import 'package:shopitem_curator/core/bloc/curator_event.dart';
import 'package:shopitem_curator/core/bloc/curator_state.dart';
import 'package:shopitem_curator/core/contracts/catalog_gateways.dart';
import 'package:shopitem_curator/core/contracts/curator_use_cases.dart';
import 'package:shopitem_curator/core/contracts/user_visible_failure.dart';
import 'package:shopitem_curator/core/models/curator_item.dart';
import 'package:shopitem_curator/core/repositories/item_repository.dart';
import 'package:shopitem_curator/core/services/curation_pipeline_service.dart';
import 'package:shopitem_curator/core/services/target_catalog_rescraper.dart';
import 'package:shopitem_curator/core/services/target_fetcher_service.dart';
import 'package:test/test.dart';

void main() {
  group('CuratorBloc async request ordering', () {
    test('only the latest image pipeline may publish progress and loaded data',
        () async {
      final harness = _BlocHarness();
      addTearDown(harness.bloc.dispose);

      harness.bloc.add(const SelectSourceImageEvent('first.jpg'));
      await _waitUntil(() => harness.pipeline.requests.length == 1);

      harness.bloc.add(const SelectSourceImageEvent('second.jpg'));
      await _waitUntil(() => harness.pipeline.requests.length == 2);

      harness.pipeline.requests[1].complete(_manifest('second.jpg'));
      await _waitUntil(
        () => switch (harness.bloc.state) {
          CuratorLoadedState(:final selectedSourceImage) =>
            selectedSourceImage == 'second.jpg',
          _ => false,
        },
      );

      harness.pipeline.requests[0].reportProgress('stale progress', 0.9);
      harness.pipeline.requests[0].complete(_manifest('first.jpg'));
      await _flushAsyncWork();

      final state = harness.bloc.state;
      expect(state, isA<CuratorLoadedState>());
      expect((state as CuratorLoadedState).selectedSourceImage, 'second.jpg');
      expect(state.manifest.sourceImage, 'second.jpg');
    });

    test('late progress from the completed latest pipeline cannot regress UI',
        () async {
      final harness = _BlocHarness();
      addTearDown(harness.bloc.dispose);

      harness.bloc.add(const SelectSourceImageEvent('latest.jpg'));
      await _waitUntil(() => harness.pipeline.requests.length == 1);
      harness.pipeline.requests.single.complete(_manifest('latest.jpg'));
      await _waitUntil(() => harness.bloc.state is CuratorLoadedState);

      harness.pipeline.requests.single.reportProgress('late progress', 0.5);
      await _flushAsyncWork();

      expect(harness.bloc.state, isA<CuratorLoadedState>());
      expect(
        (harness.bloc.state as CuratorLoadedState).manifest.sourceImage,
        'latest.jpg',
      );
    });

    test('both review entry events use the same candidate loading behavior',
        () async {
      for (final event in <CuratorEvent>[
        const StartItemReviewEvent('item_1'),
        const FetchLiveCandidatesEvent('item_1'),
      ]) {
        final harness = _BlocHarness();
        addTearDown(harness.bloc.dispose);
        await harness.loadInitialManifest();

        harness.bloc.add(event);
        await _waitUntil(() => harness.fetcher.candidateRequests.length == 1);
        harness.fetcher.candidateRequests.single
            .complete([_candidate('candidate')]);
        await _waitUntil(
          () => switch (harness.bloc.state) {
            CuratorLoadedState(:final detectedCandidates) =>
              detectedCandidates.isNotEmpty,
            _ => false,
          },
        );

        final state = harness.bloc.state as CuratorLoadedState;
        expect(state.reviewingItemId, 'item_1');
        expect(state.detectedCandidates.single.id, 'candidate');
        expect(state.reviewStatus, ReviewStatus.success);
        expect(state.reviewErrorMessage, isNull);
      }
    });

    test('candidate search exposes loading and empty states', () async {
      final harness = _BlocHarness();
      addTearDown(harness.bloc.dispose);
      await harness.loadInitialManifest();

      harness.bloc.add(const StartItemReviewEvent('item_1'));
      await _waitUntil(() => harness.fetcher.candidateRequests.length == 1);

      var state = harness.bloc.state as CuratorLoadedState;
      expect(state.reviewStatus, ReviewStatus.loading);
      expect(state.reviewErrorMessage, isNull);

      harness.fetcher.candidateRequests.single.complete(const []);
      await _waitUntil(
        () =>
            (harness.bloc.state as CuratorLoadedState).reviewStatus ==
            ReviewStatus.empty,
      );

      state = harness.bloc.state as CuratorLoadedState;
      expect(state.detectedCandidates, isEmpty);
      expect(state.reviewErrorMessage, isNull);
    });

    test('candidate search exposes a failure instead of an endless spinner',
        () async {
      final harness = _BlocHarness();
      addTearDown(harness.bloc.dispose);
      await harness.loadInitialManifest();

      harness.bloc.add(const StartItemReviewEvent('item_1'));
      await _waitUntil(() => harness.fetcher.candidateRequests.length == 1);
      harness.fetcher.candidateRequests.single
          .completeError(StateError('candidate network unavailable'));

      await _waitUntil(
        () =>
            (harness.bloc.state as CuratorLoadedState).reviewStatus ==
            ReviewStatus.failure,
      );

      final state = harness.bloc.state as CuratorLoadedState;
      expect(state.reviewErrorMessage, contains('잠시 후 다시 시도'));
      expect(
        state.reviewErrorMessage,
        isNot(contains('candidate network unavailable')),
      );
      expect(state.detectedCandidates, isEmpty);
    });

    test('URL inspection exposes empty, failure, and success states', () async {
      final harness = _BlocHarness();
      addTearDown(harness.bloc.dispose);
      await harness.loadInitialManifest();

      harness.bloc.add(const StartItemReviewEvent('item_1'));
      await _waitUntil(() => harness.fetcher.candidateRequests.length == 1);
      harness.fetcher.candidateRequests.single.complete(const []);
      await _waitUntil(
        () =>
            (harness.bloc.state as CuratorLoadedState).reviewStatus ==
            ReviewStatus.empty,
      );

      harness.bloc.add(const InspectTargetUrlEvent(
        itemId: 'item_1',
        targetUrl: 'https://www.target.com/p/missing/-/A-1',
      ));
      await _waitUntil(() => harness.fetcher.urlInspectionRequests.length == 1);
      expect(
        (harness.bloc.state as CuratorLoadedState).urlInspectionStatus,
        UrlInspectionStatus.loading,
      );
      harness.fetcher.urlInspectionRequests[0].complete(null);
      await _waitUntil(
        () =>
            (harness.bloc.state as CuratorLoadedState).urlInspectionStatus ==
            UrlInspectionStatus.empty,
      );

      harness.bloc.add(const InspectTargetUrlEvent(
        itemId: 'item_1',
        targetUrl: 'https://www.target.com/p/error/-/A-2',
      ));
      await _waitUntil(() => harness.fetcher.urlInspectionRequests.length == 2);
      harness.fetcher.urlInspectionRequests[1]
          .completeError(StateError('inspection failed'));
      await _waitUntil(
        () =>
            (harness.bloc.state as CuratorLoadedState).urlInspectionStatus ==
            UrlInspectionStatus.failure,
      );
      expect(
        (harness.bloc.state as CuratorLoadedState).urlInspectionErrorMessage,
        allOf(
          contains('잠시 후 다시 시도'),
          isNot(contains('inspection failed')),
        ),
      );

      harness.bloc.add(const InspectTargetUrlEvent(
        itemId: 'item_1',
        targetUrl: 'https://www.target.com/p/found/-/A-3',
      ));
      await _waitUntil(() => harness.fetcher.urlInspectionRequests.length == 3);
      harness.fetcher.urlInspectionRequests[2]
          .complete(_candidate('inspected'));
      await _waitUntil(
        () =>
            (harness.bloc.state as CuratorLoadedState).urlInspectionStatus ==
            UrlInspectionStatus.success,
      );

      final state = harness.bloc.state as CuratorLoadedState;
      expect(state.detectedCandidates.first.id, 'inspected');
      expect(state.reviewStatus, ReviewStatus.success);
      expect(state.urlInspectionErrorMessage, isNull);
    });

    test('a late candidate response is ignored after review cancellation',
        () async {
      final harness = _BlocHarness();
      addTearDown(harness.bloc.dispose);
      await harness.loadInitialManifest();

      harness.bloc.add(const StartItemReviewEvent('item_1'));
      await _waitUntil(() => harness.fetcher.candidateRequests.length == 1);

      harness.bloc.add(const CancelItemReviewEvent('item_1'));
      await _waitUntil(
        () => switch (harness.bloc.state) {
          CuratorLoadedState(:final reviewingItemId) => reviewingItemId == null,
          _ => false,
        },
      );

      harness.fetcher.candidateRequests.single.complete([_candidate('late')]);
      await _flushAsyncWork();

      final state = harness.bloc.state as CuratorLoadedState;
      expect(state.reviewingItemId, isNull);
      expect(state.detectedCandidates, isEmpty);
      expect(state.excludedItemIds, contains('item_1'));
      expect(state.reviewStatus, ReviewStatus.idle);
      expect(state.urlInspectionStatus, UrlInspectionStatus.idle);
    });

    test('a late candidate response cannot undo a replacement', () async {
      final harness = _BlocHarness();
      addTearDown(harness.bloc.dispose);
      await harness.loadInitialManifest();

      harness.bloc.add(const StartItemReviewEvent('item_1'));
      await _waitUntil(() => harness.fetcher.candidateRequests.length == 1);

      harness.bloc.add(const ReplaceItemImageEvent(
        itemId: 'item_1',
        newImageUrl: 'replacement.png',
        newName: 'Replacement',
        newPrice: 12.34,
        newTargetUrl: '',
      ));
      await _waitUntil(
        () => switch (harness.bloc.state) {
          CuratorLoadedState(:final reviewingItemId) => reviewingItemId == null,
          _ => false,
        },
      );

      harness.fetcher.candidateRequests.single.complete([_candidate('late')]);
      await _flushAsyncWork();

      final state = harness.bloc.state as CuratorLoadedState;
      expect(state.detectedCandidates, isEmpty);
      expect(state.allItems.single.name, 'Replacement');
      expect(state.allItems.single.imageUrl, 'replacement.png');
      expect(state.allItems.single.targetUrl, isEmpty);
      expect(state.manifest.canvasImage, isEmpty);
      expect(state.allItems.single.polygon, isNotEmpty);
    });

    test('stale cross-item cancel and replacement cannot mutate active review',
        () async {
      final harness = _BlocHarness();
      addTearDown(harness.bloc.dispose);

      harness.bloc.add(const SelectSourceImageEvent('initial.jpg'));
      await _waitUntil(() => harness.pipeline.requests.length == 1);
      harness.pipeline.requests.single.complete(_manifest(
        'initial.jpg',
        items: [_item(), _item(id: 'item_2', name: 'Notebook')],
      ));
      await _waitUntil(() => harness.bloc.state is CuratorLoadedState);

      harness.bloc.add(const StartItemReviewEvent('item_1'));
      await _waitUntil(() => harness.fetcher.candidateRequests.length == 1);
      harness.bloc.add(const StartItemReviewEvent('item_2'));
      await _waitUntil(() => harness.fetcher.candidateRequests.length == 2);

      harness.bloc.add(const CancelItemReviewEvent('item_1'));
      await _flushAsyncWork();

      var state = harness.bloc.state as CuratorLoadedState;
      expect(state.reviewingItemId, 'item_2');
      expect(state.allItems.first.isApproved, isTrue);

      harness.bloc.add(const ReplaceItemImageEvent(
        itemId: 'item_1',
        newImageUrl: 'stale-replacement.png',
        newName: 'Stale replacement',
      ));
      await _flushAsyncWork();

      state = harness.bloc.state as CuratorLoadedState;
      expect(state.reviewingItemId, 'item_2');
      expect(state.allItems.first.name, 'Backpack');
      expect(state.allItems.first.imageUrl, 'item.png');
    });

    test('candidate failure preserves a successful custom URL candidate',
        () async {
      final harness = _BlocHarness();
      addTearDown(harness.bloc.dispose);
      await harness.loadInitialManifest();

      harness.bloc.add(const StartItemReviewEvent('item_1'));
      await _waitUntil(() => harness.fetcher.candidateRequests.length == 1);
      harness.bloc.add(const InspectTargetUrlEvent(
        itemId: 'item_1',
        targetUrl: 'https://www.target.com/p/custom/-/A-3',
      ));
      await _waitUntil(() => harness.fetcher.urlInspectionRequests.length == 1);
      harness.fetcher.urlInspectionRequests.single
          .complete(_candidate('custom'));
      await _waitUntil(
        () => (harness.bloc.state as CuratorLoadedState)
            .detectedCandidates
            .isNotEmpty,
      );

      harness.fetcher.candidateRequests.single
          .completeError(StateError('SECRET_candidate_response'));
      await _flushAsyncWork();

      final state = harness.bloc.state as CuratorLoadedState;
      expect(state.detectedCandidates.map((item) => item.id), ['custom']);
      expect(state.reviewStatus, ReviewStatus.success);
      expect(state.reviewErrorMessage, isNot(contains('SECRET')));
    });

    test('replacement rebuild failure remains loaded and exposes a warning',
        () async {
      final harness = _BlocHarness(
        manifestRebuilder: const _FailingManifestRebuilder(),
      );
      addTearDown(harness.bloc.dispose);
      await harness.loadInitialManifest();

      harness.bloc.add(const StartItemReviewEvent('item_1'));
      await _waitUntil(() => harness.fetcher.candidateRequests.length == 1);

      harness.bloc.add(const ReplaceItemImageEvent(
        itemId: 'item_1',
        newImageUrl: 'replacement.png',
      ));
      await _waitUntil(
        () => switch (harness.bloc.state) {
          CuratorLoadedState(:final manifestRebuildWarning) =>
            manifestRebuildWarning != null,
          _ => false,
        },
      );

      final state = harness.bloc.state as CuratorLoadedState;
      expect(state.manifest.canvasImage, isEmpty);
      expect(state.allItems.single.imageUrl, 'replacement.png');
      expect(state.allItems.single.polygon, hasLength(4));
      expect(state.manifestRebuildWarning, contains('잠시 후 다시 시도'));
      expect(
        state.manifestRebuildWarning,
        isNot(contains('forced rebuild failure')),
      );
    });

    test('a late candidate response is ignored after changing steps', () async {
      final harness = _BlocHarness();
      addTearDown(harness.bloc.dispose);
      await harness.loadInitialManifest();

      harness.bloc.add(const StartItemReviewEvent('item_1'));
      await _waitUntil(() => harness.fetcher.candidateRequests.length == 1);

      harness.bloc.add(const ChangeStepEvent(CuratorStep.hoveringImage));
      await _waitUntil(
        () => switch (harness.bloc.state) {
          CuratorLoadedState(:final currentStep) =>
            currentStep == CuratorStep.hoveringImage,
          _ => false,
        },
      );

      harness.fetcher.candidateRequests.single.complete([_candidate('late')]);
      await _flushAsyncWork();

      final state = harness.bloc.state as CuratorLoadedState;
      expect(state.currentStep, CuratorStep.hoveringImage);
      expect(state.reviewingItemId, isNull);
      expect(state.detectedCandidates, isEmpty);
    });

    test('starting a new pipeline safely invalidates an in-flight rescrape',
        () async {
      final harness = _BlocHarness();
      addTearDown(harness.bloc.dispose);
      await harness.loadInitialManifest();

      harness.bloc.add(const RescrapeAllEvent());
      await _waitUntil(() => harness.fetcher.resolutionRequests.length == 1);

      harness.bloc.add(const SelectSourceImageEvent('replacement-source.jpg'));
      await _waitUntil(() => harness.pipeline.requests.length == 2);
      harness.pipeline.requests[1]
          .complete(_manifest('replacement-source.jpg'));
      await _waitUntil(
        () => switch (harness.bloc.state) {
          CuratorLoadedState(:final selectedSourceImage) =>
            selectedSourceImage == 'replacement-source.jpg',
          _ => false,
        },
      );

      harness.fetcher.resolutionRequests.single.complete(null);
      await _flushAsyncWork();

      final state = harness.bloc.state as CuratorLoadedState;
      expect(state.selectedSourceImage, 'replacement-source.jpg');
      expect(state.manifest.sourceImage, 'replacement-source.jpg');
    });

    test('duplicate rescrape and approval mutations are ignored while busy',
        () async {
      final harness = _BlocHarness();
      addTearDown(harness.bloc.dispose);
      await harness.loadInitialManifest();

      harness.bloc.add(const RescrapeAllEvent());
      await _waitUntil(() => harness.fetcher.resolutionRequests.length == 1);
      harness.bloc
        ..add(const RescrapeAllEvent())
        ..add(const ToggleItemInclusionEvent('item_1'));
      await _flushAsyncWork();

      expect(harness.fetcher.resolutionRequests, hasLength(1));
      var state = harness.bloc.state as CuratorLoadedState;
      expect(state.isRescraping, isTrue);
      expect(state.allItems.single.isApproved, isTrue);

      harness.fetcher.resolutionRequests.single.complete(null);
      await _waitUntil(
        () => (harness.bloc.state as CuratorLoadedState).isRescraping == false,
      );
      state = harness.bloc.state as CuratorLoadedState;
      expect(state.allItems.single.isApproved, isTrue);
      expect(state.rescrapeStatus, contains('실패'));
    });

    test('late rescrape progress cannot re-enter the busy state', () async {
      final rescraper = _ControlledCatalogRescraper();
      final harness = _BlocHarness(catalogRescraper: rescraper);
      addTearDown(harness.bloc.dispose);
      await harness.loadInitialManifest();

      harness.bloc.add(const RescrapeAllEvent());
      await _waitUntil(() => rescraper.hasRequest);
      rescraper.complete(CatalogRescrapeResult(
        items: [_item()],
        successfulItemCount: 0,
        failedItemCount: 1,
      ));
      await _waitUntil(
        () => !(harness.bloc.state as CuratorLoadedState).isRescraping,
      );
      final terminalStatus =
          (harness.bloc.state as CuratorLoadedState).rescrapeStatus;

      rescraper.reportProgress(1, 1, _item());
      await _flushAsyncWork();

      final state = harness.bloc.state as CuratorLoadedState;
      expect(state.isRescraping, isFalse);
      expect(state.rescrapeStatus, terminalStatus);
      expect(state.rescrapeStatus, contains('실패'));
    });

    test('raw failures never leak secrets but safe failures remain actionable',
        () async {
      final harness = _BlocHarness();
      addTearDown(harness.bloc.dispose);

      harness.bloc.add(const SelectSourceImageEvent('secret.jpg'));
      await _waitUntil(() => harness.pipeline.requests.length == 1);
      harness.pipeline.requests.single
          .completeError(StateError('SECRET_pipeline_token'));
      await _waitUntil(() => harness.bloc.state is CuratorErrorState);
      var errorState = harness.bloc.state as CuratorErrorState;
      expect(errorState.errorMessage, isNot(contains('SECRET')));

      harness.bloc.add(const LoadCuratorItemsEvent('SECRET_manifest_content'));
      await _waitUntil(
        () =>
            harness.bloc.state is CuratorErrorState &&
            !identical(harness.bloc.state, errorState),
      );
      errorState = harness.bloc.state as CuratorErrorState;
      expect(errorState.errorMessage, isNot(contains('SECRET')));

      harness.bloc.add(const InitializationFailedEvent(
        SimpleUserVisibleFailure('백엔드 준비 확인에 실패했습니다.'),
      ));
      await _waitUntil(
        () => switch (harness.bloc.state) {
          CuratorInitializationErrorState(:final errorMessage) =>
            errorMessage.contains('백엔드 준비 확인'),
          _ => false,
        },
      );
      final initializationError =
          harness.bloc.state as CuratorInitializationErrorState;
      expect(initializationError.errorMessage, contains('백엔드 준비 확인'));
    });

    test('backend waiting is visible but cannot overwrite active pipeline',
        () async {
      final harness = _BlocHarness();
      addTearDown(harness.bloc.dispose);

      harness.bloc.add(const InitializationWaitingEvent(
        SimpleUserVisibleFailure('프록시 준비 확인 중입니다.'),
      ));
      await _waitUntil(
        () => switch (harness.bloc.state) {
          CuratorInitialState(:final statusMessage) =>
            statusMessage.contains('자동으로 계속') &&
                statusMessage.contains('프록시 준비 확인'),
          _ => false,
        },
      );

      harness.bloc.add(const SelectSourceImageEvent('active.jpg'));
      await _waitUntil(() => harness.pipeline.requests.length == 1);
      final processingState = harness.bloc.state;

      harness.bloc.add(const InitializationWaitingEvent(
        SimpleUserVisibleFailure('late readiness callback'),
      ));
      await _flushAsyncWork();

      expect(identical(harness.bloc.state, processingState), isTrue);
      expect(harness.bloc.state, isA<CuratorProcessingState>());
    });

    test('pending work cannot mutate state after dispose', () async {
      final harness = _BlocHarness();

      harness.bloc.add(const SelectSourceImageEvent('pending.jpg'));
      await _waitUntil(() => harness.pipeline.requests.length == 1);
      final stateAtDispose = harness.bloc.state;

      harness.bloc.dispose();
      harness.pipeline.requests.single.reportProgress('late progress', 0.8);
      harness.pipeline.requests.single.complete(_manifest('late.jpg'));
      harness.bloc.add(const SelectSourceImageEvent('ignored.jpg'));
      await _flushAsyncWork();

      expect(identical(harness.bloc.state, stateAtDispose), isTrue);
    });
  });
}

final class _BlocHarness {
  _BlocHarness({
    ManifestRebuilder? manifestRebuilder,
    CatalogRescraper? catalogRescraper,
  })  : pipeline = _ControlledPipelineService(),
        fetcher = _ControlledTargetFetcher() {
    bloc = CuratorBloc(
      itemRepository: const DefaultItemRepository(),
      pipelineService: pipeline,
      manifestRebuilder: manifestRebuilder ?? pipeline,
      productReviewGateway: fetcher,
      catalogRescraper: catalogRescraper ?? TargetCatalogRescraper(fetcher),
      onDispose: fetcher.close,
    );
  }

  final _ControlledPipelineService pipeline;
  final _ControlledTargetFetcher fetcher;
  late final CuratorBloc bloc;

  Future<void> loadInitialManifest() async {
    bloc.add(const SelectSourceImageEvent('initial.jpg'));
    await _waitUntil(() => pipeline.requests.length == 1);
    pipeline.requests.single.complete(_manifest('initial.jpg'));
    await _waitUntil(() => bloc.state is CuratorLoadedState);
  }
}

final class _FailingManifestRebuilder implements ManifestRebuilder {
  const _FailingManifestRebuilder();

  @override
  Future<CuratorManifest> rebuildManifest(CuratorManifest manifest) {
    return Future<CuratorManifest>.error(
      StateError('forced rebuild failure'),
    );
  }
}

final class _ControlledPipelineService extends CurationPipelineService {
  _ControlledPipelineService()
      : super(
          ocrService: const _UnusedExtractionGateway(),
          targetFetcherService: const _UnusedProductGateway(),
        );

  final List<_PipelineRequest> requests = [];

  @override
  Future<CuratorManifest> runPipeline({
    required String sourceImagePath,
    List<int>? imageBytes,
    PipelineProgressCallback? onProgress,
  }) {
    final request = _PipelineRequest(onProgress);
    requests.add(request);
    return request.future;
  }
}

final class _UnusedExtractionGateway implements ItemExtractionGateway {
  const _UnusedExtractionGateway();

  @override
  Future<List<ExtractedItemEntry>> extractItemsFromImage(
    String imagePath, {
    List<int>? imageBytes,
  }) =>
      Future.error(UnsupportedError('Unused test gateway.'));
}

final class _UnusedProductGateway implements TargetProductGateway {
  const _UnusedProductGateway();

  @override
  Future<List<TargetProductData>> fetchTargetProducts(
    List<ExtractedItemEntry> entries, {
    void Function(int completed, int total, ExtractedItemEntry currentItem)?
        onProgress,
  }) =>
      Future.error(UnsupportedError('Unused test gateway.'));
}

final class _PipelineRequest {
  _PipelineRequest(this._onProgress);

  final PipelineProgressCallback? _onProgress;
  final Completer<CuratorManifest> _completer = Completer<CuratorManifest>();

  Future<CuratorManifest> get future => _completer.future;

  void reportProgress(String description, double progress) {
    _onProgress?.call(description, progress);
  }

  void complete(CuratorManifest manifest) {
    _completer.complete(manifest);
  }

  void completeError(Object error) {
    _completer.completeError(error);
  }
}

final class _ControlledCatalogRescraper implements CatalogRescraper {
  final Completer<CatalogRescrapeResult> _completer =
      Completer<CatalogRescrapeResult>();
  CatalogRescrapeProgressCallback? _onProgress;

  bool get hasRequest => _onProgress != null;

  @override
  Future<CatalogRescrapeResult> rescrapeAll({
    required List<CuratorItem> items,
    CatalogRescrapeProgressCallback? onProgress,
  }) {
    _onProgress = onProgress;
    return _completer.future;
  }

  void complete(CatalogRescrapeResult result) => _completer.complete(result);

  void reportProgress(int completed, int total, CuratorItem item) {
    _onProgress?.call(completed, total, item);
  }
}

final class _ControlledTargetFetcher extends TargetFetcherService {
  final List<Completer<List<TargetProductCandidate>>> candidateRequests = [];
  final List<Completer<TargetPdpResolutionResult?>> resolutionRequests = [];
  final List<Completer<TargetProductCandidate?>> urlInspectionRequests = [];

  @override
  Future<List<TargetProductCandidate>> fetchLiveCandidates(CuratorItem item) {
    final completer = Completer<List<TargetProductCandidate>>();
    candidateRequests.add(completer);
    return completer.future;
  }

  @override
  Future<TargetPdpResolutionResult?> resolveTargetProductPdpUrl(String query) {
    final completer = Completer<TargetPdpResolutionResult?>();
    resolutionRequests.add(completer);
    return completer.future;
  }

  @override
  Future<TargetProductCandidate?> fetchProductByTargetUrl(String url) {
    final completer = Completer<TargetProductCandidate?>();
    urlInspectionRequests.add(completer);
    return completer.future;
  }
}

CuratorManifest _manifest(
  String sourceImage, {
  List<CuratorItem>? items,
}) {
  return CuratorManifest(
    sourceImage: sourceImage,
    canvasImage: 'data:image/png;base64,stale-canvas',
    canvasWidth: 1200,
    canvasHeight: 820,
    items: items ?? [_item()],
  );
}

CuratorItem _item({
  String id = 'item_1',
  String name = 'Backpack',
}) {
  return CuratorItem(
    id: id,
    name: name,
    category: 'Personal',
    isPersonal: true,
    quantity: 1,
    price: 10,
    priceCurrency: 'USD',
    description: 'Test item',
    targetUrl: 'https://www.target.com/p/test/-/A-1',
    imageUrl: 'item.png',
    bounds: const ItemLayoutBounds(x: 0, y: 0, width: 100, height: 100),
    polygon: [],
    centroid: const CuratorPoint(50, 50),
  );
}

TargetProductCandidate _candidate(String id) {
  return TargetProductCandidate(
    id: id,
    name: id,
    price: 11,
    imageUrl: '$id.png',
    targetUrl: 'https://www.target.com/p/$id/-/A-2',
    description: 'Candidate $id',
  );
}

Future<void> _waitUntil(bool Function() condition) async {
  for (var attempt = 0; attempt < 1000; attempt++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  fail('Timed out waiting for asynchronous BLoC work.');
}

Future<void> _flushAsyncWork() async {
  for (var turn = 0; turn < 10; turn++) {
    await Future<void>.delayed(Duration.zero);
  }
}

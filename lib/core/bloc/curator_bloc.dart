// Pure Dart BLoC (Zero Flutter Dependencies)

import 'dart:async';
import 'dart:typed_data';

import '../contracts/curator_use_cases.dart';
import '../contracts/browser_project_gateway.dart';
import '../contracts/matching_strategy_provider.dart';
import '../models/matching_options.dart';
import '../contracts/user_visible_failure.dart';
import '../contracts/source_document_repository.dart';
import '../models/curator_item.dart';
import '../repositories/item_repository.dart';
import 'curator_event.dart';
import 'curator_state.dart';

/// CuratorBloc manages the 3-step curation workflow, item approval, and interactive re-review.
/// Strictly Pure Dart with ZERO dependencies on package:flutter.
class CuratorBloc {
  CuratorBloc({
    required ItemRepository itemRepository,
    required CurationPipeline pipelineService,
    required ManifestRebuilder manifestRebuilder,
    required ProductReviewGateway productReviewGateway,
    required CatalogRescraper catalogRescraper,
    SourceDocumentRepository? documentRepository,
    BrowserProjectGateway? browserProjectGateway,
    MatchingStrategyProvider? matchingStrategyProvider,
    bool startInBrowserMode = false,
    this.browserPollInterval = const Duration(seconds: 6),
    void Function()? onDispose,
  })  : _repository = itemRepository,
        _pipelineService = pipelineService,
        _manifestRebuilder = manifestRebuilder,
        _productReviewGateway = productReviewGateway,
        _catalogRescraper = catalogRescraper,
        _documentRepository = documentRepository,
        _browserProjects = browserProjectGateway,
        _matchingProvider = matchingStrategyProvider,
        _browserMode = startInBrowserMode && browserProjectGateway != null,
        _onDispose = onDispose {
    if (documentRepository != null) _sourceImages = [];
    _eventSubscription = _eventController.stream.listen((event) {
      unawaited(_handleEvent(event));
    });
  }

  final ItemRepository _repository;
  final CurationPipeline _pipelineService;
  final ManifestRebuilder _manifestRebuilder;
  final ProductReviewGateway _productReviewGateway;
  final CatalogRescraper _catalogRescraper;
  final SourceDocumentRepository? _documentRepository;
  final BrowserProjectGateway? _browserProjects;
  final MatchingStrategyProvider? _matchingProvider;
  MatchingOptions _matchingOptions = MatchingOptions();
  List<MatchingCapability> _matchingCapabilities = const [];
  String _matchingStatus = '';
  bool _loadingMatchingCapabilities = false;
  bool get canConfigureMatching => _matchingProvider != null;
  MatchingServices get _matchingServices =>
      _matchingProvider?.servicesFor(_matchingOptions) ??
      MatchingServices(
          pipeline: _pipelineService,
          review: _productReviewGateway,
          rescraper: _catalogRescraper);
  final Duration browserPollInterval;
  bool _browserMode;
  bool get browserMode => _browserMode;
  bool get canUseBrowserMode => _browserProjects != null;
  Timer? _browserTimer;
  bool _browserRefreshing = false;
  int _browserSelectionRequestId = 0;
  List<String> _sourceImages = List.of(defaultCuratorSourceImages);
  bool _documentBusy = false;
  String? _lastSourceImage;
  List<int>? _lastSourceBytes;
  bool get canManageDocuments => _documentRepository != null;
  final void Function()? _onDispose;

  final StreamController<CuratorEvent> _eventController =
      StreamController<CuratorEvent>.broadcast();
  final StreamController<CuratorState> _stateController =
      StreamController<CuratorState>.broadcast();
  late final StreamSubscription<CuratorEvent> _eventSubscription;

  CuratorState _currentState = const CuratorInitialState();
  bool _isDisposed = false;
  int _pipelineRequestId = 0;
  int _reviewRequestId = 0;
  int _urlInspectionRequestId = 0;
  int _rescrapeRequestId = 0;
  int _manifestRebuildRequestId = 0;
  Future<void>? _closing;

  /// Stream to listen to state changes.
  Stream<CuratorState> get stateStream => _stateController.stream;

  /// Current synchronous state snapshot.
  CuratorState get state => _currentState;

  void add(CuratorEvent event) {
    if (!_isDisposed && !_eventController.isClosed) {
      _eventController.add(event);
    }
  }

  void _emit(CuratorState newState) {
    if (_isDisposed) return;
    if (newState is CuratorLoadedState) {
      newState = newState.copyWith(
          matchingOptions: _matchingOptions,
          matchingCapabilities: _matchingCapabilities,
          matchingStatus: _matchingStatus);
    }
    _currentState = newState;
    if (!_stateController.isClosed) {
      _stateController.add(newState);
    }
  }

  bool _isCurrentPipelineRequest(int requestId) {
    return !_isDisposed && requestId == _pipelineRequestId;
  }

  bool _isCurrentReviewRequest(int requestId, String itemId) {
    if (_isDisposed || requestId != _reviewRequestId) return false;
    final state = _currentState;
    return state is CuratorLoadedState && state.reviewingItemId == itemId;
  }

  bool _isCurrentUrlInspectionRequest({
    required int reviewRequestId,
    required int urlInspectionRequestId,
    required String itemId,
  }) {
    return !_isDisposed &&
        reviewRequestId == _reviewRequestId &&
        urlInspectionRequestId == _urlInspectionRequestId &&
        _currentState is CuratorLoadedState &&
        (_currentState as CuratorLoadedState).reviewingItemId == itemId;
  }

  bool _isCurrentRescrapeRequest(int requestId) {
    return !_isDisposed && requestId == _rescrapeRequestId;
  }

  bool _isCurrentManifestRebuildRequest(int requestId) {
    return !_isDisposed && requestId == _manifestRebuildRequestId;
  }

  void _invalidateReviewRequest() {
    _reviewRequestId++;
    _urlInspectionRequestId++;
  }

  void _invalidateRescrapeRequest() {
    _rescrapeRequestId++;
  }

  void _invalidateManifestRebuildRequest() {
    _manifestRebuildRequestId++;
  }

  Future<void> _handleEvent(CuratorEvent event) async {
    // A storage mutation cannot overlap selection, review, or another mutation.
    if (_documentBusy) return;
    if (_browserMode &&
        (event is RescrapeAllEvent ||
            event is FetchLiveCandidatesEvent ||
            event is InspectTargetUrlEvent ||
            event is StartItemReviewEvent)) {
      return;
    }
    switch (event) {
      case RefreshMatchingCapabilitiesEvent():
        await _refreshMatchingCapabilities();
      case SetMatchingStrategyEvent(:final strategy, :final enabled):
        final state = _currentState;
        if (_browserMode ||
            state is! CuratorLoadedState ||
            state.isRescraping ||
            state.reviewStatus == ReviewStatus.loading ||
            state.urlInspectionStatus == UrlInspectionStatus.loading ||
            (enabled &&
                !_matchingCapabilities
                    .any((c) => c.strategy == strategy && c.available))) {
          return;
        }
        _matchingOptions = _matchingOptions.toggle(strategy, enabled);
        _emit(state);
      case RunMatchingEvent():
        final state = _currentState;
        if (_browserMode ||
            state is! CuratorLoadedState ||
            state.isRescraping ||
            state.reviewStatus == ReviewStatus.loading ||
            state.urlInspectionStatus == UrlInspectionStatus.loading) {
          return;
        }
        final path = _lastSourceImage;
        if (path != null) {
          await _selectSourceImage(path, _lastSourceBytes, runMatching: true);
        }
      case SetBrowserModeEvent(:final enabled):
        if (_browserProjects == null ||
            _browserMode == enabled ||
            (_currentState is CuratorLoadedState &&
                (_currentState as CuratorLoadedState).isRescraping)) {
          return;
        }
        _browserMode = enabled;
        _browserTimer?.cancel();
        final path = _lastSourceImage;
        if (path != null) {
          await _selectSourceImage(path, _lastSourceBytes);
        } else {
          _emit(_emptyDocumentState());
        }
      case PairBrowserEvent():
        await _pairBrowser();
      case RefreshBrowserEvent():
        await _refreshBrowser();
      case ApplyBrowserSelectionEvent():
        await _applyBrowserSelection();
      case LoadSourceDocumentsEvent(:final selectFirst):
        await _loadDocuments(selectFirst: selectFirst);
      case ImportSourceDocumentEvent(:final filename, :final bytes):
        await _importDocument(filename, bytes);
      case DeleteSourceDocumentEvent(:final sourceImagePath):
        await _deleteDocument(sourceImagePath);
      case RetrySourceDocumentEvent():
        final path = _lastSourceImage;
        if (path != null &&
            (_documentRepository == null || _sourceImages.contains(path))) {
          await _selectSourceImage(path, _lastSourceBytes, runMatching: true);
        }
      case SelectSourceImageEvent(:final sourceImagePath, :final imageBytes):
        await _selectSourceImage(sourceImagePath, imageBytes);

      case InitializationFailedEvent(:final failure):
        _pipelineRequestId++;
        _invalidateReviewRequest();
        _invalidateRescrapeRequest();
        _invalidateManifestRebuildRequest();
        _emit(CuratorInitializationErrorState(
          '초기화 중 오류 발생: ${failure.userVisibleMessage}',
        ));

      case InitializationRetryStartedEvent():
        if (_currentState is CuratorInitializationErrorState) {
          _emit(const CuratorInitialState(
            statusMessage: '백엔드 준비 상태를 다시 확인하는 중...',
          ));
        }

      case InitializationWaitingEvent(:final failure):
        final state = _currentState;
        if (state is! CuratorInitialState) break;
        final statusMessage = '백엔드 시작을 기다리는 중입니다. 준비되면 자동으로 '
            '계속합니다.\n${failure.userVisibleMessage}';
        if (state.statusMessage != statusMessage) {
          _emit(CuratorInitialState(statusMessage: statusMessage));
        }

      case ChangeStepEvent(:final targetStep):
        if (_browserMode && targetStep == CuratorStep.hoveringImage) {
          await _applyBrowserSelection(openCanvas: true);
          return;
        }
        final state = _currentState;
        if (state is CuratorLoadedState &&
            !state.isRescraping &&
            (targetStep == CuratorStep.documentInput ||
                (targetStep == CuratorStep.scrappingConfirmation &&
                    state.hasChecklist) ||
                state.allItems.isNotEmpty)) {
          _invalidateReviewRequest();
          _emit(state.copyWith(
            currentStep: targetStep,
            hoveredItemId: () => null,
            selectedItemId: () => null,
            reviewingItemId: () => null,
            detectedCandidates: const [],
            reviewStatus: ReviewStatus.idle,
            reviewErrorMessage: () => null,
            urlInspectionStatus: UrlInspectionStatus.idle,
            urlInspectionErrorMessage: () => null,
          ));
        }

      case NextStepEvent():
        final state = _currentState;
        if (_browserMode &&
            state is CuratorLoadedState &&
            state.currentStep == CuratorStep.scrappingConfirmation) {
          await _applyBrowserSelection(openCanvas: true);
          return;
        }
        if (state is CuratorLoadedState &&
            !state.isRescraping &&
            (state.allItems.isNotEmpty ||
                (state.currentStep == CuratorStep.documentInput &&
                    state.hasChecklist))) {
          _invalidateReviewRequest();
          final nextStep = switch (state.currentStep) {
            CuratorStep.documentInput => CuratorStep.scrappingConfirmation,
            CuratorStep.scrappingConfirmation => CuratorStep.hoveringImage,
            CuratorStep.hoveringImage => CuratorStep.hoveringImage,
          };
          _emit(state.copyWith(
            currentStep: nextStep,
            hoveredItemId: () => null,
            selectedItemId: () => null,
            reviewingItemId: () => null,
            detectedCandidates: const [],
            reviewStatus: ReviewStatus.idle,
            reviewErrorMessage: () => null,
            urlInspectionStatus: UrlInspectionStatus.idle,
            urlInspectionErrorMessage: () => null,
          ));
        }

      case PreviousStepEvent():
        final state = _currentState;
        if (state is CuratorLoadedState && !state.isRescraping) {
          _invalidateReviewRequest();
          final prevStep = switch (state.currentStep) {
            CuratorStep.documentInput => CuratorStep.documentInput,
            CuratorStep.scrappingConfirmation => CuratorStep.documentInput,
            CuratorStep.hoveringImage => CuratorStep.scrappingConfirmation,
          };
          _emit(state.copyWith(
            currentStep: prevStep,
            hoveredItemId: () => null,
            selectedItemId: () => null,
            reviewingItemId: () => null,
            detectedCandidates: const [],
            reviewStatus: ReviewStatus.idle,
            reviewErrorMessage: () => null,
            urlInspectionStatus: UrlInspectionStatus.idle,
            urlInspectionErrorMessage: () => null,
          ));
        }

      case ToggleItemInclusionEvent(:final itemId):
        final state = _currentState;
        if (state is CuratorLoadedState && !state.isRescraping) {
          final updatedItems = state.manifest.items.map((item) {
            return item.id == itemId
                ? item.copyWith(isApproved: !item.isApproved)
                : item;
          }).toList();
          _emit(state.copyWith(
            manifest: state.manifest.copyWith(items: updatedItems),
          ));
        }

      case ApproveItemEvent(:final itemId):
        final state = _currentState;
        if (state is CuratorLoadedState && !state.isRescraping) {
          final updatedItems = state.manifest.items.map((it) {
            if (it.id == itemId) {
              return it.copyWith(isApproved: true);
            }
            return it;
          }).toList();

          _emit(state.copyWith(
            manifest: state.manifest.copyWith(items: updatedItems),
          ));
        }

      case StartItemReviewEvent(:final itemId):
        await _fetchCandidatesForReview(itemId);

      case ReplaceItemImageEvent(
          :final itemId,
          :final newImageUrl,
          :final newName,
          :final newPrice,
          :final newTargetUrl,
        ):
        final state = _currentState;
        if (state is CuratorLoadedState &&
            !state.isRescraping &&
            state.reviewingItemId == itemId) {
          _invalidateReviewRequest();
          final requestId = ++_manifestRebuildRequestId;
          final updatedItems = state.manifest.items.map((it) {
            if (it.id == itemId) {
              final bounds = it.bounds;
              return it.copyWith(
                imageUrl: newImageUrl,
                name: newName ?? it.name,
                price: newPrice ?? it.price,
                targetUrl: newTargetUrl ?? it.targetUrl,
                polygon: _rectangularFallback(bounds),
                centroid: CuratorPoint(
                  bounds.x + (bounds.width / 2),
                  bounds.y + (bounds.height / 2),
                ),
                isApproved: true,
                isPreciselySegmented: false,
              );
            }
            return it;
          }).toList();

          final provisionalManifest = state.manifest.copyWith(
            canvasImage: '',
            items: updatedItems,
          );
          _emit(state.copyWith(
            manifest: provisionalManifest,
            reviewingItemId: () => null,
            detectedCandidates: const [],
            reviewStatus: ReviewStatus.idle,
            reviewErrorMessage: () => null,
            urlInspectionStatus: UrlInspectionStatus.idle,
            urlInspectionErrorMessage: () => null,
            manifestRebuildWarning: () => null,
          ));

          try {
            final rebuilt =
                await _manifestRebuilder.rebuildManifest(provisionalManifest);
            if (!_isCurrentManifestRebuildRequest(requestId)) return;
            final currentState = _currentState;
            if (currentState is! CuratorLoadedState) return;
            _emit(currentState.copyWith(
              manifest: _preserveCurrentApprovals(
                rebuilt,
                currentState.manifest.items,
              ),
              manifestRebuildWarning: () => null,
            ));
          } catch (error) {
            // The provisional manifest deliberately has no flattened canvas
            // and uses safe rectangular geometry, so stale pixels/contours
            // can never survive a failed rebuild.
            if (!_isCurrentManifestRebuildRequest(requestId)) return;
            final currentState = _currentState;
            if (currentState is! CuratorLoadedState) return;
            _emit(currentState.copyWith(
              manifestRebuildWarning: () => '이미지는 교체되었지만 캔버스와 윤곽선을 '
                  '다시 생성하지 못했습니다: '
                  '${_userVisibleFailureMessage(error, fallback: '잠시 후 다시 시도해 주세요.')}',
            ));
          }
        }

      case CancelItemReviewEvent(:final itemId):
        final state = _currentState;
        if (state is CuratorLoadedState &&
            !state.isRescraping &&
            state.reviewingItemId == itemId) {
          _invalidateReviewRequest();
          final updatedItems = state.manifest.items.map((item) {
            return item.id == itemId ? item.copyWith(isApproved: false) : item;
          }).toList();
          _emit(state.copyWith(
            manifest: state.manifest.copyWith(items: updatedItems),
            reviewingItemId: () => null,
            detectedCandidates: const [],
            reviewStatus: ReviewStatus.idle,
            reviewErrorMessage: () => null,
            urlInspectionStatus: UrlInspectionStatus.idle,
            urlInspectionErrorMessage: () => null,
          ));
        }

      case LoadCuratorItemsEvent(:final jsonManifestContent):
        final requestId = ++_pipelineRequestId;
        _invalidateReviewRequest();
        _invalidateRescrapeRequest();
        _invalidateManifestRebuildRequest();
        _emit(const CuratorLoadingState());
        try {
          final manifest = await _repository.loadManifest(jsonManifestContent);
          if (!_isCurrentPipelineRequest(requestId)) return;
          final selectedSourceImage = manifest.sourceImage.trim().isEmpty
              ? defaultCuratorSourceImages.first
              : manifest.sourceImage;
          final availableSourceImages = <String>[
            ...defaultCuratorSourceImages,
            if (!defaultCuratorSourceImages.contains(selectedSourceImage))
              selectedSourceImage,
          ];
          _emit(CuratorLoadedState(
            manifest: manifest,
            selectedSourceImage: selectedSourceImage,
            availableSourceImages: availableSourceImages,
          ));
        } catch (e) {
          if (!_isCurrentPipelineRequest(requestId)) return;
          _emit(CuratorErrorState(
            '항목을 불러오지 못했습니다: '
            '${_userVisibleFailureMessage(e, fallback: '매니페스트 형식을 확인해 주세요.')}',
          ));
        }

      case HoverItemEvent(:final itemId):
        final state = _currentState;
        if (state is CuratorLoadedState) {
          if (state.hoveredItemId != itemId) {
            _emit(state.copyWith(hoveredItemId: () => itemId));
          }
        }

      case SelectItemEvent(:final itemId):
        final state = _currentState;
        if (state is CuratorLoadedState) {
          final newSelectedId =
              (state.selectedItemId == itemId) ? null : itemId;
          _emit(state.copyWith(selectedItemId: () => newSelectedId));
        }

      case DismissItemEvent():
        final state = _currentState;
        if (state is CuratorLoadedState) {
          _emit(state.copyWith(selectedItemId: () => null));
        }

      // ──────────────────────────────────────────────────────────────────
      // 재스크래핑: 기존 에셋 삭제 후 Target에서 실시간 재수집
      // ──────────────────────────────────────────────────────────────────
      case RescrapeAllEvent():
        final state = _currentState;
        if (state is CuratorLoadedState && !state.isRescraping) {
          final requestId = ++_rescrapeRequestId;
          final rebuildRequestId = ++_manifestRebuildRequestId;
          _invalidateReviewRequest();
          _emit(state.copyWith(
            isRescraping: true,
            rescrapeProgress: 0.0,
            rescrapeStatus: '실시간 Target 재수집 준비 중...',
            reviewingItemId: () => null,
            detectedCandidates: const [],
            reviewStatus: ReviewStatus.idle,
            reviewErrorMessage: () => null,
            urlInspectionStatus: UrlInspectionStatus.idle,
            urlInspectionErrorMessage: () => null,
          ));

          var acceptsProgress = true;
          try {
            final rescrapeResult =
                await _matchingServices.rescraper.rescrapeAll(
              items: state.allItems,
              onProgress: (completed, total, item) {
                if (!acceptsProgress || !_isCurrentRescrapeRequest(requestId)) {
                  return;
                }
                final progressState = _currentState;
                if (progressState is! CuratorLoadedState ||
                    !progressState.isRescraping) {
                  return;
                }

                final progress = total == 0 ? 1.0 : completed / total;
                final status = '$completed/$total: ${item.name} 재수집 완료';

                _emit(progressState.copyWith(
                  isRescraping: true,
                  rescrapeProgress: progress,
                  rescrapeStatus: status,
                ));
              },
            );
            acceptsProgress = false;
            if (!_isCurrentRescrapeRequest(requestId)) return;

            final currentState = _currentState;
            if (currentState is! CuratorLoadedState) return;
            if (rescrapeResult.isTotalFailure) {
              _invalidateRescrapeRequest();
              _invalidateManifestRebuildRequest();
              _emit(currentState.copyWith(
                isRescraping: false,
                rescrapeProgress: 1.0,
                rescrapeStatus: '재스크래핑 실패: Target 상품을 갱신하지 못해 기존 데이터를 유지합니다.',
              ));
              return;
            }

            final safeItems = rescrapeResult.items.map((item) {
              final bounds = item.bounds;
              return item.copyWith(
                polygon: _rectangularFallback(bounds),
                centroid: CuratorPoint(
                  bounds.x + (bounds.width / 2),
                  bounds.y + (bounds.height / 2),
                ),
                isPreciselySegmented: false,
              );
            }).toList(growable: false);
            final provisionalManifest = currentState.manifest.copyWith(
              canvasImage: '',
              items: safeItems,
            );
            _emit(currentState.copyWith(
              manifest: provisionalManifest,
              isRescraping: true,
              rescrapeProgress: 1.0,
              rescrapeStatus: '상품 재수집 완료. 캔버스와 윤곽선을 다시 생성하는 중...',
              manifestRebuildWarning: () => null,
            ));

            final rebuilt =
                await _manifestRebuilder.rebuildManifest(provisionalManifest);
            if (!_isCurrentRescrapeRequest(requestId) ||
                !_isCurrentManifestRebuildRequest(rebuildRequestId)) {
              return;
            }
            final rebuiltState = _currentState;
            if (rebuiltState is! CuratorLoadedState) return;
            _invalidateRescrapeRequest();
            _invalidateManifestRebuildRequest();
            _emit(rebuiltState.copyWith(
              manifest: rebuilt,
              isRescraping: false,
              rescrapeProgress: 1.0,
              rescrapeStatus: rescrapeResult.isComplete
                  ? '재스크래핑 완료! 각 항목을 다시 검수해 주세요.'
                  : '재스크래핑 부분 완료: '
                      '${rescrapeResult.successfulItemCount}/'
                      '${rescrapeResult.totalItemCount}개 갱신. '
                      '실패 항목은 기존 데이터를 유지합니다.',
              reviewingItemId: () => null,
              detectedCandidates: const [],
              manifestRebuildWarning: () => null,
            ));
          } catch (e) {
            acceptsProgress = false;
            if (!_isCurrentRescrapeRequest(requestId)) return;
            final currentState = _currentState;
            if (currentState is! CuratorLoadedState) return;
            _invalidateRescrapeRequest();
            _invalidateManifestRebuildRequest();
            _emit(currentState.copyWith(
              isRescraping: false,
              rescrapeStatus: '재스크래핑 오류: '
                  '${_userVisibleFailureMessage(e, fallback: '요청을 처리하지 못했습니다. 잠시 후 다시 시도해 주세요.')}',
            ));
          }
        }

      // ──────────────────────────────────────────────────────────────────
      // 재검토: Target에서 실시간 대체 후보 상품 3~5개 검색
      // ──────────────────────────────────────────────────────────────────
      case FetchLiveCandidatesEvent(:final itemId):
        await _fetchCandidatesForReview(itemId);

      // ──────────────────────────────────────────────────────────────────
      // 사용자 지정 Target URL 실시간 파싱 및 후보 추가 (2단계 PDP 채택)
      // ──────────────────────────────────────────────────────────────────
      case InspectTargetUrlEvent(:final itemId, :final targetUrl):
        await _inspectTargetUrl(itemId, targetUrl);
    }
  }

  CuratorLoadedState _emptyDocumentState(
          {String path = '', Uint8List? bytes, String? error}) =>
      CuratorLoadedState(
        manifest: CuratorManifest(
            sourceImage: path,
            canvasWidth: 1200,
            canvasHeight: 820,
            items: const []),
        availableSourceImages: _sourceImages,
        selectedSourceImage: path,
        sourceImageBytes: bytes,
        documentErrorMessage: error,
      );

  void _invalidateDocumentWork() {
    _browserTimer?.cancel();
    _pipelineRequestId++;
    _invalidateReviewRequest();
    _invalidateRescrapeRequest();
    _invalidateManifestRebuildRequest();
  }

  Future<void> _loadDocuments({required bool selectFirst}) async {
    unawaited(_refreshMatchingCapabilities());
    final repository = _documentRepository;
    if (repository == null) return;
    _documentBusy = true;
    _invalidateDocumentWork();
    final previous = _currentState;
    final base = previous is CuratorLoadedState
        ? previous.copyWith(browserBusy: false)
        : _emptyDocumentState();
    _emit(base.copyWith(
        documentOperationInProgress: true, documentErrorMessage: () => null));
    try {
      _sourceImages = List.of(await repository.listDocuments());
      if (_isDisposed) return;
      if (_sourceImages.contains(base.selectedSourceImage)) {
        _emit(base.copyWith(
            availableSourceImages: _sourceImages,
            documentOperationInProgress: false,
            documentErrorMessage: () => null));
      } else {
        _lastSourceImage = null;
        _lastSourceBytes = null;
        _emit(_emptyDocumentState());
      }
    } catch (error) {
      _emit(base.copyWith(
          documentOperationInProgress: false,
          documentErrorMessage: () => _userVisibleFailureMessage(error,
              fallback: '문서 목록을 불러오지 못했습니다. 새로고침해 주세요.')));
      return;
    } finally {
      _documentBusy = false;
      _scheduleBrowserRefresh();
    }
    if (selectFirst && !_isDisposed && _sourceImages.isNotEmpty) {
      final path = _sourceImages.contains('assets/images/new.jpg')
          ? 'assets/images/new.jpg'
          : _sourceImages.first;
      await _selectSourceImage(path, null);
    }
  }

  Future<void> _importDocument(String filename, List<int> bytes) async {
    final repository = _documentRepository;
    final state = _currentState;
    if (repository == null ||
        state is! CuratorLoadedState ||
        state.isRescraping) {
      return;
    }
    _documentBusy = true;
    _invalidateDocumentWork();
    _emit(state.copyWith(
        documentOperationInProgress: true, documentErrorMessage: () => null));
    late final String path;
    try {
      path = await repository.importDocument(filename, bytes);
      if (_isDisposed) return;
      _sourceImages = {..._sourceImages, path}.toList()..sort();
      _emit(state.copyWith(
          availableSourceImages: _sourceImages,
          documentOperationInProgress: false));
    } catch (error) {
      _emit(state.copyWith(
          documentOperationInProgress: false,
          browserBusy: false,
          documentErrorMessage: () => _userVisibleFailureMessage(error,
              fallback: '문서를 추가하지 못했습니다. 다시 시도하세요.')));
      return;
    } finally {
      _documentBusy = false;
      _scheduleBrowserRefresh();
    }
    if (!_isDisposed) await _selectSourceImage(path, bytes);
  }

  Future<void> _deleteDocument(String path) async {
    final repository = _documentRepository;
    final state = _currentState;
    if (repository == null ||
        state is! CuratorLoadedState ||
        state.isRescraping ||
        !_sourceImages.contains(path)) {
      return;
    }
    _documentBusy = true;
    _invalidateDocumentWork();
    _emit(state.copyWith(
        documentOperationInProgress: true, documentErrorMessage: () => null));
    try {
      await repository.deleteDocument(path);
      if (_isDisposed) return;
      _sourceImages = _sourceImages.where((value) => value != path).toList();
      if (_lastSourceImage == path) {
        _lastSourceImage = null;
        _lastSourceBytes = null;
      }
      if (state.selectedSourceImage == path) {
        _emit(_emptyDocumentState());
      } else {
        _emit(state.copyWith(
            availableSourceImages: _sourceImages,
            documentOperationInProgress: false,
            browserBusy: false,
            documentErrorMessage: () => null));
      }
    } catch (error) {
      _emit(state.copyWith(
          documentOperationInProgress: false,
          browserBusy: false,
          documentErrorMessage: () => _userVisibleFailureMessage(error,
              fallback: '문서 삭제에 실패했습니다. 목록을 새로고침한 뒤 다시 시도하세요.')));
    } finally {
      _documentBusy = false;
      _scheduleBrowserRefresh();
    }
  }

  Future<void> _refreshMatchingCapabilities() async {
    final provider = _matchingProvider;
    if (provider == null || _loadingMatchingCapabilities || _isDisposed) return;
    _loadingMatchingCapabilities = true;
    try {
      _matchingCapabilities = List.unmodifiable(await provider.capabilities());
      _matchingStatus = '설정을 선택한 뒤 자동 매칭 실행을 누르세요. 선택하지 않으면 기본 HTTP 조회입니다.';
    } catch (_) {
      _matchingCapabilities = const [];
      _matchingStatus = '전략 목록을 확인하지 못했습니다. 백엔드를 업데이트·재시작한 뒤 새로고침하세요.';
    } finally {
      _loadingMatchingCapabilities = false;
      if (_currentState case final CuratorLoadedState state) _emit(state);
    }
  }

  Future<void> _selectSourceImage(String path, List<int>? imageBytes,
      {bool runMatching = false}) async {
    if (_documentRepository != null && !_sourceImages.contains(path)) return;
    _invalidateDocumentWork();
    final requestId = _pipelineRequestId;
    final services = _matchingServices;
    final options = _matchingOptions;
    _lastSourceImage = path;
    _lastSourceBytes = imageBytes;
    Uint8List? bytes;
    _emit(CuratorProcessingState(
        selectedSourceImage: path,
        currentStep: '문서 불러오기 및 준비물 목록 추출 중 (로컬 OCR)...',
        progress: 0.05));
    try {
      final loaded =
          imageBytes ?? await _documentRepository?.readDocument(path);
      if (!_isCurrentPipelineRequest(requestId)) return;
      if (loaded != null) {
        bytes = Uint8List.fromList(loaded).asUnmodifiableView();
        _lastSourceBytes = bytes;
      }
      if (_browserMode && _browserProjects != null) {
        final project = await _browserProjects.openBrowserProject(path);
        if (!_isCurrentPipelineRequest(requestId)) return;
        _emit(_emptyDocumentState(path: path, bytes: bytes)
            .copyWith(browserProject: project));
        if (project.selectedCount > 0) await _applyBrowserSelection();
        _scheduleBrowserRefresh();
        return;
      }
      if (_matchingProvider != null && !runMatching) {
        _emit(_emptyDocumentState(path: path, bytes: bytes));
        return;
      }
      final timer = Stopwatch()..start();
      final manifest = await services.pipeline.runPipeline(
        sourceImagePath: path,
        imageBytes: bytes,
        onProgress: (description, progress) {
          if (_isCurrentPipelineRequest(requestId) &&
              _currentState is CuratorProcessingState) {
            _emit(CuratorProcessingState(
                selectedSourceImage: path,
                currentStep: description,
                progress: progress));
          }
        },
      );
      if (!_isCurrentPipelineRequest(requestId)) return;
      timer.stop();
      final links = manifest.items.where((i) => i.targetUrl.isNotEmpty).length;
      _matchingStatus =
          '최근 실행 (${path.split('/').last}): ${options.isDefault ? '기본 HTTP' : options.enabled.map((s) => s.title).join(' + ')} · '
          '${(timer.elapsedMilliseconds / 1000).toStringAsFixed(1)}초 (전체 파이프라인) · 구매 링크 $links/${manifest.items.length}개. 저장된 후보가 포함될 수 있습니다.';
      _emit(CuratorLoadedState(
          manifest: manifest,
          selectedSourceImage: path,
          availableSourceImages: _sourceImages,
          sourceImageBytes: bytes));
    } catch (error) {
      if (!_isCurrentPipelineRequest(requestId)) return;
      final message = '파이프라인 실행 중 오류 발생: '
          '${_userVisibleFailureMessage(error, fallback: '요청을 처리하지 못했습니다. 잠시 후 다시 시도해 주세요.')}';
      if (_documentRepository != null) {
        // Retain the input menu even when OCR fails so the failed document can
        // be retried, replaced, or deleted (including the very last document).
        _emit(_emptyDocumentState(path: path, bytes: bytes, error: message));
      } else {
        _emit(CuratorErrorState(message));
      }
    }
  }

  void _scheduleBrowserRefresh() {
    _browserTimer?.cancel();
    final current = _currentState;
    if (!_isDisposed &&
        _browserMode &&
        browserPollInterval > Duration.zero &&
        current is CuratorLoadedState &&
        current.browserProject != null) {
      _browserTimer =
          Timer(browserPollInterval, () => add(const RefreshBrowserEvent()));
    }
  }

  Future<void> _pairBrowser() async {
    final current = _currentState;
    if (current is! CuratorLoadedState ||
        current.browserProject == null ||
        current.browserBusy ||
        current.isRescraping) {
      return;
    }
    final requestId = _pipelineRequestId;
    _emit(current.copyWith(browserBusy: true, browserMessage: () => null));
    try {
      final code = await _browserProjects!
          .pairBrowserProject(current.browserProject!.id);
      if (!_isCurrentPipelineRequest(requestId)) return;
      final latest = _currentState as CuratorLoadedState;
      _emit(latest.copyWith(
          browserPairingCode: () => code,
          browserBusy: false,
          browserMessage: () => '2분 안에 Target 탭의 확장 프로그램에 코드를 붙여 넣으세요.'));
    } catch (_) {
      if (_isCurrentPipelineRequest(requestId) &&
          _currentState is CuratorLoadedState) {
        _emit((_currentState as CuratorLoadedState).copyWith(
            browserBusy: false,
            browserMessage: () => '연결 코드를 만들지 못했습니다. 백엔드를 확인한 뒤 다시 시도하세요.'));
      }
    }
  }

  Future<void> _refreshBrowser() async {
    final current = _currentState;
    if (!_browserMode ||
        _browserRefreshing ||
        current is! CuratorLoadedState ||
        current.browserProject == null ||
        current.isRescraping ||
        current.browserBusy) {
      _scheduleBrowserRefresh();
      return;
    }
    final requestId = _pipelineRequestId;
    _browserRefreshing = true;
    final selectionRequestId = _browserSelectionRequestId;
    try {
      final project = await _browserProjects!
          .refreshBrowserProject(current.browserProject!.id);
      if (selectionRequestId != _browserSelectionRequestId ||
          !_isCurrentPipelineRequest(requestId) ||
          _currentState is! CuratorLoadedState) {
        return;
      }
      final latest = _currentState as CuratorLoadedState;
      if (project.revision != latest.browserProject?.revision) {
        _emit(latest.copyWith(
            browserProject: project,
            manifest:
                latest.manifest.copyWith(items: const [], canvasImage: ''),
            currentStep: latest.currentStep == CuratorStep.hoveringImage
                ? CuratorStep.scrappingConfirmation
                : latest.currentStep,
            browserMessage: () =>
                '새 선택 내용이 도착했습니다. 캔버스 시각화 버튼을 누르면 최신 선택을 적용합니다.'));
      } else if (latest.browserMessage?.startsWith('연결을 확인 중') ?? false) {
        _emit(latest.copyWith(browserMessage: () => '백엔드 연결이 복구되었습니다.'));
      }
    } catch (_) {
      if (selectionRequestId == _browserSelectionRequestId &&
          _isCurrentPipelineRequest(requestId) &&
          _currentState is CuratorLoadedState) {
        _emit((_currentState as CuratorLoadedState).copyWith(
            browserMessage: () =>
                '연결을 확인 중입니다. 저장된 선택은 유지됩니다. 백엔드 재시작 후 확장 프로그램은 다시 연결해 주세요.'));
      }
    } finally {
      _browserRefreshing = false;
      _scheduleBrowserRefresh();
    }
  }

  Future<void> _applyBrowserSelection({bool openCanvas = false}) async {
    final current = _currentState;
    if (!_browserMode ||
        current is! CuratorLoadedState ||
        current.browserProject == null ||
        current.isRescraping ||
        current.browserBusy) {
      return;
    }
    final requestId = _pipelineRequestId;
    ++_browserSelectionRequestId; // Invalidate an older in-flight poll.
    _browserTimer?.cancel();
    _emit(current.copyWith(
        isRescraping: true,
        rescrapeStatus: '브라우저에서 고른 최신 상품 확인 중...',
        browserMessage: () => null));
    try {
      final project = await _browserProjects!
          .refreshBrowserProject(current.browserProject!.id);
      if (!_isCurrentPipelineRequest(requestId) ||
          _currentState is! CuratorLoadedState) {
        return;
      }
      final latest = _currentState as CuratorLoadedState;
      final changed = project.revision != current.browserProject!.revision;
      final updated = latest.copyWith(
          browserProject: project,
          manifest: changed
              ? latest.manifest.copyWith(items: const [], canvasImage: '')
              : latest.manifest);
      if (project.selectedCount == 0) {
        _emit(updated.copyWith(
            isRescraping: false,
            browserMessage: () =>
                '아직 담은 상품이 없습니다. Target에서 상품을 담은 뒤 다시 눌러 주세요.'));
        return;
      }
      // Reuse a composed, unchanged selection, including the user's exclusions.
      if (!changed && latest.allItems.isNotEmpty) {
        _emit(updated.copyWith(
            isRescraping: false,
            currentStep:
                openCanvas ? CuratorStep.hoveringImage : latest.currentStep));
        return;
      }
      _emit(updated.copyWith(rescrapeStatus: '선택한 이미지로 캔버스 만드는 중...'));
      final manifest = await _browserProjects.readBrowserSelection(project);
      final rebuilt = await _manifestRebuilder.rebuildManifest(manifest);
      if (rebuilt.items.isEmpty) {
        throw StateError('No selected images were composed.');
      }
      if (!_isCurrentPipelineRequest(requestId) ||
          _currentState is! CuratorLoadedState) {
        return;
      }
      if ((_currentState as CuratorLoadedState).browserProject?.revision !=
          project.revision) {
        throw StateError('Browser selection changed during composition.');
      }
      _emit((_currentState as CuratorLoadedState).copyWith(
          manifest: rebuilt,
          isRescraping: false,
          currentStep: openCanvas
              ? CuratorStep.hoveringImage
              : (_currentState as CuratorLoadedState).currentStep,
          browserMessage: () => '선택 결과를 적용했습니다. 3단계에서 구색을 확인하세요.'));
    } catch (_) {
      if (_isCurrentPipelineRequest(requestId) &&
          _currentState is CuratorLoadedState) {
        _emit((_currentState as CuratorLoadedState).copyWith(
            isRescraping: false,
            browserMessage: () =>
                '캔버스를 만들지 못했습니다. 백엔드 연결을 확인한 뒤 캔버스 버튼을 다시 눌러 주세요.'));
      }
    } finally {
      _scheduleBrowserRefresh();
    }
  }

  Future<void> _fetchCandidatesForReview(String itemId) async {
    final state = _currentState;
    if (state is! CuratorLoadedState || state.isRescraping) return;

    final item = state.allItems.where((it) => it.id == itemId).firstOrNull;
    if (item == null) return;

    final requestId = ++_reviewRequestId;
    _urlInspectionRequestId++;
    _emit(state.copyWith(
      reviewingItemId: () => itemId,
      detectedCandidates: const [],
      reviewStatus: ReviewStatus.loading,
      reviewErrorMessage: () => null,
      urlInspectionStatus: UrlInspectionStatus.idle,
      urlInspectionErrorMessage: () => null,
    ));

    List<TargetProductCandidate> candidates;
    try {
      candidates = await _matchingServices.review.fetchLiveCandidates(item);
    } catch (error) {
      if (!_isCurrentReviewRequest(requestId, itemId)) return;
      final currentState = _currentState;
      if (currentState is! CuratorLoadedState) return;
      final hasExistingCandidate = currentState.detectedCandidates.isNotEmpty;
      _emit(currentState.copyWith(
        reviewStatus:
            hasExistingCandidate ? ReviewStatus.success : ReviewStatus.failure,
        reviewErrorMessage: () => 'Target 후보 검색 중 오류가 발생했습니다: '
            '${_userVisibleFailureMessage(error, fallback: '잠시 후 다시 시도해 주세요.')}',
      ));
      return;
    }

    if (!_isCurrentReviewRequest(requestId, itemId)) return;
    final currentState = _currentState;
    if (currentState is! CuratorLoadedState) return;

    final mergedCandidates = <TargetProductCandidate>[
      ...currentState.detectedCandidates,
      ...candidates.where(
        (candidate) => !currentState.detectedCandidates.any(
          (existing) => existing.imageUrl == candidate.imageUrl,
        ),
      ),
    ];
    _emit(currentState.copyWith(
      detectedCandidates: mergedCandidates,
      reviewStatus:
          mergedCandidates.isEmpty ? ReviewStatus.empty : ReviewStatus.success,
      reviewErrorMessage: () => null,
    ));
  }

  Future<void> _inspectTargetUrl(String itemId, String targetUrl) async {
    final state = _currentState;
    if (state is! CuratorLoadedState ||
        state.isRescraping ||
        state.reviewingItemId != itemId) {
      return;
    }

    final reviewRequestId = _reviewRequestId;
    final urlInspectionRequestId = ++_urlInspectionRequestId;
    _emit(state.copyWith(
      urlInspectionStatus: UrlInspectionStatus.loading,
      urlInspectionErrorMessage: () => null,
    ));

    TargetProductCandidate? customCandidate;
    try {
      customCandidate =
          await _matchingServices.review.fetchProductByTargetUrl(targetUrl);
    } catch (error) {
      if (!_isCurrentUrlInspectionRequest(
        reviewRequestId: reviewRequestId,
        urlInspectionRequestId: urlInspectionRequestId,
        itemId: itemId,
      )) {
        return;
      }
      final currentState = _currentState;
      if (currentState is! CuratorLoadedState) return;
      _emit(currentState.copyWith(
        urlInspectionStatus: UrlInspectionStatus.failure,
        urlInspectionErrorMessage: () => 'Target URL 검사 중 오류가 발생했습니다: '
            '${_userVisibleFailureMessage(error, fallback: '잠시 후 다시 시도해 주세요.')}',
      ));
      return;
    }

    final candidate = customCandidate;
    if (!_isCurrentUrlInspectionRequest(
      reviewRequestId: reviewRequestId,
      urlInspectionRequestId: urlInspectionRequestId,
      itemId: itemId,
    )) {
      return;
    }
    final currentState = _currentState;
    if (currentState is! CuratorLoadedState) return;

    if (candidate == null) {
      _emit(currentState.copyWith(
        urlInspectionStatus: UrlInspectionStatus.empty,
        urlInspectionErrorMessage: () => null,
      ));
      return;
    }

    final updatedCandidates = [
      candidate,
      ...currentState.detectedCandidates.where(
        (existing) => existing.imageUrl != candidate.imageUrl,
      ),
    ];
    _emit(currentState.copyWith(
      detectedCandidates: updatedCandidates,
      reviewStatus: ReviewStatus.success,
      reviewErrorMessage: () => null,
      urlInspectionStatus: UrlInspectionStatus.success,
      urlInspectionErrorMessage: () => null,
    ));
  }

  static List<CuratorPoint> _rectangularFallback(ItemLayoutBounds bounds) => [
        CuratorPoint(bounds.x, bounds.y),
        CuratorPoint(bounds.x + bounds.width, bounds.y),
        CuratorPoint(
          bounds.x + bounds.width,
          bounds.y + bounds.height,
        ),
        CuratorPoint(bounds.x, bounds.y + bounds.height),
      ];

  static CuratorManifest _preserveCurrentApprovals(
    CuratorManifest rebuilt,
    List<CuratorItem> currentItems,
  ) {
    final approvalById = <String, bool>{
      for (final item in currentItems) item.id: item.isApproved,
    };
    return rebuilt.copyWith(
      items: [
        for (final item in rebuilt.items)
          item.copyWith(
            isApproved: approvalById[item.id] ?? item.isApproved,
          ),
      ],
    );
  }

  static String _userVisibleFailureMessage(
    Object error, {
    required String fallback,
  }) {
    if (error case UserVisibleFailure(:final userVisibleMessage)) {
      final message = userVisibleMessage.trim();
      if (message.isNotEmpty) return message;
    }
    return fallback;
  }

  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    _isDisposed = true;
    _browserTimer?.cancel();
    _pipelineRequestId++;
    _reviewRequestId++;
    _urlInspectionRequestId++;
    _rescrapeRequestId++;
    _manifestRebuildRequestId++;
    await _eventSubscription.cancel();
    await _eventController.close();
    await _stateController.close();
    _onDispose?.call();
  }

  /// Compatibility bridge for synchronous framework disposal hooks.
  /// Tests and non-Flutter owners should await [close] instead.
  void dispose() => unawaited(close());
}

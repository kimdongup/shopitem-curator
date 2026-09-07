// Pure Dart BLoC States (Zero Flutter Dependencies)

import '../models/curator_item.dart';
import 'dart:typed_data';

const defaultCuratorSourceImages = <String>[
  'assets/images/new.jpg',
  'assets/images/media_1787068853075.jpg',
];

/// The 3 distinct workflow steps of the application:
/// 1. documentInput: Upload or select the school supplies checklist photo.
/// 2. scrappingConfirmation: Review and confirm matched Target items, images, and prices.
/// 3. hoveringImage: Interactive canvas with grayscale-to-color animations and speech balloon tags.
enum CuratorStep {
  documentInput(
    title: '1. 문서 입력 (Document Input)',
    shortTitle: '문서 입력',
    subtitle: '준비물 목록이 적힌 사진을 선택하고 텍스트를 추출합니다.',
  ),
  scrappingConfirmation(
    title: '2. 스크래핑 확인 (Scrapping Confirmation)',
    shortTitle: '스크래핑 확인',
    subtitle: 'Target에서 수집된 상품 사진(누끼/배경 제거)과 가격/정보를 검수하고 OK 또는 재검토를 진행합니다.',
  ),
  hoveringImage(
    title: '3. 캔버스 시각화 (Hovering Image)',
    shortTitle: '캔버스 시각화',
    subtitle: '합성된 단일 캔버스에서 마우스 호버 시 컬러 전환 및 말풍선 가격 태그를 확인합니다.',
  );

  const CuratorStep({
    required this.title,
    required this.shortTitle,
    required this.subtitle,
  });

  final String title;
  final String shortTitle;
  final String subtitle;
}

/// Loading lifecycle for the automatic Target candidate search.
enum ReviewStatus {
  idle,
  loading,
  success,
  empty,
  failure,
}

/// Loading lifecycle for a user-supplied Target product or image URL.
enum UrlInspectionStatus {
  idle,
  loading,
  success,
  empty,
  failure,
}

sealed class CuratorState {
  const CuratorState();
}

const defaultCuratorInitializationMessage = '큐레이터를 초기화하는 중...';

/// Initial uninitialized state.
final class CuratorInitialState extends CuratorState {
  const CuratorInitialState({
    this.statusMessage = defaultCuratorInitializationMessage,
  });

  final String statusMessage;
}

/// Loading state while reading local initial data.
final class CuratorLoadingState extends CuratorState {
  const CuratorLoadingState();
}

/// Terminal startup error whose retry must pass through backend readiness
/// again before any source image bytes are submitted.
final class CuratorInitializationErrorState extends CuratorState {
  const CuratorInitializationErrorState(this.errorMessage);

  final String errorMessage;
}

/// Processing state while running the pipeline on a selected image.
final class CuratorProcessingState extends CuratorState {
  const CuratorProcessingState({
    required this.selectedSourceImage,
    required this.currentStep,
    required this.progress,
  });

  final String selectedSourceImage;
  final String currentStep;
  final double progress;
}

/// Main loaded state containing step navigation, manifest, review state, and active selections.
final class CuratorLoadedState extends CuratorState {
  CuratorLoadedState({
    required this.manifest,
    this.currentStep = CuratorStep.documentInput,
    List<String> availableSourceImages = defaultCuratorSourceImages,
    this.selectedSourceImage = 'assets/images/new.jpg',
    this.reviewingItemId,
    List<TargetProductCandidate> detectedCandidates = const [],
    this.reviewStatus = ReviewStatus.idle,
    this.reviewErrorMessage,
    this.urlInspectionStatus = UrlInspectionStatus.idle,
    this.urlInspectionErrorMessage,
    this.hoveredItemId,
    this.selectedItemId,
    this.isRescraping = false,
    this.rescrapeProgress = 0.0,
    this.rescrapeStatus = '',
    this.manifestRebuildWarning,
    this.sourceImageBytes,
    this.documentOperationInProgress = false,
    this.documentErrorMessage,
  })  : availableSourceImages = List.unmodifiable(availableSourceImages),
        detectedCandidates = List.unmodifiable(detectedCandidates);

  final CuratorManifest manifest;
  final CuratorStep currentStep;
  final List<String> availableSourceImages;
  final String selectedSourceImage;
  final Uint8List? sourceImageBytes;
  final bool documentOperationInProgress;
  final String? documentErrorMessage;
  final String? reviewingItemId;
  final List<TargetProductCandidate> detectedCandidates;
  final ReviewStatus reviewStatus;
  final String? reviewErrorMessage;
  final UrlInspectionStatus urlInspectionStatus;
  final String? urlInspectionErrorMessage;
  final String? hoveredItemId;
  final String? selectedItemId;

  /// True while re-scraping all items in the background
  final bool isRescraping;

  /// 0.0 – 1.0 progress of re-scraping
  final double rescrapeProgress;

  /// Human-readable progress message during re-scrape
  final String rescrapeStatus;

  /// Recoverable warning from rebuilding the flattened canvas and contours.
  ///
  /// The manifest remains usable with safe per-item fallback geometry, so this
  /// warning does not replace the loaded state with a terminal error state.
  final String? manifestRebuildWarning;

  /// All items in manifest
  List<CuratorItem> get allItems => manifest.items;

  /// Approval is the single source of truth for inclusion.
  Set<String> get excludedItemIds => Set.unmodifiable(
        manifest.items.where((item) => !item.isApproved).map((item) => item.id),
      );

  /// Active confirmed items (excluding unchecked ones)
  List<CuratorItem> get items => List.unmodifiable(
        manifest.items.where((item) => item.isApproved),
      );

  CuratorItem? get reviewingItem {
    if (reviewingItemId == null) return null;
    return allItems.where((it) => it.id == reviewingItemId).firstOrNull;
  }

  CuratorItem? get hoveredItem {
    if (hoveredItemId == null) return null;
    return items.where((it) => it.id == hoveredItemId).firstOrNull;
  }

  CuratorItem? get selectedItem {
    if (selectedItemId == null) return null;
    return items.where((it) => it.id == selectedItemId).firstOrNull;
  }

  bool get isAnyItemActive => hoveredItemId != null || selectedItemId != null;

  CuratorLoadedState copyWith({
    CuratorManifest? manifest,
    CuratorStep? currentStep,
    List<String>? availableSourceImages,
    String? selectedSourceImage,
    String? Function()? reviewingItemId,
    List<TargetProductCandidate>? detectedCandidates,
    ReviewStatus? reviewStatus,
    String? Function()? reviewErrorMessage,
    UrlInspectionStatus? urlInspectionStatus,
    String? Function()? urlInspectionErrorMessage,
    String? Function()? hoveredItemId,
    String? Function()? selectedItemId,
    bool? isRescraping,
    double? rescrapeProgress,
    String? rescrapeStatus,
    String? Function()? manifestRebuildWarning,
    Uint8List? sourceImageBytes,
    bool? documentOperationInProgress,
    String? Function()? documentErrorMessage,
  }) {
    return CuratorLoadedState(
      manifest: manifest ?? this.manifest,
      currentStep: currentStep ?? this.currentStep,
      availableSourceImages:
          availableSourceImages ?? this.availableSourceImages,
      selectedSourceImage: selectedSourceImage ?? this.selectedSourceImage,
      sourceImageBytes: sourceImageBytes ?? this.sourceImageBytes,
      documentOperationInProgress:
          documentOperationInProgress ?? this.documentOperationInProgress,
      documentErrorMessage: documentErrorMessage != null
          ? documentErrorMessage()
          : this.documentErrorMessage,
      reviewingItemId:
          reviewingItemId != null ? reviewingItemId() : this.reviewingItemId,
      detectedCandidates: detectedCandidates ?? this.detectedCandidates,
      reviewStatus: reviewStatus ?? this.reviewStatus,
      reviewErrorMessage: reviewErrorMessage != null
          ? reviewErrorMessage()
          : this.reviewErrorMessage,
      urlInspectionStatus: urlInspectionStatus ?? this.urlInspectionStatus,
      urlInspectionErrorMessage: urlInspectionErrorMessage != null
          ? urlInspectionErrorMessage()
          : this.urlInspectionErrorMessage,
      hoveredItemId:
          hoveredItemId != null ? hoveredItemId() : this.hoveredItemId,
      selectedItemId:
          selectedItemId != null ? selectedItemId() : this.selectedItemId,
      isRescraping: isRescraping ?? this.isRescraping,
      rescrapeProgress: rescrapeProgress ?? this.rescrapeProgress,
      rescrapeStatus: rescrapeStatus ?? this.rescrapeStatus,
      manifestRebuildWarning: manifestRebuildWarning != null
          ? manifestRebuildWarning()
          : this.manifestRebuildWarning,
    );
  }
}

/// Error state in case of failure.
final class CuratorErrorState extends CuratorState {
  const CuratorErrorState(this.errorMessage);
  final String errorMessage;
}

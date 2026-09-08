import 'package:flutter/material.dart';
import '../widgets/matching_strategy_panel.dart';
import '../adapters/html_file_saver.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../core/bloc/curator_bloc.dart';
import '../../core/bloc/curator_event.dart';
import '../../core/bloc/curator_state.dart';
import '../../core/models/target_purchase_url.dart';
import '../../core/services/html_export_service.dart';
import '../../core/services/html_imagemap_exporter.dart';
import '../theme/app_colors.dart';
import '../widgets/curator_canvas.dart';
import '../widgets/product_image.dart';
import '../widgets/review_modal.dart';
import '../widgets/source_document_menu.dart';
import '../widgets/browser_project_panel.dart';

/// 3-Step Separated Curator Screen:
/// 1. Document Input (문서 입력)
/// 2. Scrapping Confirmation (스크래핑 확인 및 OK / 재검토 검수)
/// 3. Hovering Image (인터랙티브 캔버스 & 크기조절/드래그 & HTML 이미지맵 출력)
class CuratorScreen extends StatefulWidget {
  const CuratorScreen({
    super.key,
    required this.bloc,
    this.htmlExportService = const HtmlExportService(),
    this.htmlFileSaver = saveHtmlFile,
    this.catalogProxyEnabled = true,
    this.onRetryInitialization,
  });

  final CuratorBloc bloc;
  final HtmlExportService htmlExportService;
  final HtmlFileSaver htmlFileSaver;

  /// Whether the authenticated backend catalog capability is available.
  ///
  /// Browsers never contact Target directly. This switch is intended only for
  /// deployments that deliberately run without the backend catalog routes.
  final bool catalogProxyEnabled;

  /// Re-enters the backend readiness gate after a terminal startup failure.
  final VoidCallback? onRetryInitialization;

  @override
  State<CuratorScreen> createState() => _CuratorScreenState();
}

class _CuratorScreenState extends State<CuratorScreen> {
  CuratorBloc get bloc => widget.bloc;
  List<PositionedItemExportData> _currentExportData = [];
  bool _isExporting = false;
  int _exportCompleted = 0;
  int _exportTotal = 0;

  Future<void> _launchPurchaseUrl(TargetPurchaseUrl purchaseUrl) async {
    final uri = purchaseUrl.uri;
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  Future<void> _selectSourceImageWithBytes(String imagePath) async {
    if (bloc.canManageDocuments) {
      bloc.add(SelectSourceImageEvent(imagePath));
      return;
    }
    late final List<int> bytes;
    try {
      final byteData = await rootBundle.load(imagePath);
      bytes = byteData.buffer.asUint8List(
        byteData.offsetInBytes,
        byteData.lengthInBytes,
      );
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('선택한 이미지를 불러오지 못했습니다.')),
        );
      }
      return;
    }
    bloc.add(SelectSourceImageEvent(imagePath, imageBytes: bytes));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: const bool.fromEnvironment('CURATOR_PREVIEW')
          ? AppBar(
              toolbarHeight: 38,
              title: const Text('무료 체험 · 서버 재시작 시 문서 소실',
                  style: TextStyle(fontSize: 12)),
              actions: [
                IconButton(
                  tooltip: '로그아웃',
                  onPressed: () => launchUrl(Uri.base.resolve('/logout'),
                      webOnlyWindowName: '_self'),
                  icon: const Icon(Icons.logout, size: 18),
                ),
              ],
            )
          : null,
      body: StreamBuilder<CuratorState>(
        stream: bloc.stateStream,
        initialData: bloc.state,
        builder: (context, snapshot) {
          final state = snapshot.data ?? const CuratorInitialState();

          return switch (state) {
            CuratorInitialState(:final statusMessage) => Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const CircularProgressIndicator(color: AppColors.targetRed),
                    const SizedBox(height: 16),
                    Text(
                      statusMessage,
                      style: const TextStyle(
                          color: AppColors.textSecondary, fontSize: 14),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            CuratorLoadingState() => const Center(
                child: CircularProgressIndicator(color: AppColors.targetRed),
              ),
            CuratorProcessingState(
              :final selectedSourceImage,
              :final currentStep,
              :final progress,
            ) =>
              _buildProcessingScreen(
                  context, selectedSourceImage, currentStep, progress),
            CuratorInitializationErrorState(:final errorMessage) => Center(
                child: Padding(
                  padding: const EdgeInsets.all(24.0),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.error_outline,
                          size: 48, color: AppColors.targetRed),
                      const SizedBox(height: 12),
                      Text(
                        errorMessage,
                        style: const TextStyle(
                            color: Colors.redAccent, fontSize: 15),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 16),
                      ElevatedButton(
                        key: const ValueKey('initialization_retry_button'),
                        onPressed: widget.onRetryInitialization,
                        child: const Text('백엔드 다시 확인'),
                      ),
                    ],
                  ),
                ),
              ),
            CuratorErrorState(:final errorMessage) => Center(
                child: Padding(
                  padding: const EdgeInsets.all(24.0),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.error_outline,
                          size: 48, color: AppColors.targetRed),
                      const SizedBox(height: 12),
                      Text(
                        errorMessage,
                        style: const TextStyle(
                            color: Colors.redAccent, fontSize: 15),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 16),
                      ElevatedButton(
                        onPressed: () =>
                            bloc.add(const RetrySourceDocumentEvent()),
                        child: const Text('다시 시도'),
                      ),
                    ],
                  ),
                ),
              ),
            CuratorLoadedState() => Stack(
                children: [
                  _buildLoadedWorkflow(context, state),
                  // Review Inspector Modal overlay when reviewing an item
                  if (state.reviewingItemId != null &&
                      state.reviewingItem != null)
                    _buildReviewModal(context, state),
                ],
              ),
          };
        },
      ),
    );
  }

  Widget _buildProcessingScreen(
    BuildContext context,
    String selectedSourceImage,
    String currentStep,
    double progress,
  ) {
    return Center(
      child: Container(
        constraints: const BoxConstraints(maxWidth: 540),
        padding: const EdgeInsets.all(32),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: Colors.white.withAlpha(20)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withAlpha(150),
              blurRadius: 30,
              offset: const Offset(0, 10),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            const Icon(Icons.auto_awesome,
                size: 42, color: AppColors.accentCyan),
            const SizedBox(height: 16),
            const Text(
              'Target 큐레이션 파이프라인 가동 중',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w800,
                color: AppColors.textPrimary,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '분석 중인 문서: ${selectedSourceImage.split('/').last}',
              style:
                  const TextStyle(fontSize: 13, color: AppColors.textSecondary),
            ),
            const SizedBox(height: 24),
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: LinearProgressIndicator(
                value: progress,
                minHeight: 10,
                backgroundColor: Colors.white.withAlpha(20),
                valueColor:
                    const AlwaysStoppedAnimation<Color>(AppColors.targetRed),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              currentStep,
              style: const TextStyle(
                fontSize: 14.5,
                fontWeight: FontWeight.w600,
                color: AppColors.accentCyan,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLoadedWorkflow(BuildContext context, CuratorLoadedState state) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final horizontalPadding = constraints.maxWidth < 600 ? 12.0 : 24.0;
        return SingleChildScrollView(
          padding: EdgeInsets.symmetric(
            horizontal: horizontalPadding,
            vertical: 28,
          ),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1120),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  _buildHeader(),
                  const SizedBox(height: 20),
                  _buildStepperBar(state),
                  const SizedBox(height: 28),
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 300),
                    child: switch (state.currentStep) {
                      CuratorStep.documentInput =>
                        _buildStep1DocumentInput(context, state),
                      CuratorStep.scrappingConfirmation =>
                        _buildStep2ScrappingConfirmation(context, state),
                      CuratorStep.hoveringImage =>
                        _buildStep3HoveringImage(context, state),
                    },
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildHeader() {
    return Column(
      children: [
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
              decoration: BoxDecoration(
                color: AppColors.targetRed.withAlpha(35),
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: AppColors.targetRed.withAlpha(90)),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.track_changes, size: 14, color: Color(0xFFFF6B6B)),
                  SizedBox(width: 6),
                  Text(
                    'TARGET SCHOOL SUPPLIES CURATOR (3-STEP PIPELINE)',
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w800,
                      color: Color(0xFFFF6B6B),
                      letterSpacing: 0.5,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 10),
        const Text(
          '학교 준비물 인터랙티브 큐레이터',
          style: TextStyle(
            fontSize: 26,
            fontWeight: FontWeight.w900,
            color: AppColors.textPrimary,
            letterSpacing: -0.5,
          ),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }

  Widget _buildStepperBar(CuratorLoadedState state) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 820),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withAlpha(20)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: CuratorStep.values.map((step) {
          final isCurrent = state.currentStep == step;
          final isPassed = state.currentStep.index > step.index;

          return Expanded(
            child: InkWell(
              onTap: state.isRescraping ||
                      state.browserBusy ||
                      state.documentOperationInProgress ||
                      (step != CuratorStep.documentInput &&
                          (step == CuratorStep.scrappingConfirmation
                              ? !state.hasChecklist
                              : state.allItems.isEmpty &&
                                  state.browserProject == null))
                  ? null
                  : () => bloc.add(ChangeStepEvent(step)),
              borderRadius: BorderRadius.circular(12),
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
                decoration: BoxDecoration(
                  color:
                      isCurrent ? AppColors.surfaceLight : Colors.transparent,
                  borderRadius: BorderRadius.circular(12),
                  border: isCurrent
                      ? Border.all(
                          color: AppColors.accentCyan.withAlpha(120),
                          width: 1.5)
                      : null,
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Container(
                      width: 24,
                      height: 24,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: isCurrent
                            ? AppColors.targetRed
                            : (isPassed
                                ? Colors.green.withAlpha(200)
                                : Colors.white.withAlpha(20)),
                      ),
                      child: Center(
                        child: isPassed
                            ? const Icon(Icons.check,
                                size: 14, color: Colors.white)
                            : Text(
                                '${step.index + 1}',
                                style: const TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.white),
                              ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        step.shortTitle,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight:
                              isCurrent ? FontWeight.w800 : FontWeight.w600,
                          color: isCurrent
                              ? AppColors.textPrimary
                              : (isPassed
                                  ? Colors.white70
                                  : AppColors.textSecondary),
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildManifestWarningBanner(String message) {
    return Container(
      key: const Key('manifest_rebuild_warning'),
      constraints: const BoxConstraints(maxWidth: 760),
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.orange.withAlpha(28),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.orangeAccent.withAlpha(120)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(
            Icons.warning_amber_rounded,
            size: 18,
            color: Colors.orangeAccent,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(fontSize: 12, color: Color(0xFFFFD08A)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSegmentationWarningBanner(CuratorLoadedState state) {
    final fallbackCount =
        state.allItems.where((item) => !item.isPreciselySegmented).length;
    return Container(
      key: const Key('segmentation_fallback_warning'),
      constraints: const BoxConstraints(maxWidth: 760),
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.orange.withAlpha(24),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.orangeAccent.withAlpha(100)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(
            Icons.gesture,
            size: 18,
            color: Colors.orangeAccent,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '$fallbackCount개 품목은 이미지를 디코딩하지 못해 정밀 실루엣 대신 안전한 fallback 영역을 사용합니다. 이미지를 재검토하거나 macOS에서 재스크래핑해 주세요.',
              style: const TextStyle(fontSize: 12, color: Color(0xFFFFD08A)),
            ),
          ),
        ],
      ),
    );
  }

  // ==========================================
  // Step 1: Document Input
  // ==========================================
  Widget _buildStep1DocumentInput(
      BuildContext context, CuratorLoadedState state) {
    return Column(
      key: const ValueKey('step_1_document_input'),
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Text(
          CuratorStep.documentInput.title,
          style: const TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w800,
              color: AppColors.textPrimary),
        ),
        const SizedBox(height: 6),
        Text(
          CuratorStep.documentInput.subtitle,
          style: const TextStyle(fontSize: 14, color: AppColors.textSecondary),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 20),

        // File Selection Menu
        if (bloc.canUseBrowserMode) ...[
          Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              children: [
                ChoiceChip(
                    label: const Text('브라우저에서 직접 선택'),
                    selected: bloc.browserMode,
                    onSelected:
                        state.isRescraping || state.documentOperationInProgress
                            ? null
                            : (_) => bloc.add(const SetBrowserModeEvent(true))),
                ChoiceChip(
                    label: const Text('자동 조회 · 전략 선택'),
                    selected: !bloc.browserMode,
                    onSelected: state.isRescraping ||
                            state.documentOperationInProgress
                        ? null
                        : (_) => bloc.add(const SetBrowserModeEvent(false))),
              ]),
          const SizedBox(height: 12),
        ],
        SourceDocumentMenu(
          documents: state.availableSourceImages,
          selected: state.selectedSourceImage,
          busy: state.documentOperationInProgress || state.isRescraping,
          canManage: bloc.canManageDocuments,
          onSelect: _selectSourceImageWithBytes,
          onImport: (document) => bloc.add(
              ImportSourceDocumentEvent(document.filename, document.bytes)),
          onDelete: (path) => bloc.add(DeleteSourceDocumentEvent(path)),
          onRefresh: () => bloc.add(const LoadSourceDocumentsEvent()),
        ),
        if (!bloc.browserMode && bloc.canConfigureMatching) ...[
          const SizedBox(height: 16),
          MatchingStrategyPanel(bloc: bloc, state: state),
        ],
        if (bloc.browserMode && state.browserMessage != null) ...[
          const SizedBox(height: 12),
          Text(state.browserMessage!, textAlign: TextAlign.center),
        ],
        if (state.documentErrorMessage case final String message) ...[
          const SizedBox(height: 12),
          Text(message,
              style: const TextStyle(color: Colors.redAccent),
              textAlign: TextAlign.center),
          if (state.selectedSourceImage.isNotEmpty)
            TextButton(
                onPressed: state.documentOperationInProgress
                    ? null
                    : () => bloc.add(const RetrySourceDocumentEvent()),
                child: const Text('문서 분석 다시 시도')),
        ],
        const SizedBox(height: 24),

        // Document Image Preview
        if (state.selectedSourceImage.isEmpty)
          const Padding(
              padding: EdgeInsets.all(24),
              child: Text('문서를 선택하거나 드롭다운에서 새 문서를 추가해 주세요.',
                  textAlign: TextAlign.center))
        else
          Container(
            constraints: const BoxConstraints(maxWidth: 640, maxHeight: 420),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: Colors.white.withAlpha(30)),
              boxShadow: [
                BoxShadow(
                    color: Colors.black.withAlpha(180),
                    blurRadius: 24,
                    offset: const Offset(0, 10)),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(20),
              child: state.sourceImageBytes != null
                  ? Image.memory(state.sourceImageBytes!,
                      fit: BoxFit.contain,
                      errorBuilder: (_, __, ___) =>
                          const Icon(Icons.broken_image, size: 48))
                  : Image.asset(
                      state.selectedSourceImage,
                      fit: BoxFit.contain,
                      errorBuilder: (_, __, ___) => const Center(
                        child: Padding(
                          padding: EdgeInsets.all(40),
                          child: Icon(Icons.broken_image,
                              size: 48, color: Colors.white38),
                        ),
                      ),
                    ),
            ),
          ),
        const SizedBox(height: 16),
        Text(
          '총 ${state.browserProject?.entries.length ?? state.allItems.length}개의 준비물 품목이 식별되었습니다.',
          style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w700,
              color: AppColors.accentCyan),
        ),
        const SizedBox(height: 28),

        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 320),
          child: SizedBox(
            width: double.infinity,
            height: 48,
            child: ElevatedButton(
              onPressed:
                  !state.hasChecklist || state.documentOperationInProgress
                      ? null
                      : () => bloc.add(const NextStepEvent()),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.targetRed,
                foregroundColor: Colors.white,
                elevation: 4,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14)),
              ),
              child: const Text(
                '목록 확인 및 상품 선택 ➔',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                textAlign: TextAlign.center,
              ),
            ),
          ),
        ),
      ],
    );
  }

  // ==========================================
  // Step 2: Scrapping Confirmation
  // ==========================================
  Widget _buildStep2ScrappingConfirmation(
      BuildContext context, CuratorLoadedState state) {
    return Column(
      key: const ValueKey('step_2_scrapping_confirmation'),
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Text(
          CuratorStep.scrappingConfirmation.title,
          style: const TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w800,
              color: AppColors.textPrimary),
        ),
        const SizedBox(height: 6),
        Text(
          CuratorStep.scrappingConfirmation.subtitle,
          style: const TextStyle(fontSize: 14, color: AppColors.textSecondary),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 16),

        if (state.browserProject != null)
          BrowserProjectPanel(
              state: state,
              onPair: () => bloc.add(const PairBrowserEvent()),
              onRefresh: () => bloc.add(const RefreshBrowserEvent()),
              onApply: () => bloc.add(const ApplyBrowserSelectionEvent())),
        if (!widget.catalogProxyEnabled && !bloc.browserMode) ...[
          Container(
            constraints: const BoxConstraints(maxWidth: 680),
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: const Color(0x33FFB347),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0x99FFB347)),
            ),
            child: const Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.cloud_off, size: 17, color: Color(0xFFFFB347)),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '백엔드 상품 조회 기능이 비활성화되어 재수집·재검토를 사용할 수 없습니다. 배포 설정에서 인증된 프록시 연결을 확인해 주세요.',
                    style: TextStyle(fontSize: 12, color: Color(0xFFFFD08A)),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
        ],
        if (state.manifestRebuildWarning case final warning?) ...[
          _buildManifestWarningBanner(warning),
          const SizedBox(height: 12),
        ],
        if (state.allItems.any((item) => !item.isPreciselySegmented)) ...[
          _buildSegmentationWarningBanner(state),
          const SizedBox(height: 12),
        ],

        // ── 재스크래핑 버튼 & 진행 배너 ────────────────────────────────
        if (state.isRescraping) ...[
          Container(
            constraints: const BoxConstraints(maxWidth: 680),
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
            decoration: BoxDecoration(
              color: const Color(0xFF1A2332),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AppColors.accentCyan.withAlpha(100)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: AppColors.accentCyan,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        state.rescrapeStatus,
                        style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            color: AppColors.accentCyan),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Text(
                      '${(state.rescrapeProgress * 100).toInt()}%',
                      style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w800,
                          color: Colors.white70),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: state.rescrapeProgress,
                    minHeight: 6,
                    backgroundColor: Colors.white10,
                    valueColor: const AlwaysStoppedAnimation<Color>(
                        AppColors.accentCyan),
                  ),
                ),
              ],
            ),
          ),
        ] else ...[
          // 재스크래핑 버튼
          Container(
            constraints: const BoxConstraints(maxWidth: 680),
            width: double.infinity,
            child: Wrap(
              alignment: WrapAlignment.end,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 12,
              runSpacing: 8,
              children: [
                if (state.rescrapeStatus.isNotEmpty)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        state.rescrapeStatus.contains('실패')
                            ? Icons.error_outline
                            : Icons.check_circle_outline,
                        size: 14,
                        color: state.rescrapeStatus.contains('실패')
                            ? Colors.redAccent
                            : Colors.greenAccent,
                      ),
                      const SizedBox(width: 4),
                      Flexible(
                        child: Text(
                          state.rescrapeStatus,
                          style: TextStyle(
                            fontSize: 12,
                            color: state.rescrapeStatus.contains('실패')
                                ? Colors.redAccent
                                : Colors.greenAccent,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                Tooltip(
                  message: widget.catalogProxyEnabled
                      ? '백엔드를 통해 Target 상품 정보를 다시 수집합니다.'
                      : '백엔드 상품 조회 기능을 사용할 수 없습니다.',
                  child: OutlinedButton.icon(
                    onPressed: widget.catalogProxyEnabled && !bloc.browserMode
                        ? () => bloc.add(const RescrapeAllEvent())
                        : null,
                    icon: const Icon(Icons.refresh, size: 14),
                    label: const Text('재스크래핑',
                        style: TextStyle(
                            fontSize: 12.5, fontWeight: FontWeight.bold)),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFFFFB347),
                      side: const BorderSide(
                          color: Color(0xFFFFB347), width: 1.2),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 8),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10)),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 16),

        // Item Cards Grid with OK and Review buttons
        GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 370,
            mainAxisExtent: 200,
            crossAxisSpacing: 16,
            mainAxisSpacing: 16,
          ),
          itemCount: state.allItems.length,
          itemBuilder: (context, index) {
            final item = state.allItems[index];
            final isIncluded = !state.excludedItemIds.contains(item.id);
            final purchaseUrl = TargetPurchaseUrl.tryParse(item.targetUrl);

            return Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: isIncluded
                    ? AppColors.surfaceLight
                    : AppColors.surface.withAlpha(90),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: isIncluded
                      ? AppColors.accentCyan.withAlpha(120)
                      : Colors.white.withAlpha(20),
                  width: 1.3,
                ),
              ),
              child: Column(
                children: [
                  Expanded(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Cutout Image
                        Container(
                          width: 65,
                          height: 85,
                          margin: const EdgeInsets.only(right: 12),
                          decoration: BoxDecoration(
                            color: Colors.white.withAlpha(10),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          padding: const EdgeInsets.all(4),
                          child: ProductImage(
                            source: item.imageUrl,
                            semanticLabel: item.name,
                            fit: BoxFit.contain,
                            placeholderBuilder: (_) => const Icon(
                              Icons.shopping_bag_outlined,
                              size: 28,
                              color: Colors.white38,
                            ),
                          ),
                        ),

                        // Item Info
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 6, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: item.isPersonal
                                          ? AppColors.badgePersonalBg
                                          : AppColors.badgeCommonBg,
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: Text(
                                      item.isPersonal ? '개인*' : '공용',
                                      style: TextStyle(
                                        fontSize: 9.5,
                                        fontWeight: FontWeight.bold,
                                        color: item.isPersonal
                                            ? AppColors.badgePersonalText
                                            : AppColors.badgeCommonText,
                                      ),
                                    ),
                                  ),
                                  const Spacer(),
                                  Text(
                                    item.formattedPrice,
                                    style: const TextStyle(
                                        fontSize: 13,
                                        fontWeight: FontWeight.w800,
                                        color: Colors.greenAccent),
                                  ),
                                  const SizedBox(width: 4),
                                  Checkbox(
                                    value: isIncluded,
                                    activeColor: AppColors.targetRed,
                                    onChanged: state.isRescraping
                                        ? null
                                        : (_) => bloc.add(
                                              ToggleItemInclusionEvent(item.id),
                                            ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 2),
                              Text(
                                item.name,
                                style: const TextStyle(
                                    fontSize: 12.5,
                                    fontWeight: FontWeight.w700,
                                    color: AppColors.textPrimary),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                              const SizedBox(height: 4),
                              InkWell(
                                onTap: purchaseUrl == null
                                    ? null
                                    : () => _launchPurchaseUrl(purchaseUrl),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      purchaseUrl == null
                                          ? Icons.link_off
                                          : Icons.open_in_new,
                                      size: 11,
                                      color: purchaseUrl == null
                                          ? AppColors.textSecondary
                                          : const Color(0xFFFF6B6B),
                                    ),
                                    const SizedBox(width: 4),
                                    Text(
                                      purchaseUrl == null
                                          ? '직접 구매 링크 없음'
                                          : 'Target 확인 ↗',
                                      style: TextStyle(
                                          fontSize: 11.0,
                                          fontWeight: FontWeight.w600,
                                          color: purchaseUrl == null
                                              ? AppColors.textSecondary
                                              : const Color(0xFFFF6B6B)),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),

                  const Divider(color: Colors.white12, height: 12),

                  // Bottom Action Buttons: [OK] and [재검토 ↺]
                  Row(
                    children: [
                      // OK Button
                      Expanded(
                        child: ElevatedButton(
                          onPressed: state.isRescraping
                              ? null
                              : () => bloc.add(ApproveItemEvent(item.id)),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: isIncluded
                                ? Colors.green.shade700
                                : AppColors.surface,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8)),
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                  isIncluded ? Icons.check_circle : Icons.check,
                                  size: 14),
                              const SizedBox(width: 4),
                              Text(isIncluded ? 'OK (승인됨)' : 'OK 선택',
                                  style: const TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.bold)),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),

                      // Re-review Button
                      Expanded(
                        child: OutlinedButton(
                          onPressed: state.isRescraping ||
                                  bloc.browserMode ||
                                  !widget.catalogProxyEnabled
                              ? null
                              : () =>
                                  bloc.add(FetchLiveCandidatesEvent(item.id)),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: AppColors.accentCyan,
                            side: BorderSide(
                                color: AppColors.accentCyan.withAlpha(120)),
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8)),
                          ),
                          child: const Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.travel_explore, size: 14),
                              SizedBox(width: 4),
                              Text('재검토 ↺',
                                  style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.bold)),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            );
          },
        ),
        const SizedBox(height: 32),

        // Bottom Navigation Row: [◀ 문서 다시 선택] and [다음 ➔]
        Wrap(
          alignment: WrapAlignment.center,
          spacing: 16,
          runSpacing: 12,
          children: [
            OutlinedButton(
              onPressed: state.isRescraping
                  ? null
                  : () => bloc.add(const PreviousStepEvent()),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.textSecondary,
                side: BorderSide(color: Colors.white.withAlpha(50)),
                padding:
                    const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14)),
              ),
              child: const Text('◀ 문서 다시 선택',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
            ),
            ElevatedButton(
              key: const Key('open_canvas_button'),
              onPressed: state.isRescraping || state.browserBusy
                  ? null
                  : () => bloc.add(const NextStepEvent()),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.targetRed,
                foregroundColor: Colors.white,
                padding:
                    const EdgeInsets.symmetric(horizontal: 28, vertical: 14),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14)),
              ),
              child: const Text('캔버스 시각화 및 인터랙션 ➔',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      ],
    );
  }

  // ==========================================
  // Target Candidate Inspector Modal (재검토 모달)
  // ==========================================
  Widget _buildReviewModal(BuildContext context, CuratorLoadedState state) {
    final item = state.reviewingItem;
    if (item == null) return const SizedBox.shrink();

    return ReviewModal(
      key: ValueKey('review_modal_${item.id}'),
      bloc: bloc,
      state: state,
      item: item,
      onLaunchPurchaseUrl: _launchPurchaseUrl,
    );
  }

  // ==========================================
  // Step 3: Hovering Image (Interactive Canvas)
  // ==========================================
  Widget _buildStep3HoveringImage(
      BuildContext context, CuratorLoadedState state) {
    final activeManifest = state.manifest.copyWith(
      // The flattened PNG contains every item from the pipeline. Once an
      // item is excluded, render the approved subset as individual layers so
      // a removed product cannot remain as a grayscale ghost.
      canvasImage:
          state.excludedItemIds.isEmpty ? state.manifest.canvasImage : '',
      items: state.items,
    );

    return Column(
      key: const ValueKey('step_3_hovering_image'),
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Text(
          CuratorStep.hoveringImage.title,
          style: const TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w800,
              color: AppColors.textPrimary),
        ),
        const SizedBox(height: 6),
        Text(
          CuratorStep.hoveringImage.subtitle,
          style: const TextStyle(fontSize: 14, color: AppColors.textSecondary),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 24),

        if (state.manifestRebuildWarning case final warning?) ...[
          _buildManifestWarningBanner(warning),
          const SizedBox(height: 16),
        ],
        if (state.allItems.any((item) => !item.isPreciselySegmented)) ...[
          _buildSegmentationWarningBanner(state),
          const SizedBox(height: 16),
        ],

        // Interactive Single Canvas Layer
        CuratorCanvas(
          manifest: activeManifest,
          hoveredItemId: state.hoveredItemId,
          selectedItemId: state.selectedItemId,
          onHoverItem: (id) => bloc.add(HoverItemEvent(id)),
          onSelectItem: (id) => bloc.add(SelectItemEvent(id)),
          onDismissSelection: () => bloc.add(const DismissItemEvent()),
          onItemsLayoutChanged: (items) {
            _currentExportData = items;
          },
        ),
        const SizedBox(height: 24),

        // Help tip banner
        Container(
          constraints: const BoxConstraints(maxWidth: 760),
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(
            color: AppColors.surfaceLight,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: Colors.white12),
          ),
          child: const Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.info_outline, size: 14, color: AppColors.accentCyan),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  '상품을 드래그해 옮기세요. 상품을 선택한 뒤 오른쪽 아래 ↘ 화살표를 당기면 비율을 유지하며 확대·축소됩니다. 키보드 +/−도 사용할 수 있습니다.',
                  style: TextStyle(fontSize: 12, color: Colors.white70),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),

        // Navigation Row
        Wrap(
          alignment: WrapAlignment.center,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 16,
          runSpacing: 12,
          children: [
            OutlinedButton(
              onPressed: () => bloc.add(const PreviousStepEvent()),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.textSecondary,
                side: BorderSide(color: Colors.white.withAlpha(50)),
                padding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14)),
              ),
              child: const Text('◀ 상품 선택으로 돌아가기',
                  style:
                      TextStyle(fontSize: 13.5, fontWeight: FontWeight.bold)),
            ),
            ElevatedButton.icon(
              key: const Key('html_export_button'),
              onPressed:
                  _isExporting ? null : () => _downloadHtml(context, state),
              icon: _isExporting
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.download, size: 18),
              label: Text(
                _isExporting
                    ? (_exportTotal == 0
                        ? 'HTML 준비 중...'
                        : '이미지 포함 중 $_exportCompleted/$_exportTotal')
                    : 'HTML 다운로드',
                style:
                    const TextStyle(fontSize: 14, fontWeight: FontWeight.w800),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.targetRed,
                foregroundColor: Colors.white,
                padding:
                    const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14)),
                elevation: 4,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Future<void> _downloadHtml(
      BuildContext context, CuratorLoadedState state) async {
    if (_isExporting) return;
    setState(() {
      _isExporting = true;
      _exportCompleted = 0;
      _exportTotal = 0;
    });

    final activeItemsById = {
      for (final item in state.items) item.id: item,
    };
    final currentActiveExportData = _currentExportData
        .where((data) => activeItemsById.containsKey(data.item.id))
        .map((data) => PositionedItemExportData(
              item: activeItemsById[data.item.id]!,
              x: data.x,
              y: data.y,
              width: data.width,
              height: data.height,
              scale: data.scale,
              base64DataUri: data.base64DataUri,
            ))
        .toList();

    // If no drag/resize data recorded yet, generate from initial manifest bounds
    final rawExportData = currentActiveExportData.isNotEmpty
        ? currentActiveExportData
        : state.items
            .map((item) => PositionedItemExportData(
                  item: item,
                  x: item.bounds.x,
                  y: item.bounds.y,
                  width: item.bounds.width,
                  height: item.bounds.height,
                  scale: 1.0,
                ))
            .toList();

    final filename = curatorHtmlFilename(state.selectedSourceImage);
    try {
      final htmlCode = await widget.htmlExportService.generate(
        canvasWidth: state.manifest.canvasWidth,
        canvasHeight: state.manifest.canvasHeight,
        items: rawExportData,
        onProgress: (completed, total) {
          if (!mounted) return;
          setState(() {
            _exportCompleted = completed;
            _exportTotal = total;
          });
        },
      );
      if (!mounted || !context.mounted) return;
      final saved =
          await widget.htmlFileSaver(filename: filename, html: htmlCode);
      if (!mounted || !context.mounted) return;
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content:
              Text(saved ? 'HTML 파일을 내보냈습니다: $filename' : 'HTML 저장을 취소했습니다.')));
    } catch (_) {
      if (!mounted || !context.mounted) return;
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('HTML 파일을 저장하지 못했습니다. 다운로드·저장 권한을 확인하고 다시 시도해 주세요.')));
    } finally {
      if (mounted) setState(() => _isExporting = false);
    }
  }
}

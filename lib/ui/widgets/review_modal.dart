import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/bloc/curator_bloc.dart';
import '../../core/bloc/curator_event.dart';
import '../../core/bloc/curator_state.dart';
import '../../core/models/curator_item.dart';
import '../../core/models/target_purchase_url.dart';
import '../theme/app_colors.dart';
import 'product_image.dart';

typedef TargetPurchaseUrlLauncher = Future<void> Function(
  TargetPurchaseUrl purchaseUrl,
);

/// Review surface for replacing one curated item with a Target candidate.
///
/// Network progress and failures are owned by [CuratorBloc]. This widget only
/// owns the text field controller, which is transient presentation state.
class ReviewModal extends StatefulWidget {
  const ReviewModal({
    super.key,
    required this.bloc,
    required this.state,
    required this.item,
    required this.onLaunchPurchaseUrl,
  });

  final CuratorBloc bloc;
  final CuratorLoadedState state;
  final CuratorItem item;
  final TargetPurchaseUrlLauncher onLaunchPurchaseUrl;

  @override
  State<ReviewModal> createState() => _ReviewModalState();
}

class _ReviewModalState extends State<ReviewModal> {
  final TextEditingController _urlController = TextEditingController();

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  void _submitCustomUrl() {
    if (widget.state.urlInspectionStatus == UrlInspectionStatus.loading) {
      return;
    }

    final text = _urlController.text.trim();
    if (text.isEmpty) return;

    widget.bloc.add(InspectTargetUrlEvent(
      itemId: widget.item.id,
      targetUrl: text,
    ));
    _urlController.clear();
  }

  void _close() {
    widget.bloc.add(CancelItemReviewEvent(widget.item.id));
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final purchaseUrl = TargetPurchaseUrl.tryParse(item.targetUrl);

    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.escape): _close,
      },
      child: FocusTraversalGroup(
        child: FocusScope(
          autofocus: true,
          child: SizedBox.expand(
            child: Stack(
              children: [
                ModalBarrier(
                  color: Colors.black.withAlpha(200),
                  dismissible: true,
                  semanticsLabel: '상품 재검토 창 닫기',
                  onDismiss: _close,
                ),
                Center(
                  child: Container(
                    constraints:
                        const BoxConstraints(maxWidth: 640, maxHeight: 720),
                    margin: const EdgeInsets.all(12),
                    padding: const EdgeInsets.all(22),
                    decoration: BoxDecoration(
                      color: AppColors.surface,
                      borderRadius: BorderRadius.circular(24),
                      border: Border.all(
                        color: AppColors.accentCyan.withAlpha(120),
                        width: 1.5,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withAlpha(220),
                          blurRadius: 36,
                          offset: const Offset(0, 12),
                        ),
                      ],
                    ),
                    child: SingleChildScrollView(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _buildHeader(item),
                          const SizedBox(height: 6),
                          Text(
                            '대상 품목: ${item.name}',
                            style: const TextStyle(
                              fontSize: 13.5,
                              color: AppColors.textSecondary,
                            ),
                          ),
                          const SizedBox(height: 12),
                          _buildPurchaseBanner(purchaseUrl),
                          const SizedBox(height: 14),
                          _buildUrlInspector(),
                          const SizedBox(height: 16),
                          const Text(
                            '앱이 Target에서 수집한 추천 대안 상품 목록:',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.bold,
                              color: AppColors.accentCyan,
                            ),
                          ),
                          const SizedBox(height: 10),
                          _buildCandidateContent(),
                          const SizedBox(height: 16),
                          Align(
                            alignment: Alignment.centerRight,
                            child: OutlinedButton(
                              onPressed: _close,
                              style: OutlinedButton.styleFrom(
                                foregroundColor: AppColors.textSecondary,
                                side: BorderSide(
                                    color: Colors.white.withAlpha(40)),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                  vertical: 10,
                                ),
                              ),
                              child: const Text(
                                '닫기 (체크 해제)',
                                style: TextStyle(fontSize: 12.5),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(CuratorItem item) {
    return Row(
      children: [
        const Icon(Icons.travel_explore, color: AppColors.accentCyan, size: 22),
        const SizedBox(width: 8),
        const Expanded(
          child: Text(
            'Target 웹 탐색 및 이미지 재검토',
            style: TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w800,
              color: AppColors.textPrimary,
            ),
          ),
        ),
        IconButton(
          icon: const Icon(Icons.close, color: Colors.white60),
          onPressed: _close,
        ),
      ],
    );
  }

  Widget _buildPurchaseBanner(TargetPurchaseUrl? purchaseUrl) {
    final hasPurchaseUrl = purchaseUrl != null;
    final purchaseButton = ElevatedButton.icon(
      key: const Key('review_current_purchase_button'),
      onPressed: purchaseUrl == null
          ? null
          : () => widget.onLaunchPurchaseUrl(purchaseUrl),
      icon: Icon(
        hasPurchaseUrl ? Icons.open_in_new : Icons.link_off,
        size: 12,
      ),
      label: Text(
        hasPurchaseUrl ? 'Target 열기' : '직링크 없음',
        style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
      ),
      style: ElevatedButton.styleFrom(
        backgroundColor: AppColors.targetRed,
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      ),
    );

    Widget buildMessage() => Row(
          children: [
            Icon(
              hasPurchaseUrl ? Icons.public : Icons.link_off,
              color: hasPurchaseUrl
                  ? const Color(0xFFFF6B6B)
                  : AppColors.textSecondary,
              size: 18,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                hasPurchaseUrl
                    ? '브라우저에서 Target 상품 상세 페이지를 직접 열어보세요.'
                    : '현재 상품에는 검증된 Target 직접 구매 링크가 없습니다.',
                style: const TextStyle(fontSize: 12, color: Colors.white70),
              ),
            ),
          ],
        );

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surfaceLight,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white12),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth < 430) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                buildMessage(),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerRight,
                  child: purchaseButton,
                ),
              ],
            );
          }
          return Row(
            children: [
              Expanded(child: buildMessage()),
              const SizedBox(width: 8),
              purchaseButton,
            ],
          );
        },
      ),
    );
  }

  Widget _buildUrlInspector() {
    final status = widget.state.urlInspectionStatus;
    final isLoading = status == UrlInspectionStatus.loading;

    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFF131D2E),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.accentCyan.withAlpha(60)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.link, size: 14, color: AppColors.accentCyan),
              SizedBox(width: 6),
              Expanded(
                child: Text(
                  'Target 상품 URL 또는 이미지 링크 직접 입력:',
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                    color: AppColors.accentCyan,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: TextField(
                  key: const Key('review_url_input'),
                  controller: _urlController,
                  enabled: !isLoading,
                  style: const TextStyle(fontSize: 12, color: Colors.white),
                  decoration: InputDecoration(
                    hintText: 'https://www.target.com/p/... 또는 Scene7 이미지 URL',
                    hintStyle:
                        const TextStyle(fontSize: 11, color: Colors.white30),
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 8,
                    ),
                    filled: true,
                    fillColor: AppColors.surface,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide.none,
                    ),
                  ),
                  onSubmitted: (_) => _submitCustomUrl(),
                ),
              ),
              const SizedBox(width: 8),
              ElevatedButton(
                key: const Key('inspect_target_url_button'),
                onPressed: isLoading ? null : _submitCustomUrl,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.accentCyan,
                  foregroundColor: Colors.black,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                child: isLoading
                    ? const SizedBox(
                        key: Key('url_inspection_loading'),
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.black,
                        ),
                      )
                    : const Text(
                        '가져오기',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
              ),
            ],
          ),
          if (status != UrlInspectionStatus.idle &&
              status != UrlInspectionStatus.loading) ...[
            const SizedBox(height: 8),
            _buildUrlInspectionMessage(status),
          ],
        ],
      ),
    );
  }

  Widget _buildUrlInspectionMessage(UrlInspectionStatus status) {
    return switch (status) {
      UrlInspectionStatus.success => const Text(
          '입력한 링크에서 상품 후보를 추가했습니다.',
          key: Key('url_inspection_success'),
          style: TextStyle(fontSize: 11, color: Colors.greenAccent),
        ),
      UrlInspectionStatus.empty => const Text(
          '링크에서 사용할 수 있는 Target 상품 정보를 찾지 못했습니다.',
          key: Key('url_inspection_empty'),
          style: TextStyle(fontSize: 11, color: Color(0xFFFFB347)),
        ),
      UrlInspectionStatus.failure => Text(
          widget.state.urlInspectionErrorMessage ?? 'Target URL을 검사하지 못했습니다.',
          key: const Key('url_inspection_failure'),
          style: const TextStyle(fontSize: 11, color: Colors.redAccent),
        ),
      UrlInspectionStatus.idle ||
      UrlInspectionStatus.loading =>
        const SizedBox.shrink(),
    };
  }

  Widget _buildCandidateContent() {
    final candidates = widget.state.detectedCandidates;
    if (candidates.isNotEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (widget.state.reviewStatus == ReviewStatus.failure) ...[
            _buildReviewFailure(compact: true),
            const SizedBox(height: 8),
          ],
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 280),
            child: ListView.separated(
              shrinkWrap: true,
              itemCount: candidates.length,
              separatorBuilder: (_, __) => const SizedBox(height: 8),
              itemBuilder: (context, index) =>
                  _buildCandidateTile(candidates[index]),
            ),
          ),
        ],
      );
    }

    return switch (widget.state.reviewStatus) {
      ReviewStatus.loading => const Center(
          key: Key('review_candidates_loading'),
          child: Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(
                  color: AppColors.accentCyan,
                  strokeWidth: 2.5,
                ),
                SizedBox(height: 12),
                Text(
                  'Target에서 최적의 상품 정보를 검색 중입니다...',
                  style: TextStyle(
                    fontSize: 12.5,
                    color: AppColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
        ),
      ReviewStatus.empty => const Center(
          key: Key('review_candidates_empty'),
          child: Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Text(
              '조건에 맞는 대안 상품을 찾지 못했습니다.',
              style: TextStyle(color: Color(0xFFFFB347), fontSize: 12.5),
            ),
          ),
        ),
      ReviewStatus.failure => _buildReviewFailure(),
      ReviewStatus.idle || ReviewStatus.success => const Center(
          child: Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Text(
              '표시할 대안 상품이 없습니다.',
              style: TextStyle(color: AppColors.textSecondary, fontSize: 12.5),
            ),
          ),
        ),
    };
  }

  Widget _buildReviewFailure({bool compact = false}) {
    return Container(
      key: const Key('review_candidates_failure'),
      width: double.infinity,
      padding: EdgeInsets.all(compact ? 10 : 16),
      decoration: BoxDecoration(
        color: Colors.red.withAlpha(24),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.redAccent.withAlpha(90)),
      ),
      child: Text(
        widget.state.reviewErrorMessage ?? 'Target 후보를 불러오지 못했습니다.',
        style: const TextStyle(color: Colors.redAccent, fontSize: 12),
        textAlign: compact ? TextAlign.start : TextAlign.center,
      ),
    );
  }

  Widget _buildCandidateTile(TargetProductCandidate candidate) {
    final purchaseUrl = TargetPurchaseUrl.tryParse(candidate.targetUrl);

    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppColors.surfaceLight,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white12),
      ),
      child: Row(
        children: [
          Container(
            width: 50,
            height: 56,
            margin: const EdgeInsets.only(right: 12),
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              color: Colors.white.withAlpha(10),
              borderRadius: BorderRadius.circular(8),
            ),
            child: ProductImage(
              source: candidate.imageUrl,
              semanticLabel: candidate.name,
              placeholderBuilder: (_) => const Icon(
                Icons.broken_image,
                size: 24,
                color: Colors.white38,
              ),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  candidate.name,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  candidate.description,
                  style: const TextStyle(
                    fontSize: 10.5,
                    color: AppColors.textSecondary,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 3),
                Text(
                  candidate.formattedPrice,
                  style: const TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w800,
                    color: Colors.greenAccent,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Column(
            children: [
              ElevatedButton(
                key: ValueKey('select_candidate_${candidate.id}'),
                onPressed: () {
                  widget.bloc.add(ReplaceItemImageEvent(
                    itemId: widget.item.id,
                    newImageUrl: candidate.imageUrl,
                    newName: candidate.name,
                    newPrice: candidate.price,
                    // An unverified candidate must explicitly clear the old
                    // product link; null would mean "leave it unchanged".
                    newTargetUrl: purchaseUrl?.toString() ?? '',
                  ));
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.green.shade700,
                  foregroundColor: Colors.white,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                child: const Text(
                  '선택',
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
                ),
              ),
              const SizedBox(height: 3),
              TextButton(
                key: ValueKey('candidate_purchase_${candidate.id}'),
                onPressed: purchaseUrl == null
                    ? null
                    : () => widget.onLaunchPurchaseUrl(purchaseUrl),
                style: TextButton.styleFrom(
                  minimumSize: Size.zero,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: Text(
                  purchaseUrl == null ? '직링크 없음' : 'Target ↗',
                  style: TextStyle(
                    fontSize: 9.5,
                    color: purchaseUrl == null
                        ? AppColors.textSecondary
                        : const Color(0xFFFF6B6B),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

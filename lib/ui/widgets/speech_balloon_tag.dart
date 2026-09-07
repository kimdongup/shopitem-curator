import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../core/models/curator_item.dart';
import '../../core/models/target_purchase_url.dart';
import '../theme/app_colors.dart';

/// Interactive Speech Balloon Price Tag Widget that pops up when an item is selected.
class SpeechBalloonTag extends StatelessWidget {
  const SpeechBalloonTag({
    super.key,
    required this.item,
    required this.onDismiss,
    this.width = 310,
    this.tailAlignment = 0.5,
    this.tailOnTop = false,
  })  : assert(width > 0),
        assert(tailAlignment >= 0 && tailAlignment <= 1);

  final CuratorItem item;
  final VoidCallback onDismiss;
  final double width;
  final double tailAlignment;
  final bool tailOnTop;

  static double estimatedHeightForWidth(double width) =>
      width < 280 ? 220 : 210;

  Future<void> _launchTargetUrl(
    BuildContext context,
    TargetPurchaseUrl purchaseUrl,
  ) async {
    final uri = purchaseUrl.uri;
    try {
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      } else {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Could not open URL: ${item.targetUrl}')),
          );
        }
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error launching Target URL: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isPersonal = item.isPersonal;
    final purchaseUrl = TargetPurchaseUrl.tryParse(item.targetUrl);
    final compact = width < 280;
    final horizontalPadding = compact ? 12.0 : 16.0;
    final topPadding =
        tailOnTop ? (compact ? 18.0 : 22.0) : (compact ? 10.0 : 14.0);
    final bottomPadding =
        tailOnTop ? (compact ? 10.0 : 14.0) : (compact ? 18.0 : 22.0);

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): onDismiss,
      },
      child: Semantics(
        container: true,
        liveRegion: true,
        label: '${item.name} 가격 정보',
        child: CustomPaint(
          painter: _BalloonPainter(
            color: AppColors.surface.withAlpha(245),
            borderColor: Colors.white.withAlpha(60),
            tailAlignment: tailAlignment,
            tailOnTop: tailOnTop,
          ),
          child: Container(
            width: width,
            padding: EdgeInsets.fromLTRB(
              horizontalPadding,
              topPadding,
              horizontalPadding,
              bottomPadding,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildHeader(isPersonal: isPersonal, compact: compact),
                SizedBox(height: compact ? 5 : 8),
                Text(
                  item.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 14.5,
                    fontWeight: FontWeight.w800,
                    color: AppColors.textPrimary,
                    height: 1.3,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  item.description,
                  maxLines: compact ? 2 : 3,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 11.5,
                    color: AppColors.textSecondary,
                    height: 1.4,
                  ),
                ),
                SizedBox(height: compact ? 8 : 12),
                SizedBox(
                  width: double.infinity,
                  height: compact ? 34 : 38,
                  child: ElevatedButton(
                    key: const Key('speech_balloon_purchase_button'),
                    onPressed: purchaseUrl == null
                        ? null
                        : () => _launchTargetUrl(context, purchaseUrl),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.targetRed,
                      foregroundColor: Colors.white,
                      elevation: 4,
                      shadowColor: AppColors.targetRed.withAlpha(120),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                      padding: EdgeInsets.symmetric(
                        horizontal: compact ? 8 : 12,
                      ),
                    ),
                    child: compact
                        ? Text(
                            purchaseUrl == null
                                ? 'Target 직링크 없음'
                                : 'Target에서 구매하기',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w700,
                            ),
                          )
                        : Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              _buildTargetMark(),
                              const SizedBox(width: 8),
                              Flexible(
                                child: Text(
                                  purchaseUrl == null
                                      ? '검증된 Target 직링크 없음'
                                      : 'Target에서 바로 구매하기',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 12.5,
                                    fontWeight: FontWeight.w700,
                                    letterSpacing: 0.2,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 4),
                              const Icon(Icons.arrow_outward, size: 14),
                            ],
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

  Widget _buildHeader({required bool isPersonal, required bool compact}) {
    final categoryBadge = Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: isPersonal ? AppColors.badgePersonalBg : AppColors.badgeCommonBg,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: isPersonal
              ? AppColors.badgePersonalText.withAlpha(100)
              : AppColors.badgeCommonText.withAlpha(100),
        ),
      ),
      child: Text(
        isPersonal
            ? (compact ? '개인*' : '개인 물품 (*라벨)')
            : (compact ? '공용' : '교실 공용 물품'),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 10.5,
          fontWeight: FontWeight.bold,
          color: isPersonal
              ? AppColors.badgePersonalText
              : AppColors.badgeCommonText,
        ),
      ),
    );
    final priceBadge = Container(
      padding: EdgeInsets.symmetric(horizontal: compact ? 5 : 8, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.green.withAlpha(40),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: Colors.greenAccent.withAlpha(120)),
      ),
      child: compact
          ? Text(
              item.formattedPrice,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w800,
                color: Colors.greenAccent,
              ),
            )
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.sell_outlined,
                  size: 11,
                  color: Colors.greenAccent,
                ),
                const SizedBox(width: 4),
                Text(
                  item.formattedPrice,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                    color: Colors.greenAccent,
                  ),
                ),
              ],
            ),
    );
    final closeButton = IconButton(
      key: const ValueKey('speech_balloon_close_button'),
      onPressed: onDismiss,
      tooltip: '가격 태그 닫기',
      constraints: const BoxConstraints.tightFor(width: 28, height: 28),
      padding: const EdgeInsets.all(4),
      icon: const Icon(
        Icons.close,
        size: 16,
        color: AppColors.textSecondary,
      ),
    );

    if (!compact) {
      return Row(
        children: [
          Flexible(child: categoryBadge),
          const SizedBox(width: 8),
          priceBadge,
          const Spacer(),
          closeButton,
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(child: categoryBadge),
            const SizedBox(width: 6),
            closeButton,
          ],
        ),
        const SizedBox(height: 4),
        ConstrainedBox(
          constraints: BoxConstraints(maxWidth: width - 24),
          child: priceBadge,
        ),
      ],
    );
  }

  Widget _buildTargetMark() {
    return Container(
      width: 14,
      height: 14,
      decoration: const BoxDecoration(
        color: Colors.white,
        shape: BoxShape.circle,
      ),
      child: Center(
        child: Container(
          width: 8,
          height: 8,
          decoration: const BoxDecoration(
            color: AppColors.targetRed,
            shape: BoxShape.circle,
          ),
          child: Center(
            child: Container(
              width: 3,
              height: 3,
              decoration: const BoxDecoration(
                color: Colors.white,
                shape: BoxShape.circle,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Draws a rounded speech balloon whose tail can follow a clamped anchor.
class _BalloonPainter extends CustomPainter {
  _BalloonPainter({
    required this.color,
    required this.borderColor,
    required this.tailAlignment,
    required this.tailOnTop,
  });

  final Color color;
  final Color borderColor;
  final double tailAlignment;
  final bool tailOnTop;

  @override
  void paint(Canvas canvas, Size size) {
    const double radius = 16.0;
    const double tailWidth = 16.0;
    const double tailHeight = 10.0;

    final tailEdgeInset =
        (radius + tailWidth / 2).clamp(0.0, size.width / 2).toDouble();
    final tailCenterX = (size.width * tailAlignment)
        .clamp(tailEdgeInset, size.width - tailEdgeInset)
        .toDouble();

    final Path path;
    if (tailOnTop) {
      path = Path()
        ..moveTo(radius, tailHeight)
        ..lineTo(tailCenterX - tailWidth / 2, tailHeight)
        ..lineTo(tailCenterX, 0)
        ..lineTo(tailCenterX + tailWidth / 2, tailHeight)
        ..lineTo(size.width - radius, tailHeight)
        ..arcToPoint(
          Offset(size.width, tailHeight + radius),
          radius: const Radius.circular(radius),
        )
        ..lineTo(size.width, size.height - radius)
        ..arcToPoint(
          Offset(size.width - radius, size.height),
          radius: const Radius.circular(radius),
        )
        ..lineTo(radius, size.height)
        ..arcToPoint(
          Offset(0, size.height - radius),
          radius: const Radius.circular(radius),
        )
        ..lineTo(0, tailHeight + radius)
        ..arcToPoint(
          const Offset(radius, tailHeight),
          radius: const Radius.circular(radius),
        )
        ..close();
    } else {
      final bodyBottom = size.height - tailHeight;
      path = Path()
        ..moveTo(radius, 0)
        ..lineTo(size.width - radius, 0)
        ..arcToPoint(
          Offset(size.width, radius),
          radius: const Radius.circular(radius),
        )
        ..lineTo(size.width, bodyBottom - radius)
        ..arcToPoint(
          Offset(size.width - radius, bodyBottom),
          radius: const Radius.circular(radius),
        )
        ..lineTo(tailCenterX + tailWidth / 2, bodyBottom)
        ..lineTo(tailCenterX, size.height)
        ..lineTo(tailCenterX - tailWidth / 2, bodyBottom)
        ..lineTo(radius, bodyBottom)
        ..arcToPoint(
          Offset(0, bodyBottom - radius),
          radius: const Radius.circular(radius),
        )
        ..lineTo(0, radius)
        ..arcToPoint(
          const Offset(radius, 0),
          radius: const Radius.circular(radius),
        )
        ..close();
    }

    // Shadow
    canvas.drawShadow(path, Colors.black.withAlpha(200), 16.0, true);

    // Body Fill
    final paintFill = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
    canvas.drawPath(path, paintFill);

    // Border Stroke
    final paintStroke = Paint()
      ..color = borderColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    canvas.drawPath(path, paintStroke);
  }

  @override
  bool shouldRepaint(covariant _BalloonPainter oldDelegate) {
    return oldDelegate.color != color ||
        oldDelegate.borderColor != borderColor ||
        oldDelegate.tailAlignment != tailAlignment ||
        oldDelegate.tailOnTop != tailOnTop;
  }
}

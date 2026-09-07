// Pure Dart Service (Zero Flutter Dependencies)

import '../models/curator_item.dart';
import '../models/target_purchase_url.dart';
import 'local_image_data_uri.dart';

class PositionedItemExportData {
  const PositionedItemExportData({
    required this.item,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    this.scale = 1.0,
    this.base64DataUri,
  });

  final CuratorItem item;
  final double x;
  final double y;
  final double width;
  final double height;
  final double scale;
  final String? base64DataUri;

  double get scaledWidth => width * scale;
  double get scaledHeight => height * scale;
}

/// Generates a standalone, self-contained modern HTML5 Interactive Image Map.
/// Embeds images as Base64 Data URIs so that copying/pasting the HTML code
/// works anywhere without missing image files or CDN hotlinking blocks.
class HtmlImageMapExporter {
  const HtmlImageMapExporter();

  static const _transparentPixelDataUri =
      'data:image/gif;base64,R0lGODlhAQABAAD/ACwAAAAAAQABAAACADs=';

  static final _safeImageDataUriPattern = RegExp(
    r'^data:image/(?:avif|gif|jpe?g|png|webp);base64,[a-zA-Z0-9+/]*={0,2}$',
    caseSensitive: false,
  );

  /// Converts a local asset or file path to Base64 Data URI if available.
  static String? fileToBase64DataUri(String path) =>
      readLocalImageAsDataUri(path);

  static String generateHtml({
    required double canvasWidth,
    required double canvasHeight,
    required List<PositionedItemExportData> items,
    String pageTitle = 'Target School Supplies Interactive Map',
  }) {
    final areaTags = StringBuffer();
    final itemOverlays = StringBuffer();
    final clipDefinitions = StringBuffer();

    for (int i = 0; i < items.length; i++) {
      final data = items[i];
      final item = data.item;
      final x1 = data.x.toInt();
      final y1 = data.y.toInt();
      final x2 = (data.x + data.scaledWidth).toInt();
      final y2 = (data.y + data.scaledHeight).toInt();

      // Use an embedded Base64 image when it is safe, then fall back to the
      // local/remote product image. Active data URI types such as SVG are not
      // allowed in the standalone document.
      String? imgSrc = _safeImageSource(data.base64DataUri ?? '');
      if (imgSrc == null) {
        final localBase64 = fileToBase64DataUri(item.imageUrl);
        imgSrc = _safeImageSource(localBase64 ?? item.imageUrl);
      }

      final safeTargetUrl = TargetPurchaseUrl.tryParse(item.targetUrl)?.value;
      final linkTarget = safeTargetUrl ?? '#';
      final escapedTargetUrl = _escapeHtml(linkTarget);
      final escapedImageSource = _escapeHtml(
        imgSrc ?? _transparentPixelDataUri,
      );
      final escapedItemId = _escapeHtml(item.id);
      final balloonId = 'curator-balloon-$i';
      final balloonTitleId = 'curator-balloon-title-$i';
      final leftPercent = _asPercentage(data.x, canvasWidth);
      final topPercent = _asPercentage(data.y, canvasHeight);
      final widthPercent = _asPercentage(data.scaledWidth, canvasWidth);
      final heightPercent = _asPercentage(data.scaledHeight, canvasHeight);

      final exportedContours = _exportContours(data);
      final clipPath = item.contours.length > 1
          ? _svgClipPath(item, i, clipDefinitions)
          : _cssClipPath(item);
      final clipStyle = clipPath == null
          ? ''
          : ' style="clip-path: ${_escapeHtml(clipPath)};"';

      // Standard HTML polygon map connected to the transparent responsive hit
      // image below. Each disconnected foreground component gets its own
      // region. Product regions toggle their information balloon; only the
      // explicit action inside the balloon navigates away from the document.
      final mapRegions = exportedContours.isEmpty
          ? <(String, String)>[('rect', '$x1,$y1,$x2,$y2')]
          : <(String, String)>[
              for (final coordinates in exportedContours) ('poly', coordinates),
            ];
      for (final region in mapRegions) {
        areaTags.writeln(
            '      <area shape="${region.$1}" coords="${region.$2}" '
            'data-original-coords="${region.$2}" href="#$balloonId" role="button" '
            'alt="${_escapeHtml(item.name)}" '
            'title="${_escapeHtml(item.name)} (${item.formattedPrice})" '
            'aria-controls="$balloonId" aria-expanded="false" '
            'aria-haspopup="dialog" '
            'data-item-id="$escapedItemId" tabindex="-1">');
      }

      // Modern Interactive Layered Element (CSS/JS)
      final badgeText = item.isPersonal ? '개인 물품*' : '공용 물품';
      final badgeClass = item.isPersonal ? 'badge-personal' : 'badge-common';
      final balloonAction = safeTargetUrl == null
          ? '<span class="balloon-btn is-disabled" aria-disabled="true">'
              '직접 구매 링크 없음</span>'
          : '<a href="$escapedTargetUrl" target="_blank" '
              'rel="noopener noreferrer" class="balloon-btn">'
              'Target에서 구매하기 ↗</a>';

      itemOverlays.writeln('''
        <div class="curator-item" style="left: $leftPercent%; top: $topPercent%; width: $widthPercent%; height: $heightPercent%;" data-id="$escapedItemId">
          <button type="button" class="item-trigger" title="${_escapeHtml(item.name)}" aria-label="${_escapeHtml('${item.name}, ${item.formattedPrice} 정보 보기')}" aria-controls="$balloonId" aria-expanded="false" aria-haspopup="dialog"$clipStyle>
            <img src="$escapedImageSource" alt="${_escapeHtml(item.name)}" class="item-img" />
          </button>
          <div class="speech-balloon" id="$balloonId" role="dialog" aria-labelledby="$balloonTitleId">
            <div class="balloon-header">
              <span class="badge $badgeClass">$badgeText</span>
              <span class="price">${item.formattedPrice}</span>
            </div>
            <div class="balloon-title" id="$balloonTitleId">${_escapeHtml(item.name)}</div>
            <div class="balloon-desc">${_escapeHtml(item.description)}</div>
            $balloonAction
          </div>
        </div>''');
    }

    return '''<!DOCTYPE html>
<html lang="ko">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <meta name="referrer" content="no-referrer">
  <title>${_escapeHtml(pageTitle)}</title>
  <style>
    :root {
      --bg-color: #F8FAFC;
      --card-bg: #FFFFFF;
      --text-main: #0F172A;
      --text-muted: #64748B;
      --target-red: #CC0000;
      --target-red-hover: #AA0000;
      --shadow-lg: 0 25px 50px -12px rgba(15, 23, 42, 0.12), 0 0 0 1px rgba(226, 232, 240, 0.8);
      --shadow-balloon: 0 20px 30px -5px rgba(0, 0, 0, 0.3), 0 10px 10px -5px rgba(0, 0, 0, 0.2);
    }
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body {
      font-family: -apple-system, BlinkMacSystemFont, "Pretendard", "Segoe UI", Roboto, sans-serif;
      background-color: var(--bg-color);
      color: var(--text-main);
      padding: 30px 20px;
      display: flex;
      flex-direction: column;
      align-items: center;
      min-height: 100vh;
      overflow-x: hidden;
    }
    header {
      text-align: center;
      margin-bottom: 24px;
      max-width: 800px;
    }
    h1 {
      font-size: 26px;
      font-weight: 800;
      color: var(--text-main);
      letter-spacing: -0.5px;
      margin-bottom: 8px;
    }
    p.subtitle {
      font-size: 14px;
      color: var(--text-muted);
      line-height: 1.4;
    }
    main {
      display: flex;
      justify-content: center;
      width: 100%;
    }
    .canvas-container {
      position: relative;
      width: min(100%, ${canvasWidth.toInt()}px);
      aspect-ratio: ${canvasWidth.toStringAsFixed(3)} / ${canvasHeight.toStringAsFixed(3)};
      background: #FFFFFF;
      background-image: radial-gradient(#CBD5E1 1px, transparent 1px);
      background-size: 32px 32px;
      border-radius: 20px;
      box-shadow: var(--shadow-lg);
      overflow: visible;
      margin: 0 auto;
    }
    .image-map-hit-layer {
      position: absolute;
      inset: 0;
      z-index: 1;
      display: block;
      width: 100%;
      height: 100%;
      opacity: 0;
    }
    .curator-item {
      position: absolute;
      transition: transform 0.22s cubic-bezier(0.34, 1.56, 0.64, 1), z-index 0.1s ease;
      cursor: pointer;
      user-select: none;
      pointer-events: none;
      z-index: 2;
    }
    .curator-item .item-trigger {
      appearance: none;
      border: 0;
      margin: 0;
      padding: 0;
      background: transparent;
      display: block;
      width: 100%;
      height: 100%;
      cursor: pointer;
      pointer-events: auto;
    }
    .curator-item .item-trigger:focus-visible {
      outline: 3px solid #0891B2;
      outline-offset: 4px;
    }
    .curator-item .item-img {
      display: block;
      width: 100%;
      height: 100%;
      object-fit: contain;
      filter: grayscale(100%);
      transition: filter 0.2s ease, transform 0.2s ease;
      pointer-events: none;
    }
    .curator-item:hover,
    .curator-item:focus-within,
    .curator-item.is-open {
      z-index: 99 !important;
      transform: scale(1.12);
    }
    .curator-item:hover .item-img,
    .curator-item:focus-within .item-img,
    .curator-item.is-open .item-img {
      filter: grayscale(0%);
    }
    .speech-balloon {
      position: absolute;
      bottom: calc(100% + 14px);
      left: 50%;
      transform: translateX(calc(-50% + var(--balloon-shift-x, 0px))) translateY(8px);
      width: min(270px, calc(100vw - 32px));
      background: #0F172A;
      color: #FFFFFF;
      padding: 14px 16px;
      border-radius: 16px;
      box-shadow: var(--shadow-balloon);
      pointer-events: none;
      opacity: 0;
      visibility: hidden;
      transition: opacity 0.2s ease, transform 0.2s cubic-bezier(0.34, 1.56, 0.64, 1), visibility 0.2s;
      z-index: 100;
    }
    .speech-balloon::before {
      content: '';
      position: absolute;
      top: 100%;
      left: 0;
      width: 100%;
      height: 18px;
    }
    .speech-balloon::after {
      content: '';
      position: absolute;
      top: 100%;
      left: 50%;
      margin-left: -8px;
      border-width: 8px;
      border-style: solid;
      border-color: #0F172A transparent transparent transparent;
    }
    .curator-item:hover .speech-balloon,
    .curator-item:focus-within .speech-balloon,
    .curator-item.is-open .speech-balloon {
      opacity: 1;
      visibility: visible;
      transform: translateX(calc(-50% + var(--balloon-shift-x, 0px))) translateY(0);
      pointer-events: auto;
    }
    .balloon-header {
      display: flex;
      justify-content: space-between;
      align-items: center;
      margin-bottom: 6px;
    }
    .badge {
      font-size: 10px;
      font-weight: 800;
      padding: 2px 7px;
      border-radius: 5px;
    }
    .badge-personal { background: #FEF08A; color: #854D0E; }
    .badge-common { background: #334155; color: #E2E8F0; }
    .price { font-size: 13.5px; font-weight: 900; color: #4ADE80; }
    .balloon-title { font-size: 12.5px; font-weight: 700; margin-bottom: 4px; line-height: 1.35; }
    .balloon-desc { font-size: 10.5px; color: #94A3B8; margin-bottom: 10px; line-height: 1.35; }
    .balloon-btn {
      display: block;
      text-align: center;
      background: var(--target-red);
      color: #FFFFFF;
      font-size: 11.5px;
      font-weight: 700;
      padding: 7px 10px;
      border-radius: 8px;
      text-decoration: none;
      transition: background 0.15s ease;
    }
    .balloon-btn:hover { background: var(--target-red-hover); }
    .balloon-btn.is-disabled {
      background: #475569;
      color: #CBD5E1;
      cursor: not-allowed;
    }
    footer {
      margin-top: 24px;
      font-size: 12px;
      color: var(--text-muted);
    }
    @media (max-width: 600px) {
      body { padding: 20px 8px; }
      h1 { font-size: 21px; }
      p.subtitle { font-size: 12px; }
      .canvas-container { border-radius: 12px; }
    }
    @media (prefers-reduced-motion: reduce) {
      .curator-item,
      .curator-item .item-img,
      .speech-balloon { transition: none; }
    }
  </style>
</head>
<body>
  <header>
    <h1>${_escapeHtml(pageTitle)}</h1>
    <p class="subtitle">마우스를 올리거나 상품을 선택하면 컬러와 가격 태그가 나타납니다. 말풍선 안의 버튼으로 Target 구매 페이지를 엽니다.</p>
  </header>

  <main>
    <div class="canvas-container">
      <svg aria-hidden="true" width="0" height="0" focusable="false">
        <defs>
$clipDefinitions        </defs>
      </svg>
      <img class="image-map-hit-layer" src="$_transparentPixelDataUri" usemap="#target-curator-map" width="${canvasWidth.toInt()}" height="${canvasHeight.toInt()}" alt="">
$itemOverlays
      <!-- Standard HTML5 Image Map -->
      <map id="target-curator-map" name="target-curator-map">
$areaTags      </map>
    </div>
  </main>

  <footer>
    <p>Generated by ShopItem Curator &bull; 100% Self-Contained Base64 Embedded HTML</p>
  </footer>
  <script>
    (() => {
      const canvas = document.querySelector('.canvas-container');
      const hitImage = document.querySelector('.image-map-hit-layer');
      const items = Array.from(document.querySelectorAll('.curator-item'));
      const areas = Array.from(document.querySelectorAll('area[data-item-id]'));
      const itemById = new Map(items.map((item) => [item.dataset.id, item]));

      const setOpen = (targetItem, shouldOpen) => {
        for (const item of items) {
          const expanded = item === targetItem && shouldOpen;
          item.classList.toggle('is-open', expanded);
          item.querySelector('.item-trigger')
            ?.setAttribute('aria-expanded', String(expanded));
          for (const area of areas) {
            if (area.dataset.itemId === item.dataset.id) {
              area.setAttribute('aria-expanded', String(expanded));
            }
          }
        }
        if (shouldOpen) fitBalloon(targetItem);
      };

      const closeAll = () => setOpen(null, false);

      const fitBalloon = (item) => {
        if (!item) return;
        const balloon = item.querySelector('.speech-balloon');
        if (!balloon) return;
        balloon.style.setProperty('--balloon-shift-x', '0px');
        requestAnimationFrame(() => {
          const rect = balloon.getBoundingClientRect();
          const viewportWidth = document.documentElement.clientWidth;
          const margin = 8;
          let shift = 0;
          if (rect.left < margin) shift += margin - rect.left;
          if (rect.right + shift > viewportWidth - margin) {
            shift -= rect.right + shift - (viewportWidth - margin);
          }
          balloon.style.setProperty('--balloon-shift-x', String(shift) + 'px');
        });
      };

      document.addEventListener('click', (event) => {
        const element = event.target instanceof Element ? event.target : null;
        if (!element) return;

        const trigger = element.closest('.item-trigger');
        if (trigger) {
          const item = trigger.closest('.curator-item');
          if (!item) return;
          event.preventDefault();
          setOpen(item, !item.classList.contains('is-open'));
          return;
        }

        const area = element.closest('area[data-item-id]');
        if (area) {
          const item = itemById.get(area.dataset.itemId);
          if (!item) return;
          event.preventDefault();
          setOpen(item, !item.classList.contains('is-open'));
          item.querySelector('.item-trigger')?.focus();
          return;
        }

        if (!element.closest('.curator-item')) closeAll();
      });

      document.addEventListener('keydown', (event) => {
        if (event.key !== 'Escape') return;
        const openItem = document.querySelector('.curator-item.is-open');
        if (!openItem) return;
        event.preventDefault();
        closeAll();
        openItem.querySelector('.item-trigger')?.focus();
      });

      for (const item of items) {
        item.addEventListener('mouseenter', () => fitBalloon(item));
        item.addEventListener('focusin', () => setOpen(item, true));
      }

      const resizeImageMap = () => {
        if (!canvas || !hitImage) return;
        const scaleX = hitImage.clientWidth / ${canvasWidth.toStringAsFixed(6)};
        const scaleY = hitImage.clientHeight / ${canvasHeight.toStringAsFixed(6)};
        for (const area of areas) {
          const original = area.dataset.originalCoords
            ?.split(',')
            .map((value) => Number.parseFloat(value));
          if (!original || original.some((value) => !Number.isFinite(value))) {
            continue;
          }
          area.coords = original
            .map((value, index) => Math.round(value * (index % 2 === 0 ? scaleX : scaleY)))
            .join(',');
        }
        const openItem = document.querySelector('.curator-item.is-open');
        if (openItem) fitBalloon(openItem);
      };

      if ('ResizeObserver' in window && hitImage) {
        new ResizeObserver(resizeImageMap).observe(hitImage);
      } else {
        window.addEventListener('resize', resizeImageMap);
      }
      resizeImageMap();
    })();
  </script>
</body>
</html>''';
  }

  static String _asPercentage(double value, double total) {
    if (!value.isFinite || !total.isFinite || total <= 0) return '0';
    return ((value / total) * 100).toStringAsFixed(6);
  }

  static String _escapeHtml(String text) {
    return text
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;')
        .replaceAll("'", '&#39;');
  }

  static List<String> _exportContours(PositionedItemExportData data) {
    final item = data.item;
    if (item.bounds.width <= 0 || item.bounds.height <= 0) {
      return const [];
    }

    return [
      for (final contour in item.contours)
        if (contour.length >= 3)
          contour.map((point) {
            final relativeX = (point.x - item.bounds.x) / item.bounds.width;
            final relativeY = (point.y - item.bounds.y) / item.bounds.height;
            final x = data.x + relativeX * data.scaledWidth;
            final y = data.y + relativeY * data.scaledHeight;
            return '${x.round()},${y.round()}';
          }).join(','),
    ];
  }

  static String? _svgClipPath(
    CuratorItem item,
    int index,
    StringBuffer definitions,
  ) {
    if (item.bounds.width <= 0 || item.bounds.height <= 0) return null;
    final pathSegments = <String>[];
    for (final contour in item.contours) {
      if (contour.length < 3) continue;
      final points = contour.map((point) {
        final x = ((point.x - item.bounds.x) / item.bounds.width)
            .clamp(0.0, 1.0)
            .toStringAsFixed(6);
        final y = ((point.y - item.bounds.y) / item.bounds.height)
            .clamp(0.0, 1.0)
            .toStringAsFixed(6);
        return '$x $y';
      }).toList(growable: false);
      pathSegments.add(
        'M ${points.first} ${points.skip(1).map((point) => 'L $point').join(' ')} Z',
      );
    }
    if (pathSegments.isEmpty) return null;

    final id = 'curator-compound-clip-$index';
    definitions.writeln(
      '          <clipPath id="$id" clipPathUnits="objectBoundingBox">'
      '<path d="${pathSegments.join(' ')}" fill-rule="evenodd" '
      'clip-rule="evenodd" /></clipPath>',
    );
    return 'url(#$id)';
  }

  static String? _cssClipPath(CuratorItem item) {
    if (item.polygon.length < 3 ||
        item.bounds.width <= 0 ||
        item.bounds.height <= 0) {
      return null;
    }

    final points = item.polygon.map((point) {
      final x = ((point.x - item.bounds.x) / item.bounds.width * 100)
          .clamp(0.0, 100.0);
      final y = ((point.y - item.bounds.y) / item.bounds.height * 100)
          .clamp(0.0, 100.0);
      return '${x.toStringAsFixed(3)}% ${y.toStringAsFixed(3)}%';
    }).join(', ');
    return 'polygon($points)';
  }

  static String? _safeHttpUrl(String value) {
    final candidate = value.trim();
    if (candidate.isEmpty || _containsControlCharacter(candidate)) {
      return null;
    }

    final uri = Uri.tryParse(candidate);
    if (uri == null || uri.host.isEmpty) {
      return null;
    }

    final scheme = uri.scheme.toLowerCase();
    return scheme == 'http' || scheme == 'https' ? candidate : null;
  }

  static String? _safeImageSource(String value) {
    final candidate = value.trim();
    if (candidate.isEmpty || _containsControlCharacter(candidate)) {
      return null;
    }

    if (_safeImageDataUriPattern.hasMatch(candidate)) {
      return candidate;
    }

    final remoteUrl = _safeHttpUrl(candidate);
    if (remoteUrl != null) {
      return remoteUrl;
    }

    final uri = Uri.tryParse(candidate);
    if (uri != null &&
        uri.scheme.isEmpty &&
        !uri.hasAuthority &&
        (candidate.startsWith('assets/') ||
            candidate.startsWith('packages/'))) {
      return candidate;
    }

    return null;
  }

  static bool _containsControlCharacter(String value) =>
      value.codeUnits.any((unit) => unit < 0x20 || unit == 0x7f);
}

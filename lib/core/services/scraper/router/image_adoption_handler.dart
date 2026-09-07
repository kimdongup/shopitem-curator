// Pure Dart Service (Zero Flutter Dependencies)

/// [Crawlee Router Handler: Image Adoption]
/// Target Scene7 이미지 엘리먼트 및 UUID v4 정규식을 통한 1200w 고해상도 메인 컷 채택 핸들러
class ImageAdoptionHandler {
  const ImageAdoptionHandler();

  // UUID v4 패턴: 8-4-4-4-12 hex 형식 (e.g. e011a984-ba75-4ccd-a110-6297483e7190)
  static final RegExp _guestUuidPattern = RegExp(
    r'(https://target\.scene7\.com/is/image/Target/'
    r'GUEST_[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})',
    caseSensitive: false,
  );

  /// GUEST Scene7 URL에서 UUID v4 베이스(확장자·파라미터 전)를 정밀 추출합니다.
  /// .avif / .webp / .jpg / ?wid= 등이 붙어 있어도 올바르게 분리됩니다.
  static String? extractGuestImageBase(String rawUrl) {
    final m = _guestUuidPattern.firstMatch(rawUrl);
    if (m == null) return null;
    return m.group(1)!;
  }

  /// 베이스 GUEST URL에 고화질 파라미터를 붙여 반환합니다.
  static String buildHighResUrl(String base) =>
      '$base?wid=1200&hei=1200&qlt=85&fmt=pjpeg';

  /// HTML 엘리먼트(og:image, srcSet 1200w, Scene7 직접 링크)에서 최상위 해상도 URL 추출
  static String? extractTargetMainImageElement(String html) {
    // 1. og:image (property before content)
    final ogMatch1 = RegExp(
      r'<meta[^>]*?property=["\x27]og:image["\x27][^>]*?content=["\x27]'
      r'(https://target\.scene7\.com[^\s"\x27]+)["\x27]',
      caseSensitive: false,
    ).firstMatch(html);
    if (ogMatch1 != null) {
      final base = extractGuestImageBase(ogMatch1.group(1)!);
      if (base != null) return buildHighResUrl(base);
    }

    // 1b. og:image (content before property)
    final ogMatch2 = RegExp(
      r'<meta[^>]*?content=["\x27]'
      r'(https://target\.scene7\.com[^\s"\x27]+)["\x27][^>]*?property=["\x27]og:image["\x27]',
      caseSensitive: false,
    ).firstMatch(html);
    if (ogMatch2 != null) {
      final base = extractGuestImageBase(ogMatch2.group(1)!);
      if (base != null) return buildHighResUrl(base);
    }

    // 2. srcSet 최고 해상도 (1200w > 1000w > 800w 순서)
    for (final res in ['1200w', '1000w', '800w']) {
      final escapedResolution = RegExp.escape(res);
      final srcSetMatch = RegExp(
        r'(https://target\.scene7\.com/is/image/Target/'
        r'GUEST_[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})'
        r'[^\s"]*?\s+'
        '$escapedResolution',
        caseSensitive: false,
      ).firstMatch(html);
      if (srcSetMatch != null) {
        return buildHighResUrl(srcSetMatch.group(1)!);
      }
    }

    // 3. 직접 GUEST UUID URL (UUID v4 정밀 매칭)
    final directMatch = _guestUuidPattern.firstMatch(html);
    if (directMatch != null) {
      return buildHighResUrl(directMatch.group(1)!);
    }

    return null;
  }
}

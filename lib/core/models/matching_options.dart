/// Public strategy flags only. Proxy endpoints, credentials and executable
/// paths never cross the authenticated server boundary into this model.
enum MatchingStrategy {
  headerRotation('header_rotation', '1. 요청 헤더 프로필 교체',
      'HTTP 요청의 User-Agent·언어·Client Hints 조합을 교체합니다. 실제 브라우저의 TLS 지문까지 복제하지는 않습니다.'),
  proxyPool('proxy_pool', '2. 서버 프록시 풀',
      '운영자가 등록한 프록시를 순환합니다. 주거용 여부는 제공자와 계약에서 확인해야 하며 무료 프록시를 자동 수집하지 않습니다.'),
  randomDelay('random_delay', '3a. 랜덤 요청 간격',
      '요청 시작 간격에 1.2~3.8초 지연을 적용합니다. Retry-After와 차단 중지는 그대로 따릅니다.'),
  browserInteraction('browser_interaction', '3b. 브라우저 이동·스크롤',
      '별도 브라우저에서 제한된 마우스 이동과 스크롤로 페이지 렌더링을 기다립니다. 구매 버튼은 클릭하지 않습니다.'),
  stealthBrowser('stealth_browser', '4. webdriver 표시 숨김 (실험)',
      '별도 Chromium 컨텍스트의 navigator.webdriver 표시를 숨깁니다. 모든 자동화 탐지가 사라지는 것은 아닙니다.'),
  observedJson('observed_json', '5. 페이지의 상품 JSON 응답 관찰',
      '페이지가 실제로 받은 허용된 GET/XHR/Fetch JSON에서 상품 메타데이터를 읽습니다. 인증정보 복사나 임의 API 재호출은 하지 않습니다.');

  const MatchingStrategy(this.id, this.title, this.description);
  final String id;
  final String title;
  final String description;
}

final class MatchingOptions {
  MatchingOptions([Iterable<MatchingStrategy> enabled = const []])
      : enabled = Set.unmodifiable(enabled);
  final Set<MatchingStrategy> enabled;
  bool has(MatchingStrategy strategy) => enabled.contains(strategy);
  bool get usesBrowser =>
      has(MatchingStrategy.browserInteraction) ||
      has(MatchingStrategy.stealthBrowser) ||
      has(MatchingStrategy.observedJson);
  bool get isDefault => enabled.isEmpty;
  String get key =>
      MatchingStrategy.values.where(has).map((s) => s.id).join('+');
  MatchingOptions toggle(MatchingStrategy strategy, bool value) =>
      MatchingOptions(
          value ? {...enabled, strategy} : enabled.where((s) => s != strategy));
  Map<String, Object?> toJson() =>
      {'enabled': MatchingStrategy.values.where(has).map((s) => s.id).toList()};

  factory MatchingOptions.fromJson(Object? value) {
    if (value == null) return MatchingOptions();
    if (value is! Map || value.length != 1 || value['enabled'] is! List) {
      throw const FormatException('Invalid matching options.');
    }
    final values = value['enabled'] as List;
    if (values.length > MatchingStrategy.values.length) {
      throw const FormatException('Too many strategies.');
    }
    final result = <MatchingStrategy>{};
    for (final id in values) {
      final strategy =
          MatchingStrategy.values.where((s) => s.id == id).firstOrNull;
      if (strategy == null || !result.add(strategy)) {
        throw const FormatException('Unknown or repeated strategy.');
      }
    }
    return MatchingOptions(result);
  }
}

final class MatchingCapability {
  const MatchingCapability(
      {required this.strategy, required this.available, this.reason = ''});
  final MatchingStrategy strategy;
  final bool available;
  final String reason;
  Map<String, Object?> toJson() =>
      {'id': strategy.id, 'available': available, 'reason': reason};
  static List<MatchingCapability> parse(Object? value) {
    if (value is! List) {
      throw const FormatException('Invalid matching capabilities.');
    }
    final result = <MatchingCapability>[];
    for (final entry in value) {
      if (entry is! Map ||
          entry['available'] is! bool ||
          entry['reason'] is! String) {
        throw const FormatException('Invalid matching capability.');
      }
      final strategy =
          MatchingStrategy.values.where((s) => s.id == entry['id']).firstOrNull;
      if (strategy == null || result.any((c) => c.strategy == strategy)) {
        throw const FormatException('Invalid strategy.');
      }
      result.add(MatchingCapability(
          strategy: strategy,
          available: entry['available'] as bool,
          reason: entry['reason'] as String));
    }
    return List.unmodifiable(result);
  }
}

import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart' show parseHttpDate;

enum TargetLookupFailure {
  accessDenied,
  rateLimited,
  timeout,
  upstreamFailure,
  invalidResponse,
  noProductData,
}

/// Safe diagnostic: never contains response bodies, request URLs or API keys.
final class TargetLookupException implements Exception {
  const TargetLookupException(this.kind);
  final TargetLookupFailure kind;

  String get code => switch (kind) {
        TargetLookupFailure.accessDenied => 'target_access_denied',
        TargetLookupFailure.rateLimited => 'target_rate_limited',
        TargetLookupFailure.timeout => 'target_timeout',
        TargetLookupFailure.upstreamFailure => 'target_upstream_failed',
        TargetLookupFailure.invalidResponse => 'target_invalid_response',
        TargetLookupFailure.noProductData => 'target_no_product_data',
      };

  String get message => switch (kind) {
        TargetLookupFailure.accessDenied =>
          'Target이 접근을 거부했습니다. 승인된 상품 데이터 접근 권한을 확인하세요.',
        TargetLookupFailure.rateLimited =>
          'Target 요청 한도에 도달했습니다. 잠시 후 다시 시도하세요.',
        TargetLookupFailure.timeout => 'Target 상품 조회 시간이 초과되었습니다.',
        TargetLookupFailure.upstreamFailure => 'Target 상품 서버에 연결하지 못했습니다.',
        TargetLookupFailure.invalidResponse => 'Target 응답 형식이 예상과 다릅니다.',
        TargetLookupFailure.noProductData =>
          'Target 검색 페이지에 조회 가능한 상품 데이터가 없습니다. 상품이 없다는 뜻은 아닙니다. 승인된 상품 데이터 피드 또는 직접 구매 URL 확인이 필요합니다.',
      };

  @override
  String toString() => message;
}

/// One policy per catalog service, shared by search, PDP and review requests.
/// A 401/403 stops further requests to that host for this service lifetime.
/// Never rotates identities, retries denied requests or solves challenges.
final class TargetRequestPolicy {
  TargetRequestPolicy({DateTime Function()? now}) : _now = now ?? DateTime.now;

  final DateTime Function() _now;
  final Set<String> _deniedHosts = {};
  final Set<String> _rateLimitedHosts = {};
  final Map<String, DateTime> _retryAt = {};

  static const headers = {
    'User-Agent': 'ShopItemCurator/1.0',
    'Accept': 'text/html,application/json',
    'Accept-Language': 'en-US,en;q=0.9',
    // Leave compression negotiation to the HTTP transport. Advertising br or
    // deflate without a decoder can turn a 200 response into unreadable text.
  };

  Future<http.Response> get(http.Client client, Uri uri,
      {Duration timeout = const Duration(seconds: 5)}) async {
    if (_deniedHosts.contains(uri.host)) {
      throw const TargetLookupException(TargetLookupFailure.accessDenied);
    }
    final retryAt = _retryAt[uri.host];
    if (_rateLimitedHosts.contains(uri.host) ||
        (retryAt != null && _now().isBefore(retryAt))) {
      throw const TargetLookupException(TargetLookupFailure.rateLimited);
    }
    late final http.Response response;
    try {
      response = await client.get(uri, headers: headers).timeout(timeout);
    } on TimeoutException {
      throw const TargetLookupException(TargetLookupFailure.timeout);
    } on Exception {
      throw const TargetLookupException(TargetLookupFailure.upstreamFailure);
    }
    if (response.statusCode == 401 || response.statusCode == 403) {
      _deniedHosts.add(uri.host);
      throw const TargetLookupException(TargetLookupFailure.accessDenied);
    }
    if (response.statusCode == 429) {
      final retryAfter = response.headers['retry-after']?.trim();
      final seconds = int.tryParse(retryAfter ?? '');
      if (retryAfter == null || (seconds != null && seconds >= 0)) {
        _retryAt[uri.host] =
            _now().add(Duration(seconds: (seconds ?? 60).clamp(1, 2147483647)));
      } else {
        try {
          _retryAt[uri.host] = parseHttpDate(retryAfter);
        } on FormatException {
          // Unknown server instructions must not trigger early retries or be
          // misreported as a 403. Pause this host until the operator checks it.
          _rateLimitedHosts.add(uri.host);
        }
      }
      throw const TargetLookupException(TargetLookupFailure.rateLimited);
    }
    if (response.statusCode >= 500) {
      throw const TargetLookupException(TargetLookupFailure.upstreamFailure);
    }
    return response;
  }
}

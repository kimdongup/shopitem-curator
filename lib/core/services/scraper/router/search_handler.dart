// Pure Dart Service (Zero Flutter Dependencies)

import 'dart:convert';
import 'package:http/http.dart' as http;
import '../../../models/target_purchase_url.dart';
import '../session/session_pool.dart';
import '../target_request_policy.dart';

class SearchResolutionResult {
  const SearchResolutionResult({
    required this.name,
    required this.pdpUrl,
    required this.price,
    this.primaryGuestId,
    this.description,
  });

  final String name;
  final String pdpUrl;
  final double price;
  final String? primaryGuestId;
  final String? description;
}

/// [Crawlee Router Handler: Search & Matching]
/// Public HTML search; RedSky is optional and requires operator-owned access.
class SearchHandler {
  const SearchHandler({this.redSkyApiKey});
  final String? redSkyApiKey;

  /// 쿼리와 상품명 간의 토큰 기반 유사도 점수를 계산합니다.
  static double scoreSimilarity(String query, String productTitle) {
    final qTokens = query.toLowerCase().split(RegExp(r'\s+'));
    final tTokens = productTitle.toLowerCase().split(RegExp(r'\s+'));

    var score = 0.0;
    for (final qt in qTokens) {
      if (qt.isEmpty) continue;
      // 완전 일치 토큰
      if (tTokens.contains(qt)) {
        final isNumeric =
            RegExp(r'^[\d\.]+(?:fl|oz|ct|pk|count)?$').hasMatch(qt);
        score += isNumeric ? 3.0 : 1.5;
      } else {
        // 부분 포함
        for (final tt in tTokens) {
          if (tt.contains(qt) || qt.contains(tt)) {
            score += 0.5;
            break;
          }
        }
      }
    }
    final lenDiff = (qTokens.length - tTokens.length).abs();
    score -= lenDiff * 0.1;
    return score;
  }

  /// Target 검색을 통해 최적의 구매 상세페이지(PDP) URL을 확보합니다.
  Future<SearchResolutionResult?> searchPdpUrl({
    required String query,
    required http.Client client,
    required SessionPool sessionPool,
  }) async {
    final cleanQuery = query.trim();
    if (cleanQuery.isEmpty) return null;

    // 1-1. Target RedSky Search API (top-5 수집 + 스폰서 필터 + 스코어링)
    TargetLookupException? apiFailure;
    if (redSkyApiKey?.trim().isNotEmpty == true) {
      try {
        final redskyResult = await _searchViaRedSky(
            query: cleanQuery, client: client, sessionPool: sessionPool);
        if (redskyResult != null) return redskyResult;
      } on TargetLookupException catch (error) {
        apiFailure = error;
      }
    }

    // 1-2. 웹 검색 페이지 HTML Fallback
    try {
      final result = await _searchViaHtmlFallback(
          query: cleanQuery, client: client, sessionPool: sessionPool);
      if (result == null && apiFailure != null) throw apiFailure;
      return result;
    } on TargetLookupException catch (error) {
      // An empty/unavailable fallback must not hide the configured API error.
      throw apiFailure ?? error;
    }
  }

  Future<SearchResolutionResult?> _searchViaRedSky({
    required String query,
    required http.Client client,
    required SessionPool sessionPool,
  }) async {
    try {
      final redskyUrl = Uri.parse(
        'https://redsky.target.com/redsky_aggregations/v1/web/plp_search_v2'
        '?key=${Uri.encodeQueryComponent(redSkyApiKey!)}'
        '&channel=WEB'
        '&count=5'
        '&keyword=${Uri.encodeComponent(query)}',
      );

      final resp = await sessionPool.requests.get(client, redskyUrl);

      if (resp.statusCode == 200) {
        final json = jsonDecode(resp.body) as Map<String, dynamic>;
        final products =
            json['data']?['search']?['products'] as List<dynamic>? ?? [];

        final candidates = <(double score, Map<String, dynamic> product)>[];
        for (final p in products) {
          final itemData = p['item'] as Map<String, dynamic>?;
          final isSponsored = (p['labels'] as List<dynamic>? ?? []).any((l) =>
              (l as String?)?.toLowerCase().contains('sponsored') ?? false);
          if (isSponsored) continue;

          final title = itemData?['product_description']?['title'] as String?;
          if (title == null) continue;

          final score = scoreSimilarity(query, title);
          candidates.add((score, p));
        }

        candidates.sort((a, b) => b.$1.compareTo(a.$1));

        if (candidates.isNotEmpty) {
          final best = candidates.first.$2;
          final itemData = best['item'] as Map<String, dynamic>?;
          final priceData = best['price'] as Map<String, dynamic>?;
          final title = itemData?['product_description']?['title'] as String?;
          final guestId = itemData?['enrichment']?['images']
              ?['primary_image_id'] as String?;
          // Missing catalog prices stay unknown. Reusing an arbitrary
          // fallback price would present fabricated purchase information.
          final currentPrice =
              (priceData?['current_retail'] as num?)?.toDouble() ?? 0.0;
          final urlSuffix = itemData?['buy_url'] as String? ?? '';

          if (title != null && urlSuffix.isNotEmpty) {
            final fullPdpUrl = urlSuffix.startsWith('http')
                ? urlSuffix
                : 'https://www.target.com$urlSuffix';
            final purchaseUrl = TargetPurchaseUrl.tryParse(fullPdpUrl);
            if (purchaseUrl == null) {
              return null;
            }
            return SearchResolutionResult(
              name: title,
              pdpUrl: purchaseUrl.toString(),
              price: currentPrice,
              primaryGuestId: guestId,
              description:
                  'Target 검색 최고 유사도 상품 (RedSky API, Crawlee SessionPool)',
            );
          }
        }
        return null;
      }
    } on TargetLookupException {
      rethrow;
    } on Object {
      throw const TargetLookupException(TargetLookupFailure.invalidResponse);
    }
    return null;
  }

  Future<SearchResolutionResult?> _searchViaHtmlFallback({
    required String query,
    required http.Client client,
    required SessionPool sessionPool,
  }) async {
    try {
      final searchUrl = Uri.parse(
          'https://www.target.com/s?searchTerm=${Uri.encodeComponent(query)}');
      final resp = await sessionPool.requests.get(client, searchUrl);

      if (resp.statusCode == 200) {
        final html = resp.body;
        final pdpUrlMatch = RegExp(
          r'href=["\x27](/p/[^"\x27]+/-/A-\d+[^"\x27]*)["\x27]',
          caseSensitive: false,
        ).firstMatch(html);

        if (pdpUrlMatch != null) {
          final rawUrl = pdpUrlMatch.group(1)!;
          final fullUrl = 'https://www.target.com$rawUrl';
          final purchaseUrl = TargetPurchaseUrl.tryParse(fullUrl);
          if (purchaseUrl == null) {
            return null;
          }
          return SearchResolutionResult(
            name: query,
            pdpUrl: purchaseUrl.toString(),
            price: 0.0,
            description: 'Target 웹 검색 1위 상품 상세페이지',
          );
        }
        throw const TargetLookupException(TargetLookupFailure.noProductData);
      }
    } on TargetLookupException {
      rethrow;
    } on Object {
      throw const TargetLookupException(TargetLookupFailure.invalidResponse);
    }
    return null;
  }
}

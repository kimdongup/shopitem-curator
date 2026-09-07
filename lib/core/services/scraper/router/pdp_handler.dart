// Pure Dart Service (Zero Flutter Dependencies)

import 'dart:convert';
import 'package:http/http.dart' as http;
import '../../../models/target_purchase_url.dart';
import '../session/session_pool.dart';
import 'image_adoption_handler.dart';
import '../target_request_policy.dart';

/// [Crawlee Router Handler: Product Details Page (PDP)]
/// `preselect=TCIN` 기반 PDPv4 API 조회 및 PDP HTML 원본 1200w 이미지 채택
class PdpHandler {
  const PdpHandler({this.redSkyApiKey});
  final String? redSkyApiKey;

  /// PDP URL에서 선택 옵션의 `preselect` TCIN을 우선 추출하고,
  /// 옵션이 없으면 `/A-<TCIN>` 상품 경로의 TCIN을 반환합니다.
  static String? extractTcinFromPdpUrl(String pdpUrl) {
    final purchaseUrl = TargetPurchaseUrl.tryParse(pdpUrl);
    if (purchaseUrl == null) return null;

    final selectedTcin = purchaseUrl.uri.queryParameters['preselect'];
    if (selectedTcin != null && RegExp(r'^\d+$').hasMatch(selectedTcin)) {
      return selectedTcin;
    }

    final pathSegments = purchaseUrl.uri.pathSegments;
    final productId = pathSegments.isEmpty ? null : pathSegments.last;
    final match = RegExp(
      r'^A-(\d+)$',
      caseSensitive: false,
    ).firstMatch(productId ?? '');
    return match?.group(1);
  }

  /// preselect TCIN으로 Target RedSky PDPv4 API를 호출하여
  /// 해당 옵션 전용 GUEST ID 이미지 URL을 반환합니다.
  Future<String?> fetchSelectedVariantImageByTcin({
    required String tcin,
    required http.Client client,
    required SessionPool sessionPool,
  }) async {
    if (redSkyApiKey?.trim().isNotEmpty != true) return null;
    try {
      final pdpV4Url = Uri.parse(
        'https://redsky.target.com/redsky_aggregations/v1/web/pdp_client_v1'
        '?key=${Uri.encodeQueryComponent(redSkyApiKey!)}'
        '&channel=WEB'
        '&tcin=$tcin',
      );

      final resp = await sessionPool.requests.get(client, pdpV4Url);

      if (resp.statusCode == 200) {
        final json = jsonDecode(resp.body) as Map<String, dynamic>;
        final guestId = json['data']?['product']?['item']?['enrichment']
            ?['images']?['primary_image_id'] as String?;

        if (guestId != null && guestId.isNotEmpty) {
          return ImageAdoptionHandler.buildHighResUrl(
            'https://target.scene7.com/is/image/Target/GUEST_$guestId',
          );
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

  /// PDP URL 진입 후 1:1 고해상도(1200w) 메인 이미지를 채택합니다.
  Future<String?> adoptMainImage({
    required String pdpUrl,
    required http.Client client,
    required SessionPool sessionPool,
    String? fallbackImageUrl,
  }) async {
    // 1. 옵션 또는 상품 TCIN이 있으면 PDPv4 API로 정확한 이미지 직접 조회
    final tcin = extractTcinFromPdpUrl(pdpUrl);
    TargetLookupException? apiFailure;
    if (tcin != null) {
      try {
        final variantImage = await fetchSelectedVariantImageByTcin(
          tcin: tcin,
          client: client,
          sessionPool: sessionPool,
        );
        if (variantImage != null) return variantImage;
      } on TargetLookupException catch (error) {
        apiFailure = error;
      }
    }

    // 2. 일반 PDP HTML 파싱
    try {
      final resp = await sessionPool.requests
          .get(client, Uri.parse(pdpUrl), timeout: const Duration(seconds: 6));

      if (resp.statusCode == 200) {
        final imgUrl =
            ImageAdoptionHandler.extractTargetMainImageElement(resp.body);
        if (imgUrl != null) return imgUrl;
      }
    } on TargetLookupException {
      if (fallbackImageUrl == null) rethrow;
    }

    if (fallbackImageUrl == null && apiFailure != null) throw apiFailure;

    return fallbackImageUrl;
  }
}

// Pure Dart Service (Zero Flutter Dependencies)

import 'dart:convert';
import 'package:http/http.dart' as http;
import '../contracts/catalog_gateways.dart';
import '../contracts/curator_use_cases.dart';
import '../models/curator_item.dart';
import '../models/target_purchase_url.dart';
import 'scraper/cache/scrape_cache_store.dart';
import 'scraper/concurrency/concurrent_executor.dart';
import 'scraper/router/image_adoption_handler.dart';
import 'scraper/router/pdp_handler.dart';
import 'scraper/router/search_handler.dart';
import 'scraper/router/observed_product_parser.dart';
import 'scraper/session/session_pool.dart';
import 'scraper/target_request_policy.dart';

export '../contracts/catalog_gateways.dart'
    show ExtractedItemEntry, TargetProductData, TargetProductGateway;

class TargetPdpResolutionResult {
  const TargetPdpResolutionResult({
    required this.name,
    required this.pdpUrl,
    required this.price,
    this.primaryGuestId,
    this.primaryImageUrl,
    this.description,
  });

  final String name;
  final String pdpUrl;
  final double price;
  final String? primaryGuestId;
  final String? primaryImageUrl;
  final String? description;
}

/// [Crawlee Architecture TargetFetcherService]
/// Pure Dart catalog service with bounded concurrency, shared denial policy,
/// ScrapeCacheStore(중복방지 캐시), Router Handlers(Search/PDP/Image)를 기반으로 동작하는 고성능 스크래퍼
class TargetFetcherService
    implements TargetProductGateway, ProductReviewGateway {
  TargetFetcherService({
    http.Client? httpClient,
    this.preferLiveCatalog = false,
    this.preferObservedProducts = false,
    String? redSkyApiKey,
    SessionPool? sessionPool,
    ConcurrentExecutor? concurrentExecutor,
    ScrapeCacheStore? cacheStore,
    SearchHandler? searchHandler,
    PdpHandler? pdpHandler,
  })  : _client = httpClient ?? http.Client(),
        _ownsHttpClient = httpClient == null,
        _sessionPool = sessionPool ?? SessionPool(),
        _concurrentExecutor = concurrentExecutor ??
            const ConcurrentExecutor(defaultConcurrency: 3),
        _cacheStore = cacheStore ?? ScrapeCacheStore(),
        _searchHandler =
            searchHandler ?? SearchHandler(redSkyApiKey: redSkyApiKey),
        _pdpHandler = pdpHandler ?? PdpHandler(redSkyApiKey: redSkyApiKey),
        _redSkyApiKey = redSkyApiKey;

  final http.Client _client;
  final String? _redSkyApiKey;
  final Map<String, Future<TargetPdpResolutionResult?>> _pendingSearches = {};
  final bool _ownsHttpClient;
  final bool preferLiveCatalog;
  final bool preferObservedProducts;
  final SessionPool _sessionPool;
  final ConcurrentExecutor _concurrentExecutor;
  final ScrapeCacheStore _cacheStore;
  final SearchHandler _searchHandler;
  final PdpHandler _pdpHandler;

  /// 정적 위임: HTML 엘리먼트에서 1200w Scene7 이미지 추출 (기존 단위 테스트 및 호출 호환)
  static String? extractTargetMainImageElement(String html) =>
      ImageAdoptionHandler.extractTargetMainImageElement(html);

  /// Extracts a current PDP price from structured product metadata.
  ///
  /// Target changes its visual page markup frequently, so price extraction is
  /// intentionally limited to machine-readable JSON-LD offers and standard
  /// product price meta tags. Returning `null` is safer than inventing a price.
  static double? extractTargetPriceFromHtml(String html) {
    final jsonLdScripts = RegExp(
      r'''<script\b[^>]*\btype\s*=\s*["']application/ld\+json["'][^>]*>([\s\S]*?)</script>''',
      caseSensitive: false,
    ).allMatches(html);

    for (final match in jsonLdScripts) {
      final source = match.group(1)?.trim();
      if (source == null || source.isEmpty) continue;
      try {
        final price = _findJsonLdOfferPrice(jsonDecode(source));
        if (price != null) return price;
      } on FormatException {
        // A malformed script must not prevent checking other metadata blocks.
      }
    }

    final metaTags = RegExp(
      r'''<meta\b[^>]*>''',
      caseSensitive: false,
    ).allMatches(html);
    final attributePattern = RegExp(
      r'''\b(property|name|itemprop|content)\s*=\s*(["'])(.*?)\2''',
      caseSensitive: false,
    );

    for (final tagMatch in metaTags) {
      final attributes = <String, String>{};
      for (final attribute in attributePattern.allMatches(tagMatch.group(0)!)) {
        attributes[attribute.group(1)!.toLowerCase()] = attribute.group(3)!;
      }
      final priceKey = (attributes['property'] ??
              attributes['name'] ??
              attributes['itemprop'])
          ?.toLowerCase();
      if (priceKey == 'product:price:amount' ||
          priceKey == 'og:price:amount' ||
          priceKey == 'price') {
        final price = _parsePrice(attributes['content']);
        if (price != null) return price;
      }
    }

    return null;
  }

  static double? _findJsonLdOfferPrice(Object? value) {
    if (value is List) {
      for (final entry in value) {
        final price = _findJsonLdOfferPrice(entry);
        if (price != null) return price;
      }
      return null;
    }
    if (value is! Map) return null;

    final map = value.cast<Object?, Object?>();
    final type = map['@type']?.toString().toLowerCase();
    if (type == 'offer' || type == 'aggregateoffer') {
      for (final key in const ['price', 'lowPrice', 'highPrice']) {
        final price = _parsePrice(map[key]);
        if (price != null) return price;
      }
    }

    final offers = map['offers'];
    if (offers != null) {
      final price = _findJsonLdOfferPrice(offers);
      if (price != null) return price;
    }

    for (final entry in map.entries) {
      if (entry.key == 'offers') continue;
      final price = _findJsonLdOfferPrice(entry.value);
      if (price != null) return price;
    }
    return null;
  }

  static double? _parsePrice(Object? value) {
    if (value is num) {
      final price = value.toDouble();
      return price.isFinite && price > 0 ? price : null;
    }
    if (value is! String) return null;

    final normalized = value.replaceAll(',', '').trim();
    final match = RegExp(r'\d+(?:\.\d+)?').firstMatch(normalized);
    final price = match == null ? null : double.tryParse(match.group(0)!);
    return price != null && price.isFinite && price > 0 ? price : null;
  }

  /// Target catalog mapping with real product details and transparent silhouette cutouts
  static const Map<String, Map<String, dynamic>> _knownTargetItems = {
    'hand sanitizer': {
      'name': 'Aloe Hand Sanitizer Gel - 8 fl oz - up&up™',
      'price': 1.69,
      'targetUrl': 'https://www.target.com/p/-/A-81412195',
      'imageUrl': 'assets/items/item_hand_sanitizer.png',
      'description': 'Target 1위 검색 상품: 알로에 함유 8 fl oz 펌프형 손소독제 (up&up™)',
    },
    'white board markers': {
      'name': 'Expo Low Odor Dry Erase Markers Set (4ct)',
      'price': 4.49,
      'targetUrl': 'https://www.target.com/p/-/A-10804811',
      'imageUrl': 'assets/items/item_whiteboard_markers.png',
      'description': 'Target 1위 검색 상품: 화이트보드 전용 4색 마커 세트',
    },
    'backpack': {
      'name': "Vera Bradley Women's Lighten Up Essential Sling Backpack",
      'price': 44.99,
      'targetUrl':
          'https://www.target.com/p/vera-bradley-women-s-outlet-lighten-up-essential-sling-backpack/-/A-1011088900?preselect=1004521409#lnk=sametab',
      'imageUrl': 'assets/items/item_backpack.png',
      'description': 'Target 1위 검색 상품: Baja Blue Tile 패턴의 슬링 백팩',
    },
    'wipes': {
      'name': 'Clorox Disinfecting Wipes Value Pack (75ct 3pk)',
      'price': 11.99,
      'targetUrl':
          'https://www.target.com/p/clorox-disinfecting-wipes-value-pack-bleach-free-cleaning-wipes-75ct-3pk/-/A-12992469#lnk=sametab',
      'imageUrl': 'assets/items/item_wipes.png',
      'description': 'Target 1위 검색 상품: 교실 살균 소독용 클로록스 3팩 물티슈',
    },
    'hand soap': {
      'name': "Mrs. Meyer's Clean Day Hand Soap Pear Tree (12.5 fl oz)",
      'price': 4.99,
      'targetUrl':
          'https://www.target.com/p/mrs-meyer-39-s-clean-day-hand-soap-pear-tree-12-5-fl-oz/-/A-89605090#lnk=sametab',
      'imageUrl': 'assets/items/item_hand_soap.png',
      'description': 'Target 1위 검색 상품: 미세스 메이어스 천연 에센셜 오일 핸드솝',
    },
    'composition notebook': {
      'name': 'Enday Wide Ruled Black Marble Composition Notebook (100 Sheets)',
      'price': 2.49,
      'targetUrl':
          'https://www.target.com/p/enday-wide-ruled-black-marble-composition-notebook-100-sheets/-/A-1012435914?preselect=1012435915#lnk=sametab',
      'imageUrl': 'assets/items/item_notebook.png',
      'description': 'Target 1위 검색 상품: Black marbled 커버 100매 공책',
    },
    'folder paper': {
      'name': '175ct Wide Ruled Loose Leaf Notebook Filler Paper - Dealworthy™',
      'price': 0.89,
      'targetUrl': 'https://www.target.com/p/-/A-91530223',
      'imageUrl': 'assets/items/item_folder_paper.png',
      'description': 'Target 1위 검색 상품: 바인더 및 폴더용 와이드 룰 속지 종이',
    },
    'folders': {
      'name': '2 Pocket Plastic Folder Blue - up&up™',
      'price': 0.50,
      'targetUrl': 'https://www.target.com/p/-/A-17079612',
      'imageUrl': 'assets/items/item_folders.png',
      'description': 'Target 1위 검색 상품: 2포켓 내구성 플라스틱 폴더',
    },
    'glue stick': {
      'name': "Elmer's 6pk Washable School Glue Sticks - Disappearing Purple",
      'price': 2.99,
      'targetUrl': 'https://www.target.com/p/-/A-17088992',
      'imageUrl': 'assets/items/item_glue.png',
      'description': 'Target 상품: 퍼플 워셔블 풀 스틱 6개입 번들',
    },
    'pencil with eraser': {
      'name': 'Ticonderoga 18ct Pencil Presharp Yellow',
      'price': 3.69,
      'targetUrl': 'https://www.target.com/p/-/A-13300243',
      'imageUrl': 'assets/items/item_pencils.png',
      'description': 'Target 상품: 미리 깎인 고품질 #2 연필 18자루',
    },
    'eraser': {
      'name': 'Paper Mate Pink Pearl Erasers (3-Count)',
      'price': 1.49,
      'targetUrl':
          'https://www.target.com/p/paper-mate-3pk-pencil-erasers-pink-pearl/-/A-14790219',
      'imageUrl': 'assets/items/item_erasers.png',
      'description': 'Target 1위 검색 상품: 직사각형 핑크 지우개',
    },
    'sharpie': {
      'name': 'Sharpie Fine & Ultra Fine Point Permanent Markers Black (2ct)',
      'price': 2.69,
      'targetUrl': 'https://www.target.com/p/-/A-78634124',
      'imageUrl': 'assets/items/item_sharpie.png',
      'description': 'Target 1위 검색 상품: 검정 샤피 (Regular + Skinny)',
    },
    'construction paper': {
      'name': 'Crayola 240-Sheet Construction Paper 12-Color',
      'price': 5.89,
      'targetUrl': 'https://www.target.com/p/-/A-16693485',
      'imageUrl': 'assets/items/item_construction_paper.png',
      'description': 'Target 1위 검색 상품: 미술용 칼라 도화지 묶음',
    },
    'tissue box': {
      'name': 'Kleenex Trusted Care Facial Tissue - 4pk/70ct',
      'price': 6.99,
      'targetUrl': 'https://www.target.com/p/-/A-12964745',
      'imageUrl': 'assets/items/item_tissue.png',
      'description': 'Target 1위 검색 상품: 부드러운 곽티슈 티슈 박스',
    },
    'supplies container': {
      'name': 'Sterilite School Supply Pencil Box - Blue',
      'price': 4.99,
      'targetUrl': 'https://www.target.com/p/-/A-17089076',
      'imageUrl': 'assets/items/item_caddy.png',
      'description': 'Target 1위 검색 상품: 플라스틱 학용품 수납통/캐디',
    },
    'pencil box': {
      'name': 'Sterilite Flat Top Pencil Box Clear',
      'price': 0.99,
      'targetUrl': 'https://www.target.com/p/-/A-94271662',
      'imageUrl': 'assets/items/item_pencil_box.png',
      'description': 'Target 1위 검색 상품: 책상 정리용 투명 플라스틱 필통',
    },
    'scissors': {
      'name': 'Fiskars Kid\'s Blunt Tip Scissors 5" Blue',
      'price': 1.59,
      'targetUrl': 'https://www.target.com/p/-/A-53623682',
      'imageUrl': 'assets/items/item_scissors.png',
      'description': 'Target 1위 검색 상품: 어린이 안전 가위',
    },
    'colored pencils': {
      'name': 'Crayola 24ct Pre-Sharpened Colored Pencils',
      'price': 3.29,
      'targetUrl': 'https://www.target.com/p/-/A-14152250',
      'imageUrl': 'assets/items/item_colored_pencils.png',
      'description': 'Target 1위 검색 상품: 24색 크레욜라 색연필 세트',
    },
    'crayons': {
      'name': 'Crayola 24ct Classic Crayons',
      'price': 0.50,
      'targetUrl': 'https://www.target.com/p/-/A-14151826',
      'imageUrl': 'assets/items/item_crayons.png',
      'description': 'Target 상품: 크레욜라 24색 크레용',
    },
    'markers': {
      'name': 'Crayola 20ct Super Tips Washable Markers',
      'price': 4.99,
      'targetUrl': 'https://www.target.com/p/-/A-49085479',
      'imageUrl': 'assets/items/item_super_tips.png',
      'description': 'Target 1위 검색 상품: 20색 물에 잘 지워지는 워셔블 마커',
    },
    'pencil sharpener': {
      'name': 'Pencil Sharpener 2 Hole - up&up™',
      'price': 0.49,
      'targetUrl':
          'https://www.target.com/p/pencil-sharpener-2-hole-1ct-colors-may-vary-up-38-up-8482/-/A-16637246',
      'imageUrl': 'assets/items/item_sharpener.png',
      'description': 'Target 1위 검색 상품: 휴대용 수동 연필깎이 2개입',
    },
    'watercolor paints': {
      'name': 'Crayola 8ct Washable Watercolor Paint Set with Paint Brush',
      'price': 2.39,
      'targetUrl': 'https://www.target.com/p/-/A-14151836',
      'imageUrl': 'assets/items/item_watercolor.png',
      'description': 'Target 1위 검색 상품: 붓이 포함된 워셔블 수채화 물감 세트',
    },
    'flash cards (addition)': {
      'name': 'School Zone Addition & Subtraction 0-12 Math Flash Cards',
      'price': 3.29,
      'targetUrl': 'https://www.target.com/p/-/A-88833408',
      'imageUrl': 'assets/items/item_flashcards_add.png',
      'description': 'Target 1위 검색 상품: 덧셈 연산 학습용 플래시 카드',
    },
    'flash cards (subtraction)': {
      'name': 'School Zone Addition & Subtraction 0-12 Math Flash Cards',
      'price': 3.29,
      'targetUrl': 'https://www.target.com/p/-/A-88833408',
      'imageUrl': 'assets/items/item_flashcards_sub.png',
      'description': 'Target 1위 검색 상품: 뺄셈 연산 학습용 플래시 카드',
    },
    'headphones': {
      'name': 'JLab Wired 3.5mm On-Ear Headphones',
      'price': 13.99,
      'targetUrl': 'https://www.target.com/p/-/A-78775154',
      'imageUrl': 'assets/items/item_headphones.png',
      'description': 'Target 1위 검색 상품: 어린이용 온이어 유선 헤드폰',
    },
  };

  /// Stored review samples. Prices, availability and ranking are not live.
  static const Map<String, List<TargetProductCandidate>> _knownCandidatePool = {
    'backpack': [
      TargetProductCandidate(
        id: 'pool_bp_1',
        name: "Vera Bradley Lighten Up Essential Sling Backpack",
        price: 44.99,
        imageUrl:
            'https://target.scene7.com/is/image/Target/GUEST_d3c70780-f86a-436b-91ad-8a6da038167a?wid=800&hei=800&qlt=85&fmt=pjpeg',
        targetUrl:
            'https://www.target.com/p/vera-bradley-women-s-outlet-lighten-up-essential-sling-backpack/-/A-1011088900?preselect=1004521409#lnk=sametab',
        description: 'Baja Blue Tile 패턴의 슬링 백팩 (Target 1위)',
      ),
      TargetProductCandidate(
        id: 'pool_bp_2',
        name: "J World New York Sundance Rolling Backpack (19.5\")",
        price: 49.99,
        imageUrl:
            'https://target.scene7.com/is/image/Target/GUEST_8947e4eb-e87f-4ca2-8db4-f06b642ec313?wid=800&hei=800&qlt=85&fmt=pjpeg',
        targetUrl:
            'https://www.target.com/p/j-world-new-york-sundance-rolling-backpack/-/A-54432128',
        description: '바퀴가 달린 대용량 롤링 책가방 백팩',
      ),
      TargetProductCandidate(
        id: 'pool_bp_3',
        name: "High Sierra Loop Daypack Backpack",
        price: 39.99,
        imageUrl:
            'https://target.scene7.com/is/image/Target/GUEST_d3c70780-f86a-436b-91ad-8a6da038167a?wid=800&hei=800&qlt=85&fmt=pjpeg',
        targetUrl:
            'https://www.target.com/p/high-sierra-loop-backpack/-/A-82475691',
        description: '다용도 멀티 포켓 방수 데이팩 백팩',
      ),
    ],
    'white board markers': [
      TargetProductCandidate(
        id: 'pool_wbm_1',
        name: 'Expo Low Odor Dry Erase Markers Chisel Tip (4-Count)',
        price: 4.49,
        imageUrl: 'assets/items/item_whiteboard_markers.png',
        targetUrl: 'https://www.target.com/p/-/A-10804811',
        description: '화이트보드 전용 저자극 4색 굵은 팁 마커 세트',
      ),
      TargetProductCandidate(
        id: 'pool_wbm_2',
        name: 'Expo Fine Tip Dry Erase Markers Assorted Colors (8-Count)',
        price: 8.99,
        imageUrl:
            'https://target.scene7.com/is/image/Target/GUEST_646a496b-b44d-49f5-be13-04cc140e6c03?wid=800&hei=800&qlt=85&fmt=pjpeg',
        targetUrl:
            'https://www.target.com/p/expo-8ct-fine-tip-dry-erase-markers-multicolor/-/A-14065604',
        description: '세밀한 판서용 파인 팁 8색 화이트보드 마커 세트',
      ),
    ],
    'hand sanitizer': [
      TargetProductCandidate(
        id: 'pool_san_1',
        name: 'Aloe Hand Sanitizer Gel - 8 fl oz - up&up™',
        price: 1.69,
        imageUrl: 'assets/items/item_hand_sanitizer.png',
        targetUrl: 'https://www.target.com/p/-/A-81412195',
        description: '알로에 함유 8 fl oz 펌프형 손소독제 (up&up™)',
      ),
      TargetProductCandidate(
        id: 'pool_san_2',
        name: 'Purell Advanced Hand Sanitizer Refreshing Gel (2 fl oz, 4pk)',
        price: 4.99,
        imageUrl:
            'https://target.scene7.com/is/image/Target/GUEST_2622ce89-a1fd-43dc-8b39-6bc8158e71ef?wid=800&hei=800&qlt=85&fmt=pjpeg',
        targetUrl:
            'https://www.target.com/p/purell-advanced-hand-sanitizer-refreshing-gel-2-fl-oz-4pk/-/A-14711674',
        description: '휴대용 퓨렐 손소독제 4개입 번들 패키지',
      ),
    ],
    'wipes': [
      TargetProductCandidate(
        id: 'pool_wipes_1',
        name: 'Clorox Disinfecting Wipes Value Pack (75ct 3pk)',
        price: 11.99,
        imageUrl:
            'https://target.scene7.com/is/image/Target/GUEST_d391710d-36c8-4175-bec4-520b54eec7f9?wid=800&hei=800&qlt=85&fmt=pjpeg',
        targetUrl:
            'https://www.target.com/p/clorox-disinfecting-wipes-value-pack-bleach-free-cleaning-wipes-75ct-3pk/-/A-12992469#lnk=sametab',
        description: '클로록스 살균 소독 물티슈 3팩 밸류팩',
      ),
      TargetProductCandidate(
        id: 'pool_wipes_2',
        name: 'Lysol Disinfecting Wipes Lemon & Lime Blossom (80ct)',
        price: 4.69,
        imageUrl:
            'https://target.scene7.com/is/image/Target/GUEST_2622ce89-a1fd-43dc-8b39-6bc8158e71ef?wid=800&hei=800&qlt=85&fmt=pjpeg',
        targetUrl:
            'https://www.target.com/p/lysol-disinfecting-wipes-lemon-lime-blossom-80ct/-/A-14711675',
        description: '교실 살균 소독용 레몬향 물티슈',
      ),
    ],
  };

  /// ═════════════════════════════════════════════════════════════════════════
  /// 2단계 분리 스크래핑 파이프라인 (Two-Step Pipeline with Crawlee Engine)
  /// ═════════════════════════════════════════════════════════════════════════

  /// [1단계] Target 검색 ➔ 실제 아이템 구매 화면(PDP) URL 및 메타데이터 확보
  Future<TargetPdpResolutionResult?> resolveTargetProductPdpUrl(
      String query) async {
    final normalized =
        query.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
    if (normalized.isEmpty) return null;
    final key = 'search_$normalized';
    final cached = _cacheStore.get<_TargetSearchOutcome>(key);
    if (cached != null) return cached.unwrap();
    final pending = _pendingSearches[normalized];
    if (pending != null) return pending;
    final operation = _resolveAndCache(normalized, key);
    _pendingSearches[normalized] = operation;
    try {
      return await operation;
    } finally {
      _pendingSearches.remove(normalized);
    }
  }

  Future<TargetPdpResolutionResult?> _resolveAndCache(
      String query, String key) async {
    try {
      final result = await _searchHandler.searchPdpUrl(
        query: query,
        client: _client,
        sessionPool: _sessionPool,
      );

      if (result != null) {
        final purchaseUrl = TargetPurchaseUrl.tryParse(result.pdpUrl);
        if (purchaseUrl == null) {
          return null;
        }
        final res = TargetPdpResolutionResult(
          name: result.name,
          pdpUrl: purchaseUrl.toString(),
          price: result.price,
          primaryGuestId: result.primaryGuestId,
          primaryImageUrl: result.primaryImageUrl,
          description: result.description,
        );
        _cacheStore.set(key, _TargetSearchOutcome(result: res));
        return res;
      }

      _cacheStore.set(
          key, const _TargetSearchOutcome(), const Duration(seconds: 30));
      return null;
    } on TargetLookupException catch (error) {
      _cacheStore.set(
          key, _TargetSearchOutcome(error: error), const Duration(seconds: 30));
      rethrow;
    }
  }

  /// [2단계] 실제 구매 화면(PDP) 진입 ➔ 1:1 최고해상도(1200w) 메인 이미지 최종 채택
  Future<String?> adoptMainImageFromPdp(String pdpUrl,
      {String? fallbackImageUrl}) async {
    final cached = _cacheStore.get<String>('pdp_img_$pdpUrl');
    if (cached != null) return cached;

    final adopted = await _pdpHandler.adoptMainImage(
      pdpUrl: pdpUrl,
      client: _client,
      sessionPool: _sessionPool,
      fallbackImageUrl: fallbackImageUrl,
    );

    if (adopted != null) {
      _cacheStore.set('pdp_img_$pdpUrl', adopted);
      return adopted;
    }

    return fallbackImageUrl;
  }

  /// Crawlee ConcurrentExecutor 기반 초고속 2단계 병렬 스크래핑 (동시성 3~4)
  @override
  Future<List<TargetProductData>> fetchTargetProducts(
    List<ExtractedItemEntry> entries, {
    void Function(int completed, int total, ExtractedItemEntry currentItem)?
        onProgress,
  }) async {
    return _concurrentExecutor.execute<ExtractedItemEntry, TargetProductData>(
      items: entries,
      task: (entry, index) => _fetchProductTwoStep(entry, index + 1),
      onProgress: onProgress,
    );
  }

  /// 단일 품목 2단계 실행: [1단계: 검색➔PDP URL] ➔ [2단계: PDP 진입➔1200w 이미지 채택]
  Future<TargetProductData> _fetchProductTwoStep(
      ExtractedItemEntry entry, int index) async {
    final query = entry.cleanName.toLowerCase().trim();

    // The local catalog provides deterministic metadata and a transparent
    // cutout fallback. Production composition may opt into a live PDP lookup
    // first so search pages are never presented as purchase links.
    final info = _matchCatalog(query);
    TargetPdpResolutionResult? step1Result;
    TargetLookupException? lookupFailure;
    if (preferLiveCatalog || info == null) {
      try {
        step1Result = await resolveTargetProductPdpUrl(entry.cleanName);
      } on TargetLookupException catch (error) {
        lookupFailure = error;
      }
    }

    if (step1Result != null) {
      final fallbackImg = step1Result.primaryImageUrl ??
          (step1Result.primaryGuestId != null
              ? ImageAdoptionHandler.buildHighResUrl(
                  'https://target.scene7.com/is/image/Target/GUEST_${step1Result.primaryGuestId}')
              : null);

      String? adoptedImage;
      try {
        adoptedImage =
            preferObservedProducts && step1Result.primaryImageUrl != null
                ? step1Result.primaryImageUrl
                : await adoptMainImageFromPdp(step1Result.pdpUrl,
                    fallbackImageUrl: fallbackImg);
      } on TargetLookupException catch (error) {
        lookupFailure = error;
      }

      // Metadata and imagery are adopted as one unit. If a live result cannot
      // provide its own image, use the complete verified local product rather
      // than mixing the live name/price/URL with an unrelated old image.
      if (adoptedImage == null && info != null) {
        final purchaseUrl = TargetPurchaseUrl.tryParse(
          info['targetUrl'] as String,
        );
        return TargetProductData(
          id: 'item_$index',
          name: info['name'] as String,
          category: entry.isPersonal ? '개인 물품 (*이름 표기)' : '공용 물품',
          isPersonal: entry.isPersonal,
          quantity: entry.quantity,
          price: (info['price'] as num).toDouble(),
          priceCurrency: 'USD',
          description: '${info['description']} (저장된 카탈로그 정보; 실시간 확인 안됨)',
          targetUrl: purchaseUrl?.toString() ?? '',
          imageUrl: info['imageUrl'] as String,
        );
      }

      return TargetProductData(
        id: 'item_$index',
        name: step1Result.name,
        category: entry.isPersonal ? '개인 물품 (*이름 표기)' : '공용 물품',
        isPersonal: entry.isPersonal,
        quantity: entry.quantity,
        price: step1Result.price,
        priceCurrency: 'USD',
        description: lookupFailure?.message ??
            step1Result.description ??
            'Target 상품 조회 결과',
        targetUrl: step1Result.pdpUrl,
        imageUrl: adoptedImage ?? '',
      );
    }

    if (info != null) {
      final purchaseUrl = TargetPurchaseUrl.tryParse(
        info['targetUrl'] as String,
      );
      return TargetProductData(
        id: 'item_$index',
        name: info['name'] as String,
        category: entry.isPersonal ? '개인 물품 (*이름 표기)' : '공용 물품',
        isPersonal: entry.isPersonal,
        quantity: entry.quantity,
        price: (info['price'] as num).toDouble(),
        priceCurrency: 'USD',
        description: '${info['description']} (저장된 카탈로그 정보; 실시간 확인 안됨)',
        targetUrl: purchaseUrl?.toString() ?? '',
        imageUrl: info['imageUrl'] as String,
      );
    }

    // Honest unresolved fallback: retain the extracted checklist entry without
    // inventing a product, price, purchase URL, or unrelated product image.
    return TargetProductData(
      id: 'item_$index',
      name: entry.cleanName,
      category: entry.isPersonal ? '개인 물품 (*이름 표기)' : '공용 물품',
      isPersonal: entry.isPersonal,
      quantity: entry.quantity,
      price: 0.0,
      priceCurrency: 'USD',
      description: lookupFailure?.message ?? '일치하는 Target 상품 정보를 확인하지 못했습니다.',
      targetUrl: '',
      imageUrl: '',
    );
  }

  /// 사용자 지정 URL로부터 상품 추출
  @override
  Future<TargetProductCandidate?> fetchProductByTargetUrl(String url) async {
    final cleanUrl = url.trim();
    if (cleanUrl.isEmpty) return null;

    // Case 1: Direct Scene7 image URL pasted
    if (cleanUrl.contains('target.scene7.com')) {
      final base = ImageAdoptionHandler.extractGuestImageBase(cleanUrl);
      if (base != null) {
        return TargetProductCandidate(
          id: 'user_url_${DateTime.now().millisecondsSinceEpoch}',
          name: '사용자 지정 Target 이미지',
          price: 0,
          imageUrl: ImageAdoptionHandler.buildHighResUrl(base),
          targetUrl: '',
          description: '사용자가 직접 입력한 Target 상품 이미지',
        );
      }
    }

    // Case 2: Target PDP URL
    final purchaseUrl = TargetPurchaseUrl.tryParse(cleanUrl);
    if (purchaseUrl == null) {
      return null;
    }
    try {
      final response = await _sessionPool.requests
          .get(_client, purchaseUrl.uri, timeout: const Duration(seconds: 8));

      if (response.statusCode == 200) {
        final imgUrl =
            ImageAdoptionHandler.extractTargetMainImageElement(response.body);
        if (imgUrl != null) {
          final titleMatch =
              RegExp(r'<title>(.*?)</title>', caseSensitive: false)
                  .firstMatch(response.body);
          final rawTitle = titleMatch?.group(1) ?? 'Target 맞춤 상품';
          final cleanTitle =
              rawTitle.split(':').first.replaceAll(' - Target', '').trim();

          return TargetProductCandidate(
            id: 'user_pdp_${DateTime.now().millisecondsSinceEpoch}',
            name: cleanTitle,
            price: extractTargetPriceFromHtml(response.body) ?? 0,
            imageUrl: imgUrl,
            targetUrl: purchaseUrl.toString(),
            description: 'Target 웹페이지에서 직접 추출한 상품',
          );
        }
      }
    } on TargetLookupException {
      rethrow;
    } on Object {
      throw const TargetLookupException(TargetLookupFailure.invalidResponse);
    }

    return null;
  }

  /// Multi-tier candidate search with Crawlee SessionPool
  @override
  Future<List<TargetProductCandidate>> fetchLiveCandidates(
    CuratorItem item,
  ) async {
    final candidates = <TargetProductCandidate>[];
    final query = item.name.trim();
    TargetLookupException? failure;

    if (preferObservedProducts) {
      final response = await _sessionPool.requests.get(
          _client, Uri.https('www.target.com', '/s', {'searchTerm': query}));
      final observed = ObservedProductMetadata.fromHtml(response.body)
          .where((p) => SearchHandler.scoreSimilarity(query, p.name) > 0)
          .toList()
        ..sort((a, b) => SearchHandler.scoreSimilarity(query, b.name)
            .compareTo(SearchHandler.scoreSimilarity(query, a.name)));
      if (observed.isNotEmpty) {
        return [
          for (var i = 0; i < observed.length.clamp(0, 5); i++)
            TargetProductCandidate(
                id: 'observed_$i',
                name: observed[i].name,
                price: observed[i].price,
                imageUrl: observed[i].imageUrl,
                targetUrl: observed[i].targetUrl,
                description: '페이지에서 관찰한 상품 JSON · 실시간 재고는 구매 전 확인')
        ];
      }
    }

    // ── Tier 1: Target RedSky Web Search API ──────────────────────────────────
    if (_redSkyApiKey?.trim().isNotEmpty == true) {
      try {
        final redskyUrl = Uri.parse(
          'https://redsky.target.com/redsky_aggregations/v1/web/plp_search_v2'
          '?key=${Uri.encodeQueryComponent(_redSkyApiKey!)}'
          '&channel=WEB'
          '&count=5'
          '&keyword=${Uri.encodeComponent(query)}',
        );

        final resp = await _sessionPool.requests.get(_client, redskyUrl);

        if (resp.statusCode == 200) {
          final json = jsonDecode(resp.body) as Map<String, dynamic>;
          final products =
              json['data']?['search']?['products'] as List<dynamic>? ?? [];

          for (final p in products) {
            final itemData = p['item'] as Map<String, dynamic>?;
            final priceData = p['price'] as Map<String, dynamic>?;
            final title = itemData?['product_description']?['title'] as String?;
            final guestId = itemData?['enrichment']?['images']
                ?['primary_image_id'] as String?;
            final currentPrice =
                (priceData?['current_retail'] as num?)?.toDouble() ?? 0.0;
            final urlSuffix = itemData?['buy_url'] as String? ?? '';
            final rawTargetUrl = urlSuffix.startsWith('http')
                ? urlSuffix
                : 'https://www.target.com$urlSuffix';
            final purchaseUrl = TargetPurchaseUrl.tryParse(rawTargetUrl);

            if (title != null && guestId != null && purchaseUrl != null) {
              candidates.add(TargetProductCandidate(
                id: 'redsky_${candidates.length}',
                name: title,
                price: currentPrice,
                imageUrl: ImageAdoptionHandler.buildHighResUrl(
                    'https://target.scene7.com/is/image/Target/GUEST_$guestId'),
                targetUrl: purchaseUrl.toString(),
                description: 'Target 실시간 검색 결과 (RedSky API, Crawlee Engine)',
              ));
            }
          }
        }
      } on TargetLookupException catch (error) {
        failure = error;
      } on Object {
        failure =
            const TargetLookupException(TargetLookupFailure.invalidResponse);
      }
    }

    if (candidates.isNotEmpty) return candidates;

    // Search-page HTML contains independent title/image fragments that cannot
    // be paired safely and often lacks a PDP URL. Only structured RedSky
    // products or the verified local pool are eligible review candidates.

    // ── Tier 2: Verified Multi-Candidate Pool Fallback ───────────────────────
    final lowerQuery = item.name.toLowerCase();
    for (final key in _knownCandidatePool.keys) {
      if (lowerQuery.contains(key) || key.contains(lowerQuery)) {
        return _knownCandidatePool[key]!
            .map((candidate) => TargetProductCandidate(
                  id: candidate.id,
                  name: candidate.name,
                  price: candidate.price,
                  imageUrl: candidate.imageUrl,
                  targetUrl: candidate.targetUrl,
                  description: '${candidate.description} '
                      '(저장된 카탈로그 정보; 실시간 확인 안됨)',
                ))
            .toList(growable: false);
      }
    }

    // No live or verified alternative exists. The BLoC will surface an empty
    // review state instead of fabricating a bestseller and adjusted price.
    if (failure != null) throw failure;
    return const [];
  }

  /// 3단계 우선순위 매칭:
  /// 1) Exact match (query == key)
  /// 2) Query contains key
  /// 3) Key contains query
  Map<String, dynamic>? _matchCatalog(String query) {
    if (query.trim().isEmpty) return null;

    if (_knownTargetItems.containsKey(query)) {
      return _knownTargetItems[query];
    }

    String? bestKeyPass2;
    for (final key in _knownTargetItems.keys) {
      if (query.contains(key)) {
        if (bestKeyPass2 == null || key.length > bestKeyPass2.length) {
          bestKeyPass2 = key;
        }
      }
    }
    if (bestKeyPass2 != null) return _knownTargetItems[bestKeyPass2];

    String? bestKeyPass3;
    for (final key in _knownTargetItems.keys) {
      if (key.contains(query)) {
        if (bestKeyPass3 == null || key.length < bestKeyPass3.length) {
          bestKeyPass3 = key;
        }
      }
    }
    if (bestKeyPass3 != null) return _knownTargetItems[bestKeyPass3];

    return null;
  }

  /// Releases the internally-created HTTP client. Injected clients remain
  /// owned by the application composition root.
  void close() {
    if (_ownsHttpClient) {
      _client.close();
    }
  }
}

final class _TargetSearchOutcome {
  const _TargetSearchOutcome({this.result, this.error});
  final TargetPdpResolutionResult? result;
  final TargetLookupException? error;
  TargetPdpResolutionResult? unwrap() {
    if (error != null) throw error!;
    return result;
  }
}

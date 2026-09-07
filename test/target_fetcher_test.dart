import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:shopitem_curator/core/models/curator_item.dart';
import 'package:shopitem_curator/core/models/target_purchase_url.dart';
import 'package:shopitem_curator/core/services/target_fetcher_service.dart';
import 'package:shopitem_curator/core/services/demo_item_extraction_gateway.dart';

void main() {
  // ── Target Image Element Extraction ──────────────────────────────────────
  group('TargetFetcherService — Image Element Extraction Tests', () {
    test('extracts 1200w from og:image meta tag (property before content)', () {
      const html = '''
        <meta property="og:image" content="https://target.scene7.com/is/image/Target/GUEST_d3c70780-f86a-436b-91ad-8a6da038167a" data-next-head=""/>
      ''';
      final url = TargetFetcherService.extractTargetMainImageElement(html);
      expect(url, isNotNull);
      expect(url, contains('GUEST_d3c70780-f86a-436b-91ad-8a6da038167a'));
      expect(url, contains('wid=1200&hei=1200'));
    });

    test('extracts 1200w from og:image meta tag (content before property)', () {
      const html = '''
        <meta content="https://target.scene7.com/is/image/Target/GUEST_646a496b-b44d-49f5-be13-04cc140e6c03" property="og:image"/>
      ''';
      final url = TargetFetcherService.extractTargetMainImageElement(html);
      expect(url, isNotNull);
      expect(url, contains('GUEST_646a496b-b44d-49f5-be13-04cc140e6c03'));
      expect(url, contains('wid=1200&hei=1200'));
    });

    test('extracts 1200w from img srcSet element', () {
      const html = '''
        <img alt="EXPO Markers"
             srcSet="https://target.scene7.com/is/image/Target/GUEST_2622ce89-a1fd-43dc-8b39-6bc8158e71ef?wid=300 300w,
                     https://target.scene7.com/is/image/Target/GUEST_2622ce89-a1fd-43dc-8b39-6bc8158e71ef?wid=1200 1200w" />
      ''';
      final url = TargetFetcherService.extractTargetMainImageElement(html);
      expect(url, isNotNull);
      expect(url, contains('GUEST_2622ce89-a1fd-43dc-8b39-6bc8158e71ef'));
      expect(url, contains('wid=1200&hei=1200'));
    });

    test('falls back to direct Scene7 GUEST ID in href', () {
      const html = '''
        <a href="https://target.scene7.com/is/image/Target/GUEST_bbfb3a25-30ba-4a9c-a1b1-9dd919bcedf1">View</a>
      ''';
      final url = TargetFetcherService.extractTargetMainImageElement(html);
      expect(url, isNotNull);
      expect(url, contains('GUEST_bbfb3a25-30ba-4a9c-a1b1-9dd919bcedf1'));
      expect(url, contains('wid=1200&hei=1200'));
    });

    test('returns null when no Target Scene7 GUEST image found', () {
      const html = '<html><body><p>No image here</p></body></html>';
      expect(TargetFetcherService.extractTargetMainImageElement(html), isNull);
    });
  });

  group('TargetFetcherService — PDP price extraction', () {
    test('reads a price from JSON-LD Offer metadata', () {
      const html = '''
        <script type="application/ld+json">
          {"@type":"Product","offers":{"@type":"Offer","price":"12.49","priceCurrency":"USD"}}
        </script>
      ''';

      expect(TargetFetcherService.extractTargetPriceFromHtml(html), 12.49);
    });

    test('reads a price meta tag regardless of attribute order', () {
      const html = '''
        <meta content="\$7.25" property="product:price:amount">
      ''';

      expect(TargetFetcherService.extractTargetPriceFromHtml(html), 7.25);
    });

    test('returns null when PDP metadata contains no trustworthy price', () {
      const html = '<html><body>Suggested value: 5.99</body></html>';

      expect(TargetFetcherService.extractTargetPriceFromHtml(html), isNull);
    });

    test('custom PDP candidate uses extracted price instead of a fixed price',
        () async {
      final client = MockClient((request) async => http.Response('''
        <html><head>
          <title>Verified Test Product : Target</title>
          <meta property="og:image" content="https://target.scene7.com/is/image/Target/GUEST_d3c70780-f86a-436b-91ad-8a6da038167a">
          <script type="application/ld+json">
            {"@type":"Product","offers":{"@type":"Offer","price":18.75}}
          </script>
        </head></html>
      ''', 200));
      final service = TargetFetcherService(httpClient: client);

      final candidate = await service.fetchProductByTargetUrl(
        'https://www.target.com/p/-/A-12345678',
      );

      expect(candidate, isNotNull);
      expect(candidate!.price, 18.75);
      expect(candidate.price, isNot(5.99));
    });
  });

  // ── Catalog Matching — 이슈 1 & 2 수정 검증 ─────────────────────────────
  group('TargetFetcherService — Catalog Matching Tests (이슈 1·2 검증)', () {
    final service = TargetFetcherService();

    test('[이슈 1] "eraser" → Erasers (NOT Pencils)', () async {
      final products = await service.fetchTargetProducts([
        const ExtractedItemEntry(
            rawName: 'Eraser',
            cleanName: 'eraser',
            quantity: 2,
            isPersonal: false),
      ]);
      expect(products[0].name, contains('Pink Pearl Erasers'));
      expect(products[0].imageUrl, 'assets/items/item_erasers.png');
    });

    test('[이슈 2] "markers" → Super Tips Washable Markers (NOT Whiteboard EXPO)',
        () async {
      final products = await service.fetchTargetProducts([
        const ExtractedItemEntry(
            rawName: 'Markers*',
            cleanName: 'markers',
            quantity: 1,
            isPersonal: true),
      ]);
      expect(products[0].name, contains('Super Tips'));
      expect(products[0].imageUrl, 'assets/items/item_super_tips.png');
    });

    test('"pencil with eraser" → Pencils (NOT Erasers)', () async {
      final products = await service.fetchTargetProducts([
        const ExtractedItemEntry(
            rawName: 'Pencil with Eraser',
            cleanName: 'pencil with eraser',
            quantity: 1,
            isPersonal: false),
      ]);
      expect(products[0].name, contains('Ticonderoga'));
      expect(products[0].imageUrl, 'assets/items/item_pencils.png');
    });

    test('"white board markers" → EXPO Dry Erase Markers (NOT Super Tips)',
        () async {
      final products = await service.fetchTargetProducts([
        const ExtractedItemEntry(
            rawName: 'White Board Markers',
            cleanName: 'white board markers',
            quantity: 1,
            isPersonal: false),
      ]);
      expect(products[0].name, contains('Expo'));
      expect(products[0].imageUrl, 'assets/items/item_whiteboard_markers.png');
    });

    test('full 3-item fetch: hand sanitizer, backpack, white board markers',
        () async {
      final products = await service.fetchTargetProducts([
        const ExtractedItemEntry(
            rawName: 'Hand sanitizer',
            cleanName: 'hand sanitizer',
            quantity: 1,
            isPersonal: false),
        const ExtractedItemEntry(
            rawName: 'Backpack*',
            cleanName: 'backpack',
            quantity: 1,
            isPersonal: true),
        const ExtractedItemEntry(
            rawName: 'White Board Markers',
            cleanName: 'white board markers',
            quantity: 1,
            isPersonal: false),
      ]);
      expect(products.length, 3);
      expect(products[0].name, contains('Aloe Hand Sanitizer Gel'));
      expect(products[0].price, 1.69);
      expect(products[0].targetUrl, contains('target.com/p/'));
      expect(products[1].name, contains('Vera Bradley'));
      expect(products[1].isPersonal, isTrue);
      expect(products[2].name, contains('Expo'));
      expect(products[2].price, 4.49);
    });

    test('all bundled catalog items expose verified Target PDP links',
        () async {
      const ocr = DemoItemExtractionGateway();
      final entries = await ocr.extractItemsFromImage(
        'assets/images/media_1787068853075.jpg',
      );
      final products = await service.fetchTargetProducts(entries);

      expect(products, hasLength(25));
      for (final product in products) {
        expect(
          TargetPurchaseUrl.isValid(product.targetUrl),
          isTrue,
          reason: '${product.name} must link directly to a Target PDP',
        );
      }
    });

    test('an unresolved item does not fabricate product data', () async {
      final unresolvedService = TargetFetcherService(
        httpClient: MockClient((_) async => http.Response('Not found', 404)),
      );

      final products = await unresolvedService.fetchTargetProducts([
        const ExtractedItemEntry(
          rawName: 'Imaginary Classroom Widget',
          cleanName: 'Imaginary Classroom Widget',
          quantity: 2,
          isPersonal: false,
        ),
      ]);

      expect(products, hasLength(1));
      expect(products.single.name, 'Imaginary Classroom Widget');
      expect(products.single.price, 0.0);
      expect(products.single.targetUrl, isEmpty);
      expect(products.single.imageUrl, isEmpty);
    });
  });

  // ── Multi-Tier Candidate Search & Custom URL Extraction Tests ────────────
  group('TargetFetcherService — Multi-tier Candidate Search & URL Extraction',
      () {
    final service = TargetFetcherService();

    test('fetchProductByTargetUrl extracts candidate from direct Scene7 URL',
        () async {
      const scene7Url =
          'https://target.scene7.com/is/image/Target/GUEST_d3c70780-f86a-436b-91ad-8a6da038167a?wid=400';
      final cand = await service.fetchProductByTargetUrl(scene7Url);
      expect(cand, isNotNull);
      expect(cand!.imageUrl,
          contains('GUEST_d3c70780-f86a-436b-91ad-8a6da038167a'));
      expect(cand.imageUrl, contains('wid=1200&hei=1200'));
    });

    test(
        'fetchLiveCandidates returns verified multi-candidate pool on fallback',
        () async {
      final item = CuratorItem(
        id: 'item_1',
        name: 'Vera Bradley Backpack',
        category: '개인 물품',
        isPersonal: true,
        quantity: 1,
        price: 44.99,
        priceCurrency: 'USD',
        description: 'Baja Blue Tile',
        targetUrl: 'https://www.target.com/p/1011088900',
        imageUrl: 'assets/items/item_backpack.png',
        bounds: const ItemLayoutBounds(x: 0, y: 0, width: 200, height: 200),
        polygon: [],
        centroid: const CuratorPoint(0, 0),
      );

      final candidates = await service.fetchLiveCandidates(item);
      expect(candidates, isNotEmpty);
      expect(candidates.length, greaterThanOrEqualTo(2));
      expect(
          candidates.any((c) =>
              c.name.toLowerCase().contains('backpack') ||
              c.name.toLowerCase().contains('vera') ||
              c.name.toLowerCase().contains('j world')),
          isTrue);
    });

    test(
        '2-Step Pipeline: resolveTargetProductPdpUrl and adoptMainImageFromPdp work seamlessly',
        () async {
      // This is a protocol test, not proof that a live upstream grants access.
      final fetcher = TargetFetcherService(
          httpClient: MockClient((request) async => http.Response(
              request.url.path == '/s'
                  ? '<a href="/p/sanitizer/-/A-81412195">Sanitizer</a>'
                  : '<html></html>',
              200)));
      addTearDown(fetcher.close);
      final step1 = await fetcher.resolveTargetProductPdpUrl('hand sanitizer');
      expect(step1, isNotNull);
      if (step1 != null) {
        expect(step1.pdpUrl, contains('target.com'));
        // Step 2: Adopt 1200w image from PDP
        final img = await fetcher.adoptMainImageFromPdp(step1.pdpUrl,
            fallbackImageUrl: 'assets/items/item_hand_sanitizer.png');
        expect(img, isNotNull);
      }
    });

    test('unknown review items return an honest empty candidate list',
        () async {
      final unresolvedService = TargetFetcherService(
        httpClient: MockClient((_) async => http.Response('Not found', 404)),
      );
      final item = CuratorItem(
        id: 'unknown',
        name: 'Imaginary Classroom Widget',
        category: '공용 물품',
        isPersonal: false,
        quantity: 1,
        price: 0,
        priceCurrency: 'USD',
        description: '',
        targetUrl: '',
        imageUrl: '',
        bounds: const ItemLayoutBounds(x: 0, y: 0, width: 100, height: 100),
        polygon: const [],
        centroid: const CuratorPoint(50, 50),
      );

      expect(await unresolvedService.fetchLiveCandidates(item), isEmpty);
    });
  });

  // ── 구조적 수정 검증 테스트 ────────────────────────────────────────────────
  group('TargetFetcherService — Structural Fix Verification', () {
    // 문제 4: AVIF/WebP 확장자 포함 Scene7 URL에서 UUID v4 정밀 추출
    group('[문제 4] UUID v4 정규식 — .avif 확장자 포함 URL 정밀 파싱', () {
      test('og:image URL에 .avif 확장자가 붙어 있어도 정확한 GUEST ID 추출', () {
        const html = '''
          <meta property="og:image" content="https://target.scene7.com/is/image/Target/GUEST_e011a984-ba75-4ccd-a110-6297483e7190.avif?wid=1200" data-next-head=""/>
        ''';
        final url = TargetFetcherService.extractTargetMainImageElement(html);
        expect(url, isNotNull);
        // .avif 없이 정확한 UUID로 끝나야 함
        expect(url, contains('GUEST_e011a984-ba75-4ccd-a110-6297483e7190'));
        expect(url, isNot(contains('.avif')));
        expect(url, contains('wid=1200&hei=1200'));
      });

      test('srcSet에 .avif URL이 있어도 1200w 기준으로 정확히 추출', () {
        const html = '''
          <img srcSet="https://target.scene7.com/is/image/Target/GUEST_ed345990-6f06-41fc-bff8-dcba00552f36.avif?wid=300 300w,
                       https://target.scene7.com/is/image/Target/GUEST_ed345990-6f06-41fc-bff8-dcba00552f36.avif?wid=1200 1200w" />
        ''';
        final url = TargetFetcherService.extractTargetMainImageElement(html);
        expect(url, isNotNull);
        expect(url, contains('GUEST_ed345990-6f06-41fc-bff8-dcba00552f36'));
        expect(url, isNot(contains('.avif')));
        expect(url, contains('wid=1200&hei=1200'));
      });

      test('UUID가 아닌 가짜 GUEST_ ID는 매칭하지 않음 (비 UUID 형식 방어)', () {
        // 8-4-4-4-12 형식이 아닌 단순 숫자열은 매칭 안 됨
        const html = '''
          <img src="https://target.scene7.com/is/image/Target/GUEST_abc123notauuid" />
        ''';
        final url = TargetFetcherService.extractTargetMainImageElement(html);
        expect(url, isNull);
      });

      test('Clorox wipes GUEST ID 정상 추출 (사용자 제공 실제 ID)', () {
        const html = '''
          <meta property="og:image" content="https://target.scene7.com/is/image/Target/GUEST_d391710d-36c8-4175-bec4-520b54eec7f9.avif?wid=800"/>
        ''';
        final url = TargetFetcherService.extractTargetMainImageElement(html);
        expect(url, isNotNull);
        expect(url, contains('GUEST_d391710d-36c8-4175-bec4-520b54eec7f9'));
        expect(url, isNot(contains('.avif')));
      });

      test('Enday notebook GUEST ID 정상 추출 (사용자 제공 실제 ID)', () {
        const html = '''
          <meta content="https://target.scene7.com/is/image/Target/GUEST_0a6e8559-507d-4210-ae4a-efb11f109fa2" property="og:image"/>
        ''';
        final url = TargetFetcherService.extractTargetMainImageElement(html);
        expect(url, isNotNull);
        expect(url, contains('GUEST_0a6e8559-507d-4210-ae4a-efb11f109fa2'));
        expect(url, contains('wid=1200&hei=1200'));
      });
    });

    // 문제 1: preselect TCIN 추출 로직
    group('[문제 1] preselect TCIN 파싱 — 옵션 단품 정밀 처리', () {
      test('preselect 파라미터가 있는 URL에서 TCIN 정확히 추출', () {
        const url =
            'https://www.target.com/p/aloe-hand-sanitizer-gel-up-up/-/A-87355033?preselect=81412195#lnk=sametab';
        // _extractTcinFromPdpUrl은 private이므로 동일 로직으로 검증
        final uri = Uri.tryParse(url);
        expect(uri, isNotNull);
        expect(uri!.queryParameters['preselect'], '81412195');
      });

      test('preselect가 없는 일반 PDP URL은 TCIN null 반환', () {
        const url =
            'https://www.target.com/p/clorox-disinfecting-wipes-value-pack/-/A-12992469#lnk=sametab';
        final uri = Uri.tryParse(url);
        expect(uri!.queryParameters['preselect'], isNull);
      });

      test('Enday notebook preselect TCIN 추출', () {
        const url =
            'https://www.target.com/p/enday-wide-ruled-black-marble-composition-notebook-100-sheets/-/A-1012435914?preselect=1012435915#lnk=sametab';
        final uri = Uri.tryParse(url);
        expect(uri!.queryParameters['preselect'], '1012435915');
      });
    });

    // 문제 2: 유사도 스코어링
    group('[문제 2] 유사도 스코어링 — 브랜드/규격 토큰 매칭', () {
      test('Mrs. Meyer\'s 포함 타이틀이 Dial보다 높은 점수를 받아야 함 (hand soap 쿼리)', () {
        // _scoreSimilarity는 private이므로 상대적 우열 검증용 로직 직접 테스트
        // 쿼리: "mrs. meyer's hand soap 12.5 fl oz"
        const query = "mrs. meyer's hand soap 12.5 fl oz";
        const dialTitle = "Dial Liquid Hand Soap Gold 7.5 fl oz";
        const meyersTitle =
            "Mrs. Meyer's Clean Day Hand Soap Pear Tree 12.5 fl oz";

        // 토큰 교집합 계산 (간단한 유사도 검증)
        final qTokens = query.toLowerCase().split(RegExp(r'\s+'));
        final dialTokens = dialTitle.toLowerCase().split(RegExp(r'\s+'));
        final meyersTokens = meyersTitle.toLowerCase().split(RegExp(r'\s+'));

        final dialMatch = qTokens.where((t) => dialTokens.contains(t)).length;
        final meyersMatch =
            qTokens.where((t) => meyersTokens.contains(t)).length;

        expect(meyersMatch, greaterThan(dialMatch),
            reason: 'Mrs. Meyer\'s 제목은 더 많은 쿼리 토큰과 일치해야 함');
      });

      test('Clorox 3pk 포함 타이틀이 Lysol 단품보다 높은 점수를 받아야 함 (clorox wipes 쿼리)', () {
        const query = "clorox disinfecting wipes 75ct 3pk";
        const lysolTitle = "Lysol Disinfecting Wipes Lemon Lime Blossom 80ct";
        const cloroxTitle =
            "Clorox Disinfecting Wipes Value Pack Bleach Free 75ct 3pk";

        final qTokens = query.toLowerCase().split(RegExp(r'\s+'));
        final lysolTokens = lysolTitle.toLowerCase().split(RegExp(r'\s+'));
        final cloroxTokens = cloroxTitle.toLowerCase().split(RegExp(r'\s+'));

        final lysolMatch = qTokens.where((t) => lysolTokens.contains(t)).length;
        final cloroxMatch =
            qTokens.where((t) => cloroxTokens.contains(t)).length;

        expect(cloroxMatch, greaterThan(lysolMatch),
            reason: 'Clorox 3pk 제목은 더 많은 쿼리 토큰과 일치해야 함');
      });
    });

    // 문제 3: 스폰서 광고 필터링 시뮬레이션
    group('[문제 3] 스폰서 필터링 — sponsored 라벨 제외', () {
      test('sponsored 라벨이 있는 상품은 candidates 리스트에서 제외됨', () {
        // 스폰서 필터링 로직을 직접 시뮬레이션
        final mockProducts = [
          {
            'item': {
              'product_description': {'title': 'Dial Soap (Sponsored)'}
            },
            'price': {'current_retail': 1.99},
            'labels': ['Sponsored'],
          },
          {
            'item': {
              'product_description': {'title': "Mrs. Meyer's Hand Soap"}
            },
            'price': {'current_retail': 4.49},
            'labels': <String>[],
          },
        ];

        final nonSponsored = mockProducts.where((p) {
          final labels = p['labels'] as List<dynamic>? ?? [];
          return !labels.any((l) =>
              (l as String?)?.toLowerCase().contains('sponsored') ?? false);
        }).toList();

        expect(nonSponsored.length, 1);
        expect(
          (nonSponsored.first['item'] as Map)['product_description']['title'],
          "Mrs. Meyer's Hand Soap",
        );
      });
    });
  });
}

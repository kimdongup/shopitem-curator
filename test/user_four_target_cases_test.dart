// Pure Dart Tests (Zero Flutter Dependencies)

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shopitem_curator/core/services/scraper/router/image_adoption_handler.dart';
import 'package:shopitem_curator/core/services/scraper/router/pdp_handler.dart';
import 'package:shopitem_curator/core/services/scraper/router/search_handler.dart';
import 'package:shopitem_curator/core/services/target_fetcher_service.dart';
import 'package:test/test.dart';

void main() {
  group('Target 4대 실사례 대응 전용 검증 테스트셋 (Dedicated Test Suite)', () {
    // ═════════════════════════════════════════════════════════════════════════
    // Case 1: Aloe Hand Sanitizer direct variant PDP
    // ═════════════════════════════════════════════════════════════════════════
    group('[Case 1] Aloe Hand Sanitizer Gel (A-81412195)', () {
      const targetUrl = 'https://www.target.com/p/-/A-81412195';
      const expectedGuestId = 'GUEST_e011a984-ba75-4ccd-a110-6297483e7190';

      test('1. 직접 PDP URL에서 TCIN(81412195)을 정확히 파싱한다', () {
        final tcin = PdpHandler.extractTcinFromPdpUrl(targetUrl);
        expect(tcin, equals('81412195'));
      });

      test('2. HTML에 .avif 포맷으로 포함된 GUEST ID를 UUID v4 기준으로 정확히 채택한다', () {
        const sampleHtml = '''
          <meta property="og:image" content="https://target.scene7.com/is/image/Target/$expectedGuestId.avif?wid=1200" />
        ''';
        final adoptedUrl =
            ImageAdoptionHandler.extractTargetMainImageElement(sampleHtml);
        expect(adoptedUrl, isNotNull);
        expect(adoptedUrl, contains(expectedGuestId));
        expect(adoptedUrl, isNot(contains('.avif')));
        expect(adoptedUrl, contains('wid=1200&hei=1200&qlt=85&fmt=pjpeg'));
      });

      test('3. Mock PDPv4 API를 통해 preselect TCIN 기반으로 정확한 이미지 URL을 반환한다',
          () async {
        final mockClient = MockClient((request) async {
          if (request.url.queryParameters['tcin'] == '81412195') {
            return http.Response(
              '''
              {
                "data": {
                  "product": {
                    "item": {
                      "enrichment": {
                        "images": {
                          "primary_image_id": "e011a984-ba75-4ccd-a110-6297483e7190"
                        }
                      }
                    }
                  }
                }
              }
              ''',
              200,
              headers: {'content-type': 'application/json'},
            );
          }
          return http.Response('Not Found', 404);
        });

        final service = TargetFetcherService(
            httpClient: mockClient, redSkyApiKey: 'test-authorized-key');
        final adoptedUrl = await service.adoptMainImageFromPdp(targetUrl);

        expect(adoptedUrl, isNotNull);
        expect(adoptedUrl, contains(expectedGuestId));
        expect(adoptedUrl, contains('wid=1200&hei=1200'));
      });

      test('4. 카탈로그 조회 시 해당 공식 구매 URL과 매핑된다', () async {
        final service = TargetFetcherService();
        final products = await service.fetchTargetProducts([
          const ExtractedItemEntry(
            rawName: 'Hand Sanitizer',
            cleanName: 'hand sanitizer',
            quantity: 1,
            isPersonal: false,
          ),
        ]);

        expect(products.length, equals(1));
        expect(products.first.targetUrl, equals(targetUrl));
        expect(products.first.name, contains('Aloe Hand Sanitizer Gel'));
      });
    });

    // ═════════════════════════════════════════════════════════════════════════
    // Case 2: Mrs. Meyer's Hand Soap (A-89605090 ➔ GUEST_ed345990...)
    // ═════════════════════════════════════════════════════════════════════════
    group('[Case 2] Mrs. Meyer\'s Clean Day Hand Soap (A-89605090)', () {
      const targetUrl =
          'https://www.target.com/p/mrs-meyer-39-s-clean-day-hand-soap-pear-tree-12-5-fl-oz/-/A-89605090#lnk=sametab';
      const expectedGuestId = 'GUEST_ed345990-6f06-41fc-bff8-dcba00552f36';

      test('1. og:image 및 srcSet의 .avif 이미지로부터 1200w 메인 이미지를 채택한다', () {
        const sampleHtml = '''
          <img srcSet="https://target.scene7.com/is/image/Target/$expectedGuestId.avif?wid=300 300w,
                       https://target.scene7.com/is/image/Target/$expectedGuestId.avif?wid=1200 1200w" />
        ''';
        final adoptedUrl =
            ImageAdoptionHandler.extractTargetMainImageElement(sampleHtml);
        expect(adoptedUrl, isNotNull);
        expect(adoptedUrl, contains(expectedGuestId));
        expect(adoptedUrl, contains('wid=1200&hei=1200'));
      });

      test('2. 검색어 유사도 스코어링에서 Mrs. Meyer\'s가 일반 Dial보다 높은 점수를 획득한다', () {
        const query = 'mrs meyers clean day hand soap 12.5 fl oz';
        const meyersTitle =
            "Mrs. Meyer's Clean Day Hand Soap Pear Tree 12.5 fl oz";
        const dialTitle = 'Dial Liquid Hand Soap Gold 7.5 fl oz';

        final meyersScore = SearchHandler.scoreSimilarity(query, meyersTitle);
        final dialScore = SearchHandler.scoreSimilarity(query, dialTitle);

        expect(meyersScore, greaterThan(dialScore));
      });

      test('3. 카탈로그 조회 시 Mrs. Meyer\'s 공식 PDP 구매 URL과 매핑된다', () async {
        final service = TargetFetcherService();
        final products = await service.fetchTargetProducts([
          const ExtractedItemEntry(
            rawName: 'Hand Soap',
            cleanName: 'hand soap',
            quantity: 1,
            isPersonal: false,
          ),
        ]);

        expect(products.length, equals(1));
        expect(products.first.targetUrl, equals(targetUrl));
        expect(
            products.first.name, contains("Mrs. Meyer's Clean Day Hand Soap"));
      });
    });

    // ═════════════════════════════════════════════════════════════════════════
    // Case 3: Clorox Disinfecting Wipes 3pk (A-12992469 ➔ GUEST_d391710d...)
    // ═════════════════════════════════════════════════════════════════════════
    group('[Case 3] Clorox Disinfecting Wipes Value Pack 3pk (A-12992469)', () {
      const targetUrl =
          'https://www.target.com/p/clorox-disinfecting-wipes-value-pack-bleach-free-cleaning-wipes-75ct-3pk/-/A-12992469#lnk=sametab';
      const expectedGuestId = 'GUEST_d391710d-36c8-4175-bec4-520b54eec7f9';

      test('1. PDP 웹페이지로부터 Clorox 고유 GUEST ID 1200w 이미지를 채택한다', () {
        const sampleHtml = '''
          <meta property="og:image" content="https://target.scene7.com/is/image/Target/$expectedGuestId.avif?wid=800" />
        ''';
        final adoptedUrl =
            ImageAdoptionHandler.extractTargetMainImageElement(sampleHtml);
        expect(adoptedUrl, isNotNull);
        expect(adoptedUrl, contains(expectedGuestId));
        expect(adoptedUrl, contains('wid=1200&hei=1200'));
      });

      test('2. 검색어 유사도 스코어링에서 Clorox 3pk가 Lysol 단품보다 높은 점수를 획득한다', () {
        const query = 'clorox disinfecting wipes value pack 75ct 3pk';
        const cloroxTitle =
            'Clorox Disinfecting Wipes Value Pack Bleach Free 75ct 3pk';
        const lysolTitle = 'Lysol Disinfecting Wipes Canister 80ct';

        final cloroxScore = SearchHandler.scoreSimilarity(query, cloroxTitle);
        final lysolScore = SearchHandler.scoreSimilarity(query, lysolTitle);

        expect(cloroxScore, greaterThan(lysolScore));
      });

      test('3. 카탈로그 조회 시 Clorox 공식 PDP 구매 URL과 매핑된다', () async {
        final service = TargetFetcherService();
        final products = await service.fetchTargetProducts([
          const ExtractedItemEntry(
            rawName: 'Disinfecting Wipes',
            cleanName: 'wipes',
            quantity: 1,
            isPersonal: false,
          ),
        ]);

        expect(products.length, equals(1));
        expect(products.first.targetUrl, equals(targetUrl));
        expect(products.first.name, contains('Clorox Disinfecting Wipes'));
      });
    });

    // ═════════════════════════════════════════════════════════════════════════
    // Case 4: Enday Composition Notebook (preselect=1012435915 ➔ GUEST_0a6e8559...)
    // ═════════════════════════════════════════════════════════════════════════
    group('[Case 4] Enday Wide Ruled Notebook (preselect=1012435915)', () {
      const targetUrl =
          'https://www.target.com/p/enday-wide-ruled-black-marble-composition-notebook-100-sheets/-/A-1012435914?preselect=1012435915#lnk=sametab';
      const expectedGuestId = 'GUEST_0a6e8559-507d-4210-ae4a-efb11f109fa2';

      test('1. URL에서 preselect TCIN(1012435915)을 정확히 파싱한다', () {
        final tcin = PdpHandler.extractTcinFromPdpUrl(targetUrl);
        expect(tcin, equals('1012435915'));
      });

      test('2. HTML의 Scene7 링크로부터 고유 GUEST ID 1200w 이미지를 채택한다', () {
        const sampleHtml = '''
          <meta content="https://target.scene7.com/is/image/Target/$expectedGuestId.avif" property="og:image" />
        ''';
        final adoptedUrl =
            ImageAdoptionHandler.extractTargetMainImageElement(sampleHtml);
        expect(adoptedUrl, isNotNull);
        expect(adoptedUrl, contains(expectedGuestId));
        expect(adoptedUrl, contains('wid=1200&hei=1200'));
      });

      test('3. Mock PDPv4 API를 통해 preselect TCIN 기반으로 엔데이 전용 이미지를 채택한다',
          () async {
        final mockClient = MockClient((request) async {
          if (request.url.queryParameters['tcin'] == '1012435915') {
            return http.Response(
              '''
              {
                "data": {
                  "product": {
                    "item": {
                      "enrichment": {
                        "images": {
                          "primary_image_id": "0a6e8559-507d-4210-ae4a-efb11f109fa2"
                        }
                      }
                    }
                  }
                }
              }
              ''',
              200,
              headers: {'content-type': 'application/json'},
            );
          }
          return http.Response('Not Found', 404);
        });

        final service = TargetFetcherService(
            httpClient: mockClient, redSkyApiKey: 'test-authorized-key');
        final adoptedUrl = await service.adoptMainImageFromPdp(targetUrl);

        expect(adoptedUrl, isNotNull);
        expect(adoptedUrl, contains(expectedGuestId));
      });

      test('4. 카탈로그 조회 시 Enday 공식 PDP 구매 URL과 매핑된다', () async {
        final service = TargetFetcherService();
        final products = await service.fetchTargetProducts([
          const ExtractedItemEntry(
            rawName: 'Composition Notebook',
            cleanName: 'composition notebook',
            quantity: 1,
            isPersonal: false,
          ),
        ]);

        expect(products.length, equals(1));
        expect(products.first.targetUrl, equals(targetUrl));
        expect(products.first.name, contains('Enday Wide Ruled Black Marble'));
      });
    });
  });
}

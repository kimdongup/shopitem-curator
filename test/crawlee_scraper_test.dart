import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:shopitem_curator/core/services/scraper/session/browser_fingerprints.dart';
import 'package:shopitem_curator/core/services/scraper/session/session_pool.dart';
import 'package:shopitem_curator/core/services/scraper/concurrency/rate_limiter.dart';
import 'package:shopitem_curator/core/services/scraper/concurrency/concurrent_executor.dart';
import 'package:shopitem_curator/core/services/scraper/cache/scrape_cache_store.dart';
import 'package:shopitem_curator/core/services/scraper/router/image_adoption_handler.dart';
import 'package:shopitem_curator/core/services/scraper/router/search_handler.dart';
import 'package:shopitem_curator/core/services/scraper/router/pdp_handler.dart';

void main() {
  group('Crawlee Scraper Architecture — Pure Dart Unit Tests', () {
    // ── 1. SessionPool & Fingerprint Tests ──────────────────────────────────
    group('SessionPool & Fingerprints', () {
      test('initializes with multiple browser fingerprint presets', () {
        expect(BrowserFingerprint.presets.length, greaterThanOrEqualTo(4));
        final macChrome = BrowserFingerprint.presets
            .firstWhere((p) => p.id.contains('mac_chrome'));
        expect(macChrome.headers['User-Agent'], contains('Macintosh'));
        expect(macChrome.headers['Sec-Ch-Ua'], contains('Chrome'));
      });

      test('SessionPool rotates active sessions in round-robin fashion', () {
        final pool = SessionPool(maxPoolSize: 3);
        final s1 = pool.getSession();
        final s2 = pool.getSession();
        expect(s1.id, isNot(equals(s2.id)));
      });

      test(
          'SessionPool retires bad/blocked session and replenishes fresh session',
          () {
        final pool = SessionPool(maxPoolSize: 2);
        final badSession = pool.getSession();
        final freshSession = pool.retireAndGetNew(badSession);

        expect(badSession.isBlocked, isTrue);
        expect(freshSession.isBlocked, isFalse);
        expect(freshSession.id, isNot(equals(badSession.id)));
      });

      test('SessionPool replacements never exceed the configured pool size',
          () {
        final pool = SessionPool(maxPoolSize: 2);

        for (var i = 0; i < 20; i++) {
          pool.retireAndGetNew(pool.getSession());
        }

        expect(pool.sessionCount, 2);
        expect(pool.activeSessionCount, 2);
      });
    });

    // ── 2. ConcurrentExecutor & RateLimiter Tests ───────────────────────────
    group('ConcurrentExecutor & RateLimiter', () {
      test(
          'ConcurrentExecutor preserves original item order and reports progress',
          () async {
        const executor = ConcurrentExecutor(
          defaultConcurrency: 3,
          rateLimiter: RateLimiter(minDelayMs: 1, maxDelayMs: 5),
        );

        final items = List.generate(10, (i) => 'item_$i');
        final progressCalls = <int>[];

        final results = await executor.execute<String, String>(
          items: items,
          task: (item, index) async {
            await Future.delayed(Duration(milliseconds: 10 - index));
            return 'processed_$item';
          },
          onProgress: (completed, total, currentItem) {
            progressCalls.add(completed);
          },
        );

        expect(results.length, 10);
        // 원래 순서 유지 확인
        for (int i = 0; i < 10; i++) {
          expect(results[i], 'processed_item_$i');
        }
        expect(progressCalls.length, 10);
        expect(progressCalls.last, 10);
      });
    });

    // ── 3. ScrapeCacheStore Tests ───────────────────────────────────────────
    group('ScrapeCacheStore', () {
      test('stores and retrieves cached data before expiration', () {
        final cache = ScrapeCacheStore();
        cache.set('test_key', {'name': 'Sample Product', 'price': 9.99});

        expect(cache.contains('test_key'), isTrue);
        final data = cache.get<Map<String, dynamic>>('test_key');
        expect(data, isNotNull);
        expect(data!['name'], 'Sample Product');
      });

      test('evicts the oldest entry when the configured bound is reached', () {
        final cache = ScrapeCacheStore(maxEntries: 2)
          ..set('first', 1)
          ..set('second', 2)
          ..set('third', 3);

        expect(cache.size, 2);
        expect(cache.get<int>('first'), isNull);
        expect(cache.get<int>('second'), 2);
        expect(cache.get<int>('third'), 3);
      });

      test('evicts expired cache entries automatically', () async {
        final cache = ScrapeCacheStore();
        cache.set('short_lived', 'value', const Duration(milliseconds: 10));

        await Future.delayed(const Duration(milliseconds: 25));
        expect(cache.get<String>('short_lived'), isNull);
      });
    });

    // ── 4. Router Handlers Tests ────────────────────────────────────────────
    group('Router Handlers', () {
      test(
          'ImageAdoptionHandler extracts UUID v4 and builds 1200w high-res URL',
          () {
        const raw =
            'https://target.scene7.com/is/image/Target/GUEST_e011a984-ba75-4ccd-a110-6297483e7190.avif?wid=800';
        final base = ImageAdoptionHandler.extractGuestImageBase(raw);
        expect(base,
            'https://target.scene7.com/is/image/Target/GUEST_e011a984-ba75-4ccd-a110-6297483e7190');
        final highRes = ImageAdoptionHandler.buildHighResUrl(base!);
        expect(highRes, contains('wid=1200&hei=1200&qlt=85&fmt=pjpeg'));
      });

      test('SearchHandler scores brand & volume tokens accurately', () {
        const query = 'mrs meyers hand soap 12.5 fl oz';
        const candidate1 = "Mrs. Meyer's Clean Day Hand Soap 12.5 fl oz";
        const candidate2 = 'Dial Liquid Hand Soap Gold 7.5 fl oz';

        final score1 = SearchHandler.scoreSimilarity(query, candidate1);
        final score2 = SearchHandler.scoreSimilarity(query, candidate2);
        expect(score1, greaterThan(score2));
      });

      test('SearchHandler leaves a missing RedSky price unknown', () async {
        final client = MockClient(
          (_) async => http.Response(
            jsonEncode({
              'data': {
                'search': {
                  'products': [
                    {
                      'item': {
                        'product_description': {'title': 'Verified Notebook'},
                        'buy_url': '/p/verified-notebook/-/A-12345678',
                        'enrichment': {
                          'images': {'primary_image_id': 'guest-id'},
                        },
                      },
                    },
                  ],
                },
              },
            }),
            200,
          ),
        );

        final result =
            await const SearchHandler(redSkyApiKey: 'test-authorized-key')
                .searchPdpUrl(
          query: 'verified notebook',
          client: client,
          sessionPool: SessionPool(),
        );

        expect(result, isNotNull);
        expect(result!.price, 0.0);
      });

      test('SearchHandler HTML fallback never invents a fixed price', () async {
        final client = MockClient((request) async {
          if (request.url.host == 'redsky.target.com') {
            return http.Response('Unavailable', 503);
          }
          return http.Response(
            '<a href="/p/verified-notebook/-/A-12345678">Product</a>',
            200,
          );
        });

        final result = await const SearchHandler().searchPdpUrl(
          query: 'verified notebook',
          client: client,
          sessionPool: SessionPool(),
        );

        expect(result, isNotNull);
        expect(result!.price, 0.0);
      });

      test('PdpHandler extracts preselect TCIN from complex query URLs', () {
        const url =
            'https://www.target.com/p/notebook/-/A-1012435914?preselect=1012435915#lnk=sametab';
        final tcin = PdpHandler.extractTcinFromPdpUrl(url);
        expect(tcin, '1012435915');
      });
    });
  });
}

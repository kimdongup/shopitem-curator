import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:shopitem_curator/core/services/scraper/router/search_handler.dart';
import 'package:shopitem_curator/core/services/scraper/router/pdp_handler.dart';
import 'package:shopitem_curator/core/services/scraper/session/session_pool.dart';
import 'package:shopitem_curator/core/services/scraper/target_request_policy.dart';
import 'package:shopitem_curator/core/services/target_fetcher_service.dart';

void main() {
  test('without operator access, search and PDP never call RedSky', () async {
    final requests = <http.Request>[];
    final client = MockClient((request) async {
      requests.add(request);
      expect(request.url.host, 'www.target.com');
      expect(request.headers['User-Agent'], 'ShopItemCurator/1.0');
      expect(
          request.headers.keys
              .any((key) => key.toLowerCase().startsWith('sec-')),
          isFalse);
      expect(
          request.headers.keys
              .any((key) => key.toLowerCase() == 'accept-encoding'),
          isFalse);
      return http.Response(
          '<a href="/p/notebook/-/A-12345678">Notebook</a>', 200);
    });
    final pool = SessionPool();
    expect(
        await const SearchHandler()
            .searchPdpUrl(query: 'notebook', client: client, sessionPool: pool),
        isNotNull);
    expect(
        await const PdpHandler().adoptMainImage(
            pdpUrl: 'https://www.target.com/p/-/A-12345678',
            client: client,
            sessionPool: pool),
        isNull);
    expect(requests.length, 2);
  });

  test('403 is not retried or reset by replacing session bookkeeping',
      () async {
    final pool = SessionPool();
    var count = 0;
    final client = MockClient((_) async {
      count++;
      return http.Response('', 403);
    });
    final uri = Uri.parse('https://www.target.com/s');
    await expectLater(pool.requests.get(client, uri),
        _failure(TargetLookupFailure.accessDenied));
    pool.retireAndGetNew(pool.getSession());
    await expectLater(pool.requests.get(client, uri),
        _failure(TargetLookupFailure.accessDenied));
    expect(count, 1);
  });

  test('429 waits for Retry-After with the same identity', () async {
    var now = DateTime.utc(2026, 9, 7);
    final policy = TargetRequestPolicy(now: () => now);
    var calls = 0;
    final client = MockClient((_) async {
      calls++;
      return calls == 1
          ? http.Response('', 429, headers: {'retry-after': '120'})
          : http.Response('ok', 200);
    });
    final uri = Uri.parse('https://www.target.com/s');
    await expectLater(
        policy.get(client, uri), _failure(TargetLookupFailure.rateLimited));
    now = now.add(const Duration(seconds: 119));
    await expectLater(
        policy.get(client, uri), _failure(TargetLookupFailure.rateLimited));
    expect(calls, 1);
    now = now.add(const Duration(seconds: 1));
    expect((await policy.get(client, uri)).statusCode, 200);
  });

  test('timeouts and invalid JSON have typed diagnostics without leaking keys',
      () async {
    final policy = TargetRequestPolicy();
    final pending = Completer<http.Response>();
    await expectLater(
        policy.get(MockClient((_) => pending.future),
            Uri.parse('https://www.target.com'),
            timeout: const Duration(milliseconds: 1)),
        _failure(TargetLookupFailure.timeout));
    pending.complete(http.Response('', 200));
    const handler = SearchHandler(redSkyApiKey: 'private-test-key');
    await expectLater(
        handler.searchPdpUrl(
            query: 'notebook',
            client: MockClient((request) async => http.Response(
                request.url.host == 'redsky.target.com'
                    ? '{bad-json'
                    : '<html></html>',
                200)),
            sessionPool: SessionPool()),
        _failure(TargetLookupFailure.invalidResponse));
    expect(
        const TargetLookupException(TargetLookupFailure.accessDenied)
            .toString(),
        isNot(contains('private-test-key')));
  });

  test('Retry-After HTTP date is honored without turning 429 into 403',
      () async {
    var now = DateTime.utc(2026, 9, 7);
    final policy = TargetRequestPolicy(now: () => now);
    var calls = 0;
    final client = MockClient((_) async {
      calls++;
      return calls == 1
          ? http.Response('', 429,
              headers: {'retry-after': 'Mon, 07 Sep 2026 00:02:00 GMT'})
          : http.Response('', 200);
    });
    final uri = Uri.parse('https://www.target.com/s');
    await expectLater(
        policy.get(client, uri), _failure(TargetLookupFailure.rateLimited));
    now = now.add(const Duration(seconds: 119));
    await expectLater(
        policy.get(client, uri), _failure(TargetLookupFailure.rateLimited));
    expect(calls, 1);
    now = now.add(const Duration(seconds: 1));
    expect((await policy.get(client, uri)).statusCode, 200);
    expect(calls, 2);
  });

  test('malformed Retry-After stays rate-limited without sending more requests',
      () async {
    final policy = TargetRequestPolicy();
    var calls = 0;
    final client = MockClient((_) async {
      calls++;
      return http.Response('', 429, headers: {'retry-after': 'invalid-date'});
    });
    final uri = Uri.parse('https://www.target.com/s');
    for (var i = 0; i < 3; i++) {
      await expectLater(
          policy.get(client, uri), _failure(TargetLookupFailure.rateLimited));
    }
    expect(calls, 1);
  });

  for (final status in [403, 429, 503]) {
    test('HTML 404 does not hide configured API status $status', () async {
      final kind = switch (status) {
        403 => TargetLookupFailure.accessDenied,
        429 => TargetLookupFailure.rateLimited,
        _ => TargetLookupFailure.upstreamFailure,
      };
      await expectLater(
          const SearchHandler(redSkyApiKey: 'test-authorized-key').searchPdpUrl(
              query: 'bicycle',
              client: MockClient((request) async => http.Response(
                  '', request.url.host == 'redsky.target.com' ? status : 404)),
              sessionPool: SessionPool()),
          _failure(kind));
    });
  }

  test('API denial remains visible if public HTML contains no products',
      () async {
    var apiCalls = 0;
    final client = MockClient((request) async {
      if (request.url.host == 'redsky.target.com') {
        apiCalls++;
        return http.Response('', 403);
      }
      return http.Response(
          '<html><script id="__NEXT_DATA__">{}</script></html>', 200);
    });
    final pool = SessionPool();
    const handler = SearchHandler(redSkyApiKey: 'test-authorized-key');
    for (final query in ['big notebook', 'shoes for running', 'bicycle']) {
      await expectLater(
          handler.searchPdpUrl(query: query, client: client, sessionPool: pool),
          _failure(TargetLookupFailure.accessDenied));
    }
    expect(apiCalls, 1);
  });

  test(
      'matching user input remains four items and reports missing product data honestly',
      () async {
    final requests = <Uri>[];
    final fetcher = TargetFetcherService(
        preferLiveCatalog: true,
        httpClient: MockClient((request) async {
          requests.add(request.url);
          return http.Response(
              '<html><script id="__NEXT_DATA__">{}</script></html>', 200);
        }));
    addTearDown(fetcher.close);
    final products = await fetcher.fetchTargetProducts([
      for (final name in [
        'big notebook',
        'crayon',
        'shoes for running',
        'bicycle'
      ])
        ExtractedItemEntry(
            rawName: name, cleanName: name, isPersonal: false, quantity: 1),
    ]);
    expect(products.length, 4);
    expect(products[1].imageUrl, 'assets/items/item_crayons.png');
    expect(products[1].description, contains('실시간 확인 안됨'));
    for (final i in [0, 2, 3]) {
      expect(products[i].imageUrl, isEmpty);
      expect(products[i].description, contains('상품 데이터가 없습니다'));
    }
    expect(
        requests.length, 4); // Was up to two entire searches per unknown item.
    expect(requests.every((uri) => uri.host == 'www.target.com'), isTrue);
  });

  test('identical simultaneous searches and negative results share one request',
      () async {
    var count = 0;
    final fetcher =
        TargetFetcherService(httpClient: MockClient((request) async {
      count++;
      await Future<void>.delayed(const Duration(milliseconds: 20));
      return http.Response('', 404);
    }));
    addTearDown(fetcher.close);
    final results = await Future.wait([
      fetcher.resolveTargetProductPdpUrl('  BIG notebook'),
      fetcher.resolveTargetProductPdpUrl('big  notebook '),
    ]);
    expect(results, [null, null]);
    expect(await fetcher.resolveTargetProductPdpUrl('big notebook'), isNull);
    expect(count, 1);
  });

  test('live public HTML diagnostic never invokes RedSky', () async {
    final inner = http.Client();
    addTearDown(inner.close);
    final seen = <String>[];
    final fetcher = TargetFetcherService(
        preferLiveCatalog: true,
        httpClient: MockClient((request) async {
          seen.add(request.url.host);
          expect(request.url.host, 'www.target.com');
          return inner.get(request.url, headers: request.headers);
        }));
    final products = await fetcher.fetchTargetProducts([
      for (final name in [
        'big notebook',
        'crayon',
        'shoes for running',
        'bicycle'
      ])
        ExtractedItemEntry(
            rawName: name, cleanName: name, isPersonal: false, quantity: 1),
    ]);
    expect(products.length, 4);
    stdout.writeln(jsonEncode({
      'hosts': seen.toSet().toList(),
      'items': [
        for (final p in products)
          {
            'name': p.name,
            'matched': p.targetUrl.isNotEmpty,
            'description': p.description
          }
      ]
    }));
  }, skip: Platform.environment['CURATOR_TEST_TARGET_HTML'] != '1');
}

Matcher _failure(TargetLookupFailure kind) => throwsA(
    isA<TargetLookupException>().having((error) => error.kind, 'kind', kind));

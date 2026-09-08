import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:shopitem_curator/core/models/matching_options.dart';
import 'package:shopitem_curator/core/contracts/catalog_gateways.dart';
import 'package:shopitem_curator/core/contracts/curator_use_cases.dart';
import 'package:shopitem_curator/core/services/backend_proxy_gateway.dart';
import 'package:shopitem_curator/core/services/scraper/target_request_policy.dart';
import 'package:shopitem_curator/core/services/scraper/session/session_pool.dart';
import 'package:shopitem_curator/core/services/scraper/router/search_handler.dart';
import '../server/matching_http_client.dart';
import '../server/matching_strategy_registry.dart';
import '../server/matching_browser_client.dart';
import '../server/curator_proxy_server.dart';

void main() {
  final uri = Uri.https('www.target.com', '/s');
  test('strategy flags round trip, reject credential/header/unknown injection',
      () {
    final options = MatchingOptions(MatchingStrategy.values);
    expect(MatchingOptions.fromJson(options.toJson()).key, options.key);
    expect(options.usesBrowser, isTrue);
    expect(() => options.enabled.clear(), throwsUnsupportedError);
    for (final raw in [
      [],
      {
        'enabled': ['invalid']
      },
      {
        'enabled': ['proxy_pool', 'proxy_pool']
      },
      {'enabled': [], 'proxy': 'http://secret'},
      {'enabled': [], 'headers': {}}
    ]) {
      expect(() => MatchingOptions.fromJson(raw), throwsFormatException);
    }
  });
  test(
      'actual headers change on opt-in but 403 breaker spans profiles and default',
      () async {
    final state = TargetAccessState();
    final registry = MatchingStrategyRegistry(
        browser: MatchingBrowserRuntime(executable: '/missing'),
        headerProfiles:
            MatchingStrategyRegistry.chromeProfiles('152.0.7977.83'));
    addTearDown(registry.close);
    final agents = <String?>[];
    final client = MockClient((r) async {
      agents.add(r.headers['user-agent']);
      return http.Response('', agents.length == 2 ? 403 : 200);
    });
    final selected = TargetRequestPolicy(
        accessState: state, headersFor: registry.headersFor);
    final basic = TargetRequestPolicy(accessState: state);
    await selected.get(client, uri);
    await expectLater(
        selected.get(client, uri), throwsA(isA<TargetLookupException>()));
    await expectLater(
        basic.get(client, uri), throwsA(isA<TargetLookupException>()));
    expect(agents.length, 2);
    expect(agents.first, contains('Macintosh'));
    expect(agents.last, contains('Windows'));
  });
  test('queued requests recheck denial after delay and Retry-After is shared',
      () async {
    final state = TargetAccessState();
    final ready = Completer<void>();
    final queued = TargetRequestPolicy(
        accessState: state, beforeRequest: () => ready.future);
    var calls = 0;
    final client = MockClient((_) async {
      calls++;
      return http.Response('', 200);
    });
    final request = queued.get(client, uri);
    final expectation =
        expectLater(request, throwsA(isA<TargetLookupException>()));
    state.deniedHosts.add(uri.host);
    ready.complete();
    await expectation;
    expect(calls, 0);
    state.deniedHosts.clear();
    expect(
        () => TargetRequestPolicy(accessState: state).inspectResponse(
            uri, http.Response('', 429, headers: {'retry-after': '120'})),
        throwsA(isA<TargetLookupException>()));
    await expectLater(TargetRequestPolicy(accessState: state).get(client, uri),
        throwsA(isA<TargetLookupException>()));
    expect(calls, 0);
  });
  test('request spacing is bounded and serialized', () async {
    final durations = <Duration>[];
    final scheduler = MatchingRequestScheduler(
        random: Random(7),
        delay: (d) async {
          durations.add(d);
        });
    await Future.wait(
        List.generate(25, (_) => scheduler.wait(randomized: true)));
    expect(
        durations
            .every((d) => d.inMilliseconds >= 1200 && d.inMilliseconds <= 3800),
        isTrue);
    expect(durations.toSet().length, greaterThan(1));
    scheduler.close();
    await expectLater(scheduler.wait(randomized: false),
        throwsA(isA<TargetLookupException>()));
  });
  test(
      'operator proxy config keeps credentials separate and rotates without direct fallback',
      () async {
    final a = MatchingProxy.fromJson({
      'url': 'http://one.example:8080',
      'username': 'USER',
      'password': 'SECRET'
    });
    final b = MatchingProxy.fromJson({'url': 'http://two.example:8080'});
    expect(a.toString(), isNot(contains('SECRET')));
    expect(
        () => MatchingProxy.fromJson(
            {'url': 'http://user:secret@one.example:8080'}),
        throwsFormatException);
    expect(() => MatchingProxy.fromJson({'url': 'file:///tmp/proxy'}),
        throwsFormatException);
    final used = <MatchingProxy?>[];
    final client = MatchingHttpClient(
        proxies: [a, b],
        createClient: (proxy) => MockClient((_) async {
              used.add(proxy);
              if (proxy == a) throw const SocketException('proxy unavailable');
              return http.Response('ok', 200);
            }));
    addTearDown(client.close);
    await expectLater(client.get(uri), throwsA(isA<SocketException>()));
    expect(used, [a]);
    expect((await client.get(uri)).body, 'ok');
    expect(used, [a, b]);
  });
  test('HTTP transport bounds bodies and rejects redirect to another host',
      () async {
    var calls = 0;
    final client = MatchingHttpClient(
        createClient: (_) => MockClient((_) async {
              calls++;
              return http.Response('', 302,
                  headers: {'location': 'https://127.0.0.1/private'});
            }));
    addTearDown(client.close);
    await expectLater(client.get(uri), throwsA(isA<TargetLookupException>()));
    expect(calls, 1);
    final large = MatchingHttpClient(
        maxBytes: 4,
        createClient: (_) =>
            MockClient((_) async => http.Response('12345', 200)));
    addTearDown(large.close);
    await expectLater(large.get(uri), throwsA(isA<TargetLookupException>()));
  });
  test(
      'missing browser/proxy disables only dependent capabilities, never silent fallback',
      () async {
    final registry = MatchingStrategyRegistry(
        browser:
            MatchingBrowserRuntime(executable: '/missing', node: '/missing'));
    addTearDown(registry.close);
    final capabilities = await registry.capabilities();
    expect(capabilities.where((c) => c.available).single.strategy,
        MatchingStrategy.randomDelay);
    expect(await registry.service(null), isNull);
    await expectLater(
        registry.service({
          'enabled': ['proxy_pool']
        }),
        throwsA(isA<MatchingStrategyException>()));
    await expectLater(
        registry.service({
          'enabled': ['stealth_browser']
        }),
        throwsA(isA<MatchingStrategyException>()));
    await expectLater(
        registry.service({
          'enabled': ['random_delay'],
          'proxy': 'SECRET'
        }),
        throwsA(isA<MatchingStrategyException>()));
    final first = await registry.service({
      'enabled': ['random_delay']
    });
    expect(
        await registry.service({
          'enabled': ['random_delay']
        }),
        same(first));
  });
  test(
      'observed JSON wins as an atomic product, invalid URL cannot enter search',
      () async {
    const html =
        '<script id="curator-observed-products" type="application/json">'
        '[{"name":"big notebook","target_url":"https://www.target.com/p/-/A-12345678",'
        '"image_url":"https://target.scene7.com/is/image/Target/GUEST_note","price":3.25},'
        '{"name":"notebook","target_url":"https://evil.test/p/-/A-12345678","image_url":"https://evil.test/image","price":1}]</script>';
    final result = await const SearchHandler().searchPdpUrl(
        query: 'big notebook',
        client: MockClient((_) async => http.Response(html, 200)),
        sessionPool: SessionPool());
    expect(result!.name, 'big notebook');
    expect(result.price, 3.25);
    expect(result.primaryImageUrl, endsWith('GUEST_note'));
    expect(result.pdpUrl, contains('www.target.com'));
  });
  test(
      'scoped gateway does not mutate sibling requests and chunks with unique IDs',
      () async {
    final requests = <Map<String, dynamic>>[];
    final gateway = BackendProxyGateway(
        backendBaseUrl: 'http://127.0.0.1:8787',
        httpClient: MockClient((r) async {
          final body = jsonDecode(r.body) as Map<String, dynamic>;
          requests.add(body);
          if (r.url.path.endsWith('inspect')) return _json({'candidate': null});
          expect((body['items'] as List).length, 1);
          return _json({
            'products': [
              {
                'id': 'item_1',
                'name': body['items'][0]['clean_name'],
                'category': 'Other',
                'is_personal': false,
                'quantity': 1,
                'price': 0,
                'price_currency': 'USD',
                'description': 'Unknown',
                'target_url': '',
                'image_url': ''
              }
            ]
          });
        }));
    final advanced = gateway
        .withMatchingOptions(MatchingOptions([MatchingStrategy.randomDelay]));
    await advanced
        .fetchProductByTargetUrl('https://www.target.com/p/-/A-12345678');
    await gateway
        .fetchProductByTargetUrl('https://www.target.com/p/-/A-12345678');
    expect(requests[0]['matching_options'], {
      'enabled': ['random_delay']
    });
    expect(requests[1].containsKey('matching_options'), isFalse);
    final result = await advanced.fetchTargetProducts([
      const ExtractedItemEntry(
          rawName: 'Notebook',
          cleanName: 'Notebook',
          isPersonal: false,
          quantity: 1),
      const ExtractedItemEntry(
          rawName: 'Crayon',
          cleanName: 'Crayon',
          isPersonal: false,
          quantity: 1)
    ]);
    expect(result.map((p) => p.id), ['item_1', 'item_2']);
    expect(result.map((p) => p.name), ['Notebook', 'Crayon']);
  });
  test(
      'server authenticates capabilities and rejects unsupported flags before catalog execution',
      () async {
    var catalogCalls = 0;
    final registry = MatchingStrategyRegistry(
        browser:
            MatchingBrowserRuntime(executable: '/missing', node: '/missing'));
    final server = CuratorProxyServer(
        config: CuratorProxyConfig(
            bindAddress: InternetAddress.loopbackIPv4,
            port: 0,
            bearerToken: 'test-token'),
        matchingStrategies: registry,
        dependencies: CuratorProxyDependencies(
            extractOcr:
                ({required sourceImagePath, required imageBytes}) async => [],
            fetchProducts: (items) async {
              catalogCalls++;
              return [];
            },
            fetchCandidates: (_) async => [],
            inspectProduct: (_) async => null,
            rescrape: (items) async => CatalogRescrapeResult(
                items: items,
                successfulItemCount: 0,
                failedItemCount: items.length)));
    await server.start();
    addTearDown(server.close);
    final client = http.Client();
    addTearDown(client.close);
    final endpoint = server.baseUri.resolve('/v1/catalog/strategies');
    expect((await client.get(endpoint)).statusCode, 401);
    final headers = {
      'authorization': 'Bearer test-token',
      'content-type': 'application/json'
    };
    final capabilities = await client.get(endpoint, headers: headers);
    expect(capabilities.statusCode, 200);
    expect(capabilities.body, isNot(contains('/missing')));
    for (final flag in ['proxy_pool', 'invented']) {
      final result =
          await client.post(server.baseUri.resolve('/v1/catalog/products'),
              headers: headers,
              body: jsonEncode({
                'items': [
                  {
                    'raw_name': 'Notebook',
                    'clean_name': 'Notebook',
                    'is_personal': false,
                    'quantity': 1
                  }
                ],
                'matching_options': {
                  'enabled': [flag]
                }
              }));
      expect(result.statusCode, flag == 'proxy_pool' ? 503 : 400);
      expect(result.body, contains('matching_strategy_unavailable'));
    }
    expect(catalogCalls, 0);
  });
}

http.Response _json(Object body) => http.Response(jsonEncode(body), 200,
    headers: {'content-type': 'application/json'});

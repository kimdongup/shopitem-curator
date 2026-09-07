import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:shopitem_curator/core/contracts/catalog_gateways.dart';
import 'package:shopitem_curator/core/contracts/curator_use_cases.dart';
import 'package:shopitem_curator/core/models/curator_item.dart';
import 'package:shopitem_curator/core/services/ocr_extractor_service.dart';
import 'package:shopitem_curator/core/services/target_fetcher_service.dart';
import 'package:shopitem_curator/core/services/scraper/target_request_policy.dart';
import 'package:test/test.dart';

import '../server/curator_proxy_server.dart';
import '../server/avif_image_decoder.dart';
import 'fixtures/transparent_avif.dart';

const _token = 'test-proxy-token';
const _scene7Url =
    'https://target.scene7.com/is/image/Target/GUEST_123?wid=1200';
const _targetUrl = 'https://www.target.com/p/-/A-12345678';

void main() {
  group('CuratorProxyConfig', () {
    test('rejects unauthenticated public and trusted-header public binds', () {
      expect(
        () => CuratorProxyConfig(
          bindAddress: InternetAddress.anyIPv4,
          bearerToken: null,
        ),
        throwsArgumentError,
      );
      expect(
        () => CuratorProxyConfig(
          bindAddress: InternetAddress.anyIPv4,
          bearerToken: _token,
          trustedAuthHeader: 'X-Verified-User',
        ),
        throwsArgumentError,
      );
    });

    test('accepts exact CORS lists and rejects wildcard or malformed origins',
        () {
      expect(
        () => CuratorProxyConfig(
          bindAddress: InternetAddress.loopbackIPv4,
          bearerToken: _token,
          allowedOrigin: 'https://app.example, http://localhost:8080',
        ),
        returnsNormally,
      );
      for (final origin in [
        '*',
        'https://user@app.example',
        'https://app.example/path',
        'https://app.example?query=1',
      ]) {
        expect(
          () => CuratorProxyConfig(
            bindAddress: InternetAddress.loopbackIPv4,
            bearerToken: _token,
            allowedOrigin: origin,
          ),
          throwsArgumentError,
          reason: origin,
        );
      }
    });
  });

  test('health is public while catalog endpoints require a valid bearer token',
      () async {
    final harness = await _startHarness();
    addTearDown(harness.close);

    final health = await harness.request('GET', '/health');
    expect(health.statusCode, HttpStatus.ok);
    expect(health.json, {
      'status': 'ok',
      'service': 'shopitem-curator-proxy',
      'api_version': 'v1',
    });
    expect(health.header('x-request-id'), isNotEmpty);

    final missing = await harness.request(
      'POST',
      '/v1/catalog/inspect',
      jsonBody: const {'url': _targetUrl},
    );
    expect(missing.statusCode, HttpStatus.unauthorized);
    expect(missing.header('www-authenticate'), contains('Bearer'));

    final wrong = await harness.request(
      'POST',
      '/v1/catalog/inspect',
      token: 'wrong-token',
      jsonBody: const {'url': _targetUrl},
    );
    expect(wrong.statusCode, HttpStatus.unauthorized);

    final accepted = await harness.request(
      'POST',
      '/v1/catalog/inspect',
      token: _token,
      jsonBody: const {'url': _targetUrl},
    );
    expect(accepted.statusCode, HttpStatus.ok);
    expect(accepted.json, {'candidate': null});
  });

  test('readiness is public and reports whether OCR is configured', () async {
    final readyHarness = await _startHarness();
    addTearDown(readyHarness.close);

    final ready = await readyHarness.request('GET', '/ready');
    expect(ready.statusCode, HttpStatus.ok);
    expect(ready.json, {
      'status': 'ready',
      'service': 'shopitem-curator-proxy',
      'api_version': 'v1',
      'dependencies': {'ocr': 'ready'},
    });

    final unavailableHarness = await _startHarness(
      dependencies: _dependencies(ocrConfigured: false),
    );
    addTearDown(unavailableHarness.close);

    final health = await unavailableHarness.request('GET', '/health');
    expect(health.statusCode, HttpStatus.ok);

    final unavailable = await unavailableHarness.request('GET', '/ready');
    expect(unavailable.statusCode, HttpStatus.serviceUnavailable);
    expect(unavailable.json, {
      'status': 'not_ready',
      'service': 'shopitem-curator-proxy',
      'api_version': 'v1',
      'dependencies': {'ocr': 'not_configured'},
    });
    expect(unavailable.body, isNot(contains('GEMINI_API_KEY')));
    expect(unavailable.header('www-authenticate'), isNull);
  });

  for (final kind in TargetLookupFailure.values) {
    test('catalog routes expose safe Target diagnostic ${kind.name}', () async {
      final failure = TargetLookupException(kind);
      final harness = await _startHarness(
        dependencies: _dependencies(
          fetchProducts: (_) async => throw failure,
          fetchCandidates: (_) async => throw failure,
          inspectProduct: (_) async => throw failure,
          rescrape: (_) async => throw failure,
        ),
      );
      addTearDown(harness.close);
      final bodies = {
        '/v1/catalog/products': {
          'items': [
            {
              'raw_name': 'bicycle',
              'clean_name': 'bicycle',
              'is_personal': false,
              'quantity': 1,
            }
          ]
        },
        '/v1/catalog/review-candidates': {'item': _item().toJson()},
        '/v1/catalog/inspect': {'url': _targetUrl},
        '/v1/catalog/rescrape': {
          'items': [_item().toJson()]
        },
      };
      for (final entry in bodies.entries) {
        final response = await harness.request('POST', entry.key,
            token: _token, jsonBody: entry.value);
        expect(response.statusCode,
            kind == TargetLookupFailure.rateLimited ? 429 : 502,
            reason: entry.key);
        expect(((response.json as Map)['error'] as Map)['code'], failure.code);
        expect(response.header('x-request-id'), isNotEmpty);
        expect(response.body, isNot(contains(_token)));
        expect(response.body, isNot(contains(_targetUrl)));
      }
    });
  }

  test('local OCR readiness recovers without restarting and fails closed',
      () async {
    var available = false;
    var shouldThrow = false;
    final harness = await _startHarness(
        dependencies: _dependencies(checkOcrReady: () async {
      if (shouldThrow) throw StateError('private-engine-path');
      return available;
    }));
    addTearDown(harness.close);
    expect((await harness.request('GET', '/ready')).statusCode, 503);
    available = true;
    expect((await harness.request('GET', '/ready')).statusCode, 200);
    shouldThrow = true;
    final failed = await harness.request('GET', '/ready');
    expect(failed.statusCode, 503);
    expect(failed.body, isNot(contains('private-engine-path')));
  });

  test('trusted reverse-proxy header is the only auth bypass in that mode',
      () async {
    final harness = await _startHarness(
      config: _config(
        bearerToken: null,
        trustedAuthHeader: 'X-Curator-Authenticated',
      ),
    );
    addTearDown(harness.close);

    final missing = await harness.request(
      'POST',
      '/v1/catalog/inspect',
      jsonBody: const {'url': _targetUrl},
    );
    expect(missing.statusCode, HttpStatus.unauthorized);

    final forgedValue = await harness.request(
      'POST',
      '/v1/catalog/inspect',
      headers: const {'X-Curator-Authenticated': 'true'},
      jsonBody: const {'url': _targetUrl},
    );
    expect(forgedValue.statusCode, HttpStatus.unauthorized);

    final injected = await harness.request(
      'POST',
      '/v1/catalog/inspect',
      headers: const {'X-Curator-Authenticated': '1'},
      jsonBody: const {'url': _targetUrl},
    );
    expect(injected.statusCode, HttpStatus.ok);
  });

  test('CORS allows exact lists and handles preflight without authentication',
      () async {
    final harness = await _startHarness(
      config: _config(
        allowedOrigin: 'https://one.example, https://two.example:8443',
      ),
    );
    addTearDown(harness.close);

    final preflight = await harness.request(
      'OPTIONS',
      '/v1/catalog/products',
      origin: 'https://two.example:8443',
    );
    expect(preflight.statusCode, HttpStatus.noContent);
    expect(
      preflight.header('access-control-allow-origin'),
      'https://two.example:8443',
    );
    expect(preflight.header('vary'), contains('Origin'));

    final denied = await harness.request(
      'OPTIONS',
      '/v1/catalog/products',
      origin: 'https://evil.example',
    );
    expect(denied.statusCode, HttpStatus.forbidden);
  });

  test('implicit random-port CORS is limited to unauthenticated loopback dev',
      () async {
    final development = await _startHarness(
      config: _config(bearerToken: null),
    );
    addTearDown(development.close);

    final local = await development.request(
      'GET',
      '/health',
      origin: 'http://localhost:54321',
    );
    expect(local.statusCode, HttpStatus.ok);
    expect(
      local.header('access-control-allow-origin'),
      'http://localhost:54321',
    );

    final nonLocal = await development.request(
      'GET',
      '/health',
      origin: 'https://app.example',
    );
    expect(nonLocal.statusCode, HttpStatus.forbidden);

    final authenticated = await _startHarness(config: _config());
    addTearDown(authenticated.close);
    final noImplicitCors = await authenticated.request(
      'GET',
      '/health',
      origin: 'http://127.0.0.1:54321',
    );
    expect(noImplicitCors.statusCode, HttpStatus.forbidden);
  });

  test('OCR accepts bytes and emits the snake_case gateway contract', () async {
    String? receivedPath;
    List<int>? receivedBytes;
    final dependencies = _dependencies(
      extractOcr: ({required sourceImagePath, required imageBytes}) async {
        receivedPath = sourceImagePath;
        receivedBytes = List<int>.of(imageBytes);
        return const [
          ExtractedItemEntry(
            rawName: 'Markers*',
            cleanName: 'markers',
            isPersonal: true,
            quantity: 2,
          ),
        ];
      },
    );
    final harness = await _startHarness(dependencies: dependencies);
    addTearDown(harness.close);

    final response = await harness.request(
      'POST',
      '/v1/ocr/extract',
      token: _token,
      jsonBody: {
        'source_image_path': 'uploads/list.png',
        'image_base64': base64Encode([1, 2, 3, 4]),
      },
    );

    expect(response.statusCode, HttpStatus.ok);
    expect(receivedPath, 'uploads/list.png');
    expect(receivedBytes, [1, 2, 3, 4]);
    expect(response.json, {
      'items': [
        {
          'raw_name': 'Markers*',
          'clean_name': 'markers',
          'is_personal': true,
          'quantity': 2,
        },
      ],
    });
  });

  test('OCR configuration and upstream failures are sanitized with request IDs',
      () async {
    final unavailable = await _startHarness(
      dependencies: _dependencies(ocrConfigured: false),
    );
    addTearDown(unavailable.close);
    final unavailableResponse = await unavailable.request(
      'POST',
      '/v1/ocr/extract',
      token: _token,
      jsonBody: {
        'image_base64': base64Encode([1])
      },
    );
    expect(unavailableResponse.statusCode, HttpStatus.serviceUnavailable);

    const upstreamSecret = '/private/ocr/do-not-leak process-stderr-secret';
    final failing = await _startHarness(
      dependencies: _dependencies(
        extractOcr: ({required sourceImagePath, required imageBytes}) async {
          throw StateError(upstreamSecret);
        },
      ),
    );
    addTearDown(failing.close);
    final failure = await failing.request(
      'POST',
      '/v1/ocr/extract',
      token: _token,
      jsonBody: {
        'image_base64': base64Encode([1])
      },
    );
    expect(failure.statusCode, HttpStatus.badGateway);
    expect(failure.body, isNot(contains(upstreamSecret)));
    expect(failure.body, isNot(contains('do-not-leak')));
    final error =
        (failure.json as Map<String, dynamic>)['error'] as Map<String, dynamic>;
    expect(error['message'], 'Local OCR processing failed.');
    expect(error['code'], 'ocr_failed');
    expect(error['request_id'], failure.header('x-request-id'));

    final unavailableModel = await _startHarness(
      dependencies: _dependencies(
        extractOcr: ({required sourceImagePath, required imageBytes}) async {
          throw const OcrException(OcrFailureKind.engineUnavailable);
        },
      ),
    );
    addTearDown(unavailableModel.close);
    final modelFailure = await unavailableModel.request(
      'POST',
      '/v1/ocr/extract',
      token: _token,
      jsonBody: {
        'image_base64': base64Encode([1])
      },
    );
    expect(modelFailure.statusCode, HttpStatus.serviceUnavailable);
    final modelError = (modelFailure.json as Map<String, dynamic>)['error']
        as Map<String, dynamic>;
    expect(modelError['code'], 'ocr_engine_unavailable');
    expect(modelError['message'], contains('engine or language data'));
    expect(modelError['request_id'], modelFailure.header('x-request-id'));
  });

  test(
      'catalog routes serialize products, candidates, inspection, and rescrape',
      () async {
    final item = _item(imageUrl: _scene7Url);
    final dependencies = _dependencies(
      fetchProducts: (items) async => const [
        TargetProductData(
          id: 'product-1',
          name: 'Markers',
          category: 'Writing',
          isPersonal: true,
          quantity: 2,
          price: 4.25,
          priceCurrency: 'USD',
          description: 'Washable',
          targetUrl: _targetUrl,
          imageUrl: _scene7Url,
        ),
      ],
      fetchCandidates: (_) async => const [
        TargetProductCandidate(
          id: 'candidate-1',
          name: 'Candidate',
          price: 5.5,
          imageUrl: _scene7Url,
          targetUrl: _targetUrl,
          description: 'Candidate description',
        ),
      ],
      inspectProduct: (_) async => const TargetProductCandidate(
        id: 'inspected-1',
        name: 'Inspected',
        price: 6,
        imageUrl: 'assets/items/local.png',
        targetUrl: _targetUrl,
        description: 'Inspected description',
      ),
      rescrape: (items) async => CatalogRescrapeResult(
        items: items,
        successfulItemCount: items.length,
        failedItemCount: 0,
      ),
    );
    final harness = await _startHarness(dependencies: dependencies);
    addTearDown(harness.close);

    final products = await harness.request(
      'POST',
      '/v1/catalog/products',
      token: _token,
      jsonBody: const {
        'items': [
          {
            'raw_name': 'Markers*',
            'clean_name': 'markers',
            'is_personal': true,
            'quantity': 2,
          },
        ],
      },
    );
    expect(products.statusCode, HttpStatus.ok);
    final product =
        ((products.json as Map<String, dynamic>)['products'] as List<dynamic>)
            .single as Map<String, dynamic>;
    expect(product['price_currency'], 'USD');
    expect(product['image_url'], startsWith('/v1/catalog/image?url='));
    expect(product, isNot(contains('priceCurrency')));

    final candidates = await harness.request(
      'POST',
      '/v1/catalog/review-candidates',
      token: _token,
      jsonBody: {'item': item.toJson()},
    );
    expect(candidates.statusCode, HttpStatus.ok);
    final candidate = ((candidates.json as Map<String, dynamic>)['candidates']
            as List<dynamic>)
        .single as Map<String, dynamic>;
    expect(candidate['id'], 'candidate-1');
    expect(candidate['image_url'], startsWith('/v1/catalog/image?url='));

    final inspection = await harness.request(
      'POST',
      '/v1/catalog/inspect',
      token: _token,
      jsonBody: const {'url': _targetUrl},
    );
    expect(inspection.statusCode, HttpStatus.ok);
    expect(
      ((inspection.json as Map<String, dynamic>)['candidate']
          as Map<String, dynamic>)['image_url'],
      'assets/items/local.png',
    );

    final rescrape = await harness.request(
      'POST',
      '/v1/catalog/rescrape',
      token: _token,
      jsonBody: {
        'items': [item.toJson()],
      },
    );
    expect(rescrape.statusCode, HttpStatus.ok);
    expect(rescrape.json, {
      'items': [
        {
          ...item.toJson(),
          'image_url': startsWith('/v1/catalog/image?url='),
        },
      ],
      'successful_item_count': 1,
      'failed_item_count': 0,
    });
  });

  test('inspection and image proxy reject hosts outside the Target allowlist',
      () async {
    var inspectCalls = 0;
    final imageFetcher = _FakeImageFetcher();
    final harness = await _startHarness(
      dependencies: _dependencies(
        inspectProduct: (_) async {
          inspectCalls++;
          return null;
        },
      ),
      imageFetcher: imageFetcher,
    );
    addTearDown(harness.close);

    final inspection = await harness.request(
      'POST',
      '/v1/catalog/inspect',
      token: _token,
      jsonBody: const {'url': 'https://example.com/p/-/A-12345678'},
    );
    expect(inspection.statusCode, HttpStatus.badRequest);
    expect(inspectCalls, 0);

    final imagePath = Uri(
      path: '/v1/catalog/image',
      queryParameters: const {'url': 'https://example.com/image.png'},
    ).toString();
    final image = await harness.request('GET', imagePath, token: _token);
    expect(image.statusCode, HttpStatus.badRequest);
    expect(imageFetcher.requestedUris, isEmpty);
  });

  test('image proxy returns only allowlisted raster bytes', () async {
    final decoder = _FakeAvifDecoder();
    final imageFetcher = _FakeImageFetcher(
      image: CuratorProxyImage(
        bytes: const [0x89, 0x50, 0x4e, 0x47],
        contentType: 'image/png',
      ),
    );
    final harness =
        await _startHarness(imageFetcher: imageFetcher, avifDecoder: decoder);
    addTearDown(harness.close);

    final path = Uri(
      path: '/v1/catalog/image',
      queryParameters: const {'url': _scene7Url},
    ).toString();
    final response = await harness.request('GET', path, token: _token);

    expect(response.statusCode, HttpStatus.ok);
    expect(response.bytes, [0x89, 0x50, 0x4e, 0x47]);
    expect(response.header('content-type'), startsWith('image/png'));
    expect(imageFetcher.requestedUris.single.toString(), _scene7Url);
    expect(decoder.calls, 0);
  });

  for (final mime in ['image/avif', 'image/jpeg']) {
    test('image proxy normalizes AVIF even when reported as $mime', () async {
      final decoder = _FakeAvifDecoder();
      final harness = await _startHarness(
          avifDecoder: decoder,
          imageFetcher: _FakeImageFetcher(
              image: CuratorProxyImage(
                  bytes: transparentLShapeAvif(), contentType: mime)));
      addTearDown(harness.close);
      final path = Uri(path: '/v1/catalog/image', queryParameters: {
        'url': _scene7Url,
        'raster': 'png-v1',
      }).toString();
      final denied = await harness.request('GET', path);
      expect(denied.statusCode, 401);
      expect(decoder.calls, 0);
      final response = await harness.request('GET', path, token: _token);
      expect(response.statusCode, 200);
      expect(response.header('content-type'), startsWith('image/png'));
      expect(response.bytes, decoder.png);
      expect(response.header('content-length'), '${decoder.png.length}');
      expect(decoder.calls, 1);
      expect(response.header('cache-control'), contains('private'));
      await harness.close();
      expect(decoder.closeCount, 1);
    });
  }

  for (final (kind, status, code) in [
    (AvifDecodeFailure.unavailable, 503, 'avif_decoder_unavailable'),
    (AvifDecodeFailure.invalidImage, 502, 'avif_decode_failed'),
    (AvifDecodeFailure.oversized, 413, 'avif_image_too_large'),
    (AvifDecodeFailure.busy, 429, 'avif_decoder_busy'),
  ]) {
    test('AVIF $kind returns sanitized $status, never undecoded image bytes',
        () async {
      final harness = await _startHarness(
          avifDecoder: _FakeAvifDecoder(error: AvifDecodeException(kind)),
          imageFetcher: _FakeImageFetcher(
              image: CuratorProxyImage(
                  bytes: transparentLShapeAvif(), contentType: 'image/avif')));
      addTearDown(harness.close);
      final response = await harness.request(
          'GET',
          Uri(path: '/v1/catalog/image', queryParameters: {'url': _scene7Url})
              .toString(),
          token: _token);
      expect(response.statusCode, status);
      expect(response.header('content-type'), startsWith('application/json'));
      expect(response.body, contains(code));
    });
  }

  test('body size, upstream timeout, and per-IP rate limit are enforced',
      () async {
    final smallBody = await _startHarness(
      config: _config(maxBodyBytes: 64),
    );
    addTearDown(smallBody.close);
    final tooLarge = await smallBody.request(
      'POST',
      '/v1/catalog/products',
      token: _token,
      jsonBody: {'items': List.filled(20, 'oversized')},
    );
    expect(tooLarge.statusCode, HttpStatus.requestEntityTooLarge);

    final never = Completer<List<TargetProductCandidate>>();
    final timingOut = await _startHarness(
      config: _config(upstreamTimeout: const Duration(milliseconds: 20)),
      dependencies: _dependencies(fetchCandidates: (_) => never.future),
    );
    addTearDown(timingOut.close);
    final timeout = await timingOut.request(
      'POST',
      '/v1/catalog/review-candidates',
      token: _token,
      jsonBody: {'item': _item().toJson()},
    );
    expect(timeout.statusCode, HttpStatus.gatewayTimeout);

    final rateLimited = await _startHarness(config: _config(rateLimit: 2));
    addTearDown(rateLimited.close);
    for (var index = 0; index < 2; index++) {
      final accepted = await rateLimited.request(
        'POST',
        '/v1/catalog/inspect',
        token: _token,
        jsonBody: const {'url': _targetUrl},
      );
      expect(accepted.statusCode, HttpStatus.ok);
    }
    final rejected = await rateLimited.request(
      'POST',
      '/v1/catalog/inspect',
      token: _token,
      jsonBody: const {'url': _targetUrl},
    );
    expect(rejected.statusCode, HttpStatus.tooManyRequests);
    expect(rejected.header('retry-after'), isNotEmpty);
  });

  test('close releases injected resources and is idempotent', () async {
    var dependenciesClosed = 0;
    final imageFetcher = _FakeImageFetcher();
    final harness = await _startHarness(
      dependencies: _dependencies(close: () => dependenciesClosed++),
      imageFetcher: imageFetcher,
    );

    expect(harness.server.isRunning, isTrue);
    await harness.server.close();
    await harness.server.close();

    expect(harness.server.isRunning, isFalse);
    expect(dependenciesClosed, 1);
    expect(imageFetcher.closeCount, 1);
    harness.client.close(force: true);
  });
}

CuratorProxyConfig _config({
  String? bearerToken = _token,
  String? trustedAuthHeader,
  String? allowedOrigin,
  int maxBodyBytes = 12 * 1024 * 1024,
  int maxImageBytes = 8 * 1024 * 1024,
  Duration upstreamTimeout = const Duration(seconds: 1),
  int rateLimit = 100,
}) {
  return CuratorProxyConfig(
    bindAddress: InternetAddress.loopbackIPv4,
    port: 0,
    bearerToken: bearerToken,
    trustedAuthHeader: trustedAuthHeader,
    allowedOrigin: allowedOrigin,
    maxBodyBytes: maxBodyBytes,
    maxImageBytes: maxImageBytes,
    upstreamTimeout: upstreamTimeout,
    rateLimit: rateLimit,
  );
}

CuratorProxyDependencies _dependencies({
  ProxyOcrExtractor? extractOcr,
  ProxyProductFetcher? fetchProducts,
  ProxyCandidateFetcher? fetchCandidates,
  ProxyProductInspector? inspectProduct,
  ProxyCatalogRescraper? rescrape,
  bool ocrConfigured = true,
  Future<bool> Function()? checkOcrReady,
  FutureOr<void> Function()? close,
}) {
  return CuratorProxyDependencies(
    extractOcr: extractOcr ??
        ({required sourceImagePath, required imageBytes}) async => const [],
    fetchProducts: fetchProducts ?? (_) async => const [],
    fetchCandidates: fetchCandidates ?? (_) async => const [],
    inspectProduct: inspectProduct ?? (_) async => null,
    rescrape: rescrape ??
        (items) async => CatalogRescrapeResult(
              items: items,
              successfulItemCount: items.length,
              failedItemCount: 0,
            ),
    ocrConfigured: ocrConfigured,
    checkOcrReady: checkOcrReady,
    close: close,
  );
}

CuratorItem _item({String imageUrl = 'assets/items/item.png'}) {
  return CuratorItem(
    id: 'item-1',
    name: 'Markers',
    category: 'Writing',
    isPersonal: true,
    quantity: 2,
    price: 4.25,
    priceCurrency: 'USD',
    description: 'Washable markers',
    targetUrl: _targetUrl,
    imageUrl: imageUrl,
    bounds: const ItemLayoutBounds(x: 0, y: 0, width: 100, height: 100),
    polygon: const [
      CuratorPoint(0, 0),
      CuratorPoint(100, 0),
      CuratorPoint(100, 100),
    ],
    centroid: const CuratorPoint(50, 50),
  );
}

Future<_Harness> _startHarness({
  CuratorProxyConfig? config,
  CuratorProxyDependencies? dependencies,
  CuratorProxyImageFetcher? imageFetcher,
  AvifImageDecoder? avifDecoder,
}) async {
  final server = CuratorProxyServer(
    config: config ?? _config(),
    dependencies: dependencies ?? _dependencies(),
    imageFetcher: imageFetcher,
    avifDecoder: avifDecoder,
  );
  await server.start();
  return _Harness(server);
}

final class _Harness {
  _Harness(this.server) {
    client.findProxy = (_) => 'DIRECT';
    client.connectionTimeout = const Duration(seconds: 2);
  }

  final CuratorProxyServer server;
  final HttpClient client = HttpClient();

  Future<_TestResponse> request(
    String method,
    String path, {
    String? token,
    String? origin,
    Map<String, String> headers = const {},
    Object? jsonBody,
  }) async {
    final request = await client.openUrl(method, server.baseUri.resolve(path));
    if (token != null) {
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    }
    if (origin != null) request.headers.set('Origin', origin);
    headers.forEach(request.headers.set);
    if (jsonBody != null) {
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(jsonBody));
    }
    final response = await request.close();
    final responseHeaders = <String, List<String>>{};
    response.headers.forEach(
      (name, values) => responseHeaders[name.toLowerCase()] = List.of(values),
    );
    final bytes = await response.fold<List<int>>(
      <int>[],
      (all, chunk) => all..addAll(chunk),
    );
    return _TestResponse(response.statusCode, responseHeaders, bytes);
  }

  Future<void> close() async {
    await server.close();
    client.close(force: true);
  }
}

final class _TestResponse {
  const _TestResponse(this.statusCode, this.headers, this.bytes);

  final int statusCode;
  final Map<String, List<String>> headers;
  final List<int> bytes;

  String get body => utf8.decode(bytes);
  Object? get json => jsonDecode(body);

  String? header(String name) => headers[name.toLowerCase()]?.join(', ');
}

final class _FakeImageFetcher implements CuratorProxyImageFetcher {
  _FakeImageFetcher({CuratorProxyImage? image})
      : image = image ??
            CuratorProxyImage(
              bytes: const [0x89, 0x50, 0x4e, 0x47],
              contentType: 'image/png',
            );

  final CuratorProxyImage image;
  final List<Uri> requestedUris = [];
  int closeCount = 0;

  @override
  Future<CuratorProxyImage> fetch(
    Uri uri, {
    required int maxBytes,
    required Duration timeout,
  }) async {
    requestedUris.add(uri);
    return image;
  }

  @override
  void close() => closeCount++;
}

final class _FakeAvifDecoder implements AvifImageDecoder {
  _FakeAvifDecoder({this.error});
  final Object? error;
  final png = Uint8List.fromList([137, 80, 78, 71, 13, 10, 26, 10]);
  int calls = 0, closeCount = 0;
  @override
  Future<Uint8List> decodeToPng(Uint8List bytes,
      {required int maxOutputBytes, required Duration timeout}) async {
    calls++;
    expect(isAvifImage(bytes), isTrue);
    if (error != null) throw error!;
    return png;
  }

  @override
  void close() => closeCount++;
}

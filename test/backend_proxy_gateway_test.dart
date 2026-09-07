import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shopitem_curator/core/contracts/backend_readiness_gateway.dart';
import 'package:shopitem_curator/core/contracts/catalog_gateways.dart';
import 'package:shopitem_curator/core/contracts/curator_use_cases.dart';
import 'package:shopitem_curator/core/models/curator_item.dart';
import 'package:shopitem_curator/core/services/backend_proxy_gateway.dart';
import 'package:shopitem_curator/core/services/scraper/target_request_policy.dart';
import 'package:test/test.dart';

void main() {
  group('BackendProxyGateway', () {
    for (final kind in TargetLookupFailure.values) {
      test('shows safe Target diagnostic ${kind.name} without retrying POST',
          () async {
        final failure = TargetLookupException(kind);
        var calls = 0;
        final gateway = BackendProxyGateway(
          backendBaseUrl: 'https://backend.test/',
          httpClient: MockClient((request) async {
            calls++;
            return _jsonResponse({
              'error': {
                'code': failure.code,
                'status': kind == TargetLookupFailure.rateLimited ? 429 : 502,
                'message': 'private-upstream-body',
              },
            }, statusCode: kind == TargetLookupFailure.rateLimited ? 429 : 502);
          }),
        );
        await expectLater(
          gateway.fetchLiveCandidates(_item('diagnostic')),
          throwsA(isA<BackendProxyException>()
              .having((error) => error.message, 'message', contains('Target'))
              .having((error) => error.toString(), 'safe message',
                  isNot(contains('private-upstream-body')))),
        );
        expect(calls, 1);
      });
    }

    test('implements every pure application port and validates configuration',
        () {
      final gateway = BackendProxyGateway(
        backendBaseUrl: 'https://backend.test/curator/',
        httpClient: MockClient((_) async => _jsonResponse(const {})),
      );

      expect(gateway, isA<ItemExtractionGateway>());
      expect(gateway, isA<BackendReadinessGateway>());
      expect(gateway, isA<TargetProductGateway>());
      expect(gateway, isA<ProductReviewGateway>());
      expect(gateway, isA<CatalogRescraper>());
      expect(gateway.backendBaseUri.toString(),
          equals('https://backend.test/curator/'));
      expect(gateway.requestTimeout, const Duration(seconds: 60));
      expect(
        () => BackendProxyGateway(backendBaseUrl: 'javascript:alert(1)'),
        throwsArgumentError,
      );
      expect(
        () => BackendProxyGateway(backendBaseUrl: 'http://backend.test'),
        throwsArgumentError,
      );
      expect(
        () => BackendProxyGateway(
          backendBaseUrl: 'https://backend.test',
          authToken: 'bad\r\ntoken',
        ),
        throwsArgumentError,
      );
    });

    test('readiness retries only safe GET transport failures', () async {
      var attempts = 0;
      final gateway = BackendProxyGateway(
        backendBaseUrl: 'https://backend.test/curator/',
        authToken: 'ready-token',
        httpClient: MockClient((request) async {
          attempts++;
          expect(request.method, 'GET');
          expect(request.url.path, '/curator/ready');
          expect(request.headers['authorization'], 'Bearer ready-token');
          if (attempts < 3) throw StateError('server is still binding');
          return _jsonResponse(const {
            'status': 'ready',
            'service': 'shopitem-curator-proxy',
            'api_version': 'v1',
            'dependencies': {'ocr': 'configured'},
          });
        }),
      );

      await gateway.waitUntilReady(
        timeout: const Duration(milliseconds: 100),
        pollInterval: const Duration(milliseconds: 1),
        attemptTimeout: const Duration(milliseconds: 20),
      );

      expect(attempts, 3);
    });

    test('readiness fails immediately for a missing local OCR configuration',
        () async {
      var attempts = 0;
      final gateway = BackendProxyGateway(
        backendBaseUrl: 'http://127.0.0.1:8787/',
        httpClient: MockClient((_) async {
          attempts++;
          return _jsonResponse(
            const {
              'status': 'not_ready',
              'service': 'shopitem-curator-proxy',
              'api_version': 'v1',
              'dependencies': {'ocr': 'not_configured'},
            },
            statusCode: 503,
          );
        }),
      );

      await expectLater(
        gateway.waitUntilReady(
          timeout: const Duration(milliseconds: 100),
          pollInterval: const Duration(milliseconds: 1),
        ),
        throwsA(
          isA<BackendProxyException>()
              .having((error) => error.statusCode, 'statusCode', 503)
              .having(
                (error) => error.kind,
                'kind',
                BackendProxyFailureKind.configuration,
              ),
        ),
      );
      expect(attempts, 1);
    });

    test('continuous readiness recovers after backend configuration changes',
        () async {
      var attempts = 0;
      final waitingFailures = <BackendProxyException>[];
      final gateway = BackendProxyGateway(
        backendBaseUrl: 'http://127.0.0.1:8787/',
        httpClient: MockClient((request) async {
          attempts++;
          expect(request.method, 'GET');
          expect(request.url.path, '/ready');
          if (attempts < 3) {
            return _jsonResponse(
              const {
                'status': 'not_ready',
                'service': 'shopitem-curator-proxy',
                'api_version': 'v1',
                'dependencies': {'ocr': 'not_configured'},
              },
              statusCode: 503,
            );
          }
          return _jsonResponse(const {
            'status': 'ready',
            'service': 'shopitem-curator-proxy',
            'api_version': 'v1',
            'dependencies': {'ocr': 'ready'},
          });
        }),
      );

      final outcome = await gateway.waitUntilReady(
        timeout: null,
        pollInterval: const Duration(milliseconds: 1),
        maximumPollInterval: const Duration(milliseconds: 2),
        attemptTimeout: const Duration(milliseconds: 20),
        retryConfigurationFailures: true,
        onWaiting: (failure) {
          waitingFailures.add(failure as BackendProxyException);
        },
      );

      expect(outcome, BackendReadinessOutcome.ready);
      expect(attempts, 3);
      expect(waitingFailures, hasLength(2));
      expect(
        waitingFailures.every(
          (failure) => failure.kind == BackendProxyFailureKind.configuration,
        ),
        isTrue,
      );
    });

    test('continuous readiness cancellation stops before another GET',
        () async {
      var attempts = 0;
      final cancelSignal = Completer<void>();
      final gateway = BackendProxyGateway(
        backendBaseUrl: 'http://127.0.0.1:8787/',
        httpClient: MockClient((request) async {
          attempts++;
          expect(request.method, 'GET');
          throw StateError('not listening');
        }),
      );

      final outcome = await gateway.waitUntilReady(
        timeout: null,
        pollInterval: const Duration(milliseconds: 1),
        maximumPollInterval: const Duration(milliseconds: 2),
        attemptTimeout: const Duration(milliseconds: 20),
        cancelSignal: cancelSignal.future,
        onWaiting: (_) {
          if (!cancelSignal.isCompleted) cancelSignal.complete();
        },
      );

      expect(outcome, BackendReadinessOutcome.cancelled);
      expect(attempts, 1);
    });

    test('timed out readiness GETs are aborted before another probe starts',
        () async {
      var attempts = 0;
      var activeRequests = 0;
      var maximumActiveRequests = 0;
      final cancelSignal = Completer<void>();
      final gateway = BackendProxyGateway(
        backendBaseUrl: 'http://127.0.0.1:8787/',
        httpClient: MockClient.streaming((request, _) async {
          attempts++;
          activeRequests++;
          if (activeRequests > maximumActiveRequests) {
            maximumActiveRequests = activeRequests;
          }
          try {
            final abortTrigger =
                (request as http.AbortableRequest).abortTrigger;
            await abortTrigger;
            throw http.RequestAbortedException(request.url);
          } finally {
            activeRequests--;
          }
        }),
      );

      final outcome = await gateway.waitUntilReady(
        timeout: null,
        pollInterval: const Duration(milliseconds: 1),
        maximumPollInterval: const Duration(milliseconds: 2),
        attemptTimeout: const Duration(milliseconds: 5),
        cancelSignal: cancelSignal.future,
        onWaiting: (_) {
          if (attempts == 3 && !cancelSignal.isCompleted) {
            cancelSignal.complete();
          }
        },
      );

      expect(outcome, BackendReadinessOutcome.cancelled);
      expect(attempts, 3);
      expect(maximumActiveRequests, 1);
      expect(activeRequests, 0);
    });

    test('readiness rejects an incompatible process on the configured port',
        () async {
      final gateway = BackendProxyGateway(
        backendBaseUrl: 'http://127.0.0.1:8787/',
        httpClient: MockClient(
          (_) async => _jsonResponse(const {'status': 'ready'}),
        ),
      );

      await expectLater(
        gateway.waitUntilReady(),
        throwsA(
          isA<BackendProxyException>().having(
            (error) => error.kind,
            'kind',
            BackendProxyFailureKind.invalidResponse,
          ),
        ),
      );
    });

    test('OCR posts bytes with auth to a prefixed endpoint and decodes schema',
        () async {
      late http.Request captured;
      final gateway = BackendProxyGateway(
        backendBaseUrl: 'https://backend.test/curator/',
        authToken: 'token-123',
        httpClient: MockClient((request) async {
          captured = request;
          return _jsonResponse({
            'items': [
              {
                'raw_name': 'Glue Stick x8',
                'clean_name': 'Glue Stick',
                'is_personal': false,
                'quantity': 8,
              },
            ],
          });
        }),
      );

      final entries = await gateway.extractItemsFromImage(
        'assets/images/list.jpg',
        imageBytes: const [1, 2, 3],
      );

      expect(captured.url.path, '/curator/v1/ocr/extract');
      expect(captured.headers['authorization'], 'Bearer token-123');
      final requestJson = jsonDecode(captured.body) as Map<String, dynamic>;
      expect(requestJson['source_image_path'], 'assets/images/list.jpg');
      expect(requestJson['image_base64'], base64Encode(const [1, 2, 3]));
      expect(entries.single.cleanName, 'Glue Stick');
      expect(entries.single.quantity, 8);
    });

    test('products preserve progress and resolve proxy paths under base prefix',
        () async {
      final proxyPath =
          '${_proxyPath('https://target.scene7.com/is/image/Target/GUEST_item')}&raster=png-v1';
      final gateway = BackendProxyGateway(
        backendBaseUrl: 'https://backend.test/curator/',
        httpClient: MockClient((request) async {
          expect(request.url.path, '/curator/v1/catalog/products');
          return _jsonResponse({
            'products': [
              _productJson(imageUrl: proxyPath),
            ],
          });
        }),
      );
      final progress = <String>[];

      final products = await gateway.fetchTargetProducts(
        const [
          ExtractedItemEntry(
            rawName: 'Glue',
            cleanName: 'Glue',
            isPersonal: false,
            quantity: 1,
          ),
        ],
        onProgress: (completed, total, item) {
          progress.add('$completed/$total:${item.cleanName}');
        },
      );

      expect(
        products.single.imageUrl,
        'https://backend.test/curator$proxyPath',
      );
      expect(progress, ['1/1:Glue']);
    });

    test('auth downloads a proxy image and returns a raster data URI',
        () async {
      final requests = <http.BaseRequest>[];
      final proxyPath =
          _proxyPath('https://target.scene7.com/is/image/Target/GUEST_item');
      final gateway = BackendProxyGateway(
        backendBaseUrl: 'https://backend.test/api/',
        authToken: 'image-token',
        httpClient: MockClient((request) async {
          requests.add(request);
          if (request.method == 'GET') {
            expect(request.url.path, '/api/v1/catalog/image');
            return http.Response.bytes(
              _tinyPng,
              200,
              headers: const {'content-type': 'image/png'},
            );
          }
          return _jsonResponse({
            'products': [_productJson(imageUrl: proxyPath)],
          });
        }),
      );

      final products = await gateway.fetchTargetProducts(const [
        ExtractedItemEntry(
          rawName: 'Glue',
          cleanName: 'Glue',
          isPersonal: false,
          quantity: 1,
        ),
      ]);

      expect(
        products.single.imageUrl,
        'data:image/png;base64,${base64Encode(_tinyPng)}',
      );
      expect(requests, hasLength(2));
      expect(
        requests.every(
          (request) => request.headers['authorization'] == 'Bearer image-token',
        ),
        isTrue,
      );
    });

    test('bundled assets and valid raster data URIs never trigger image GETs',
        () async {
      final dataUri = 'data:image/png;base64,${base64Encode(_tinyPng)}';
      var requestCount = 0;
      final gateway = BackendProxyGateway(
        backendBaseUrl: 'https://backend.test/',
        authToken: 'token',
        httpClient: MockClient((request) async {
          requestCount++;
          expect(request.method, 'POST');
          return _jsonResponse({
            'products': [
              _productJson(imageUrl: dataUri),
              {
                ..._productJson(imageUrl: 'assets/items/glue.png'),
                'id': 'product_2',
              },
            ],
          });
        }),
      );

      final products = await gateway.fetchTargetProducts(const [
        ExtractedItemEntry(
          rawName: 'Glue',
          cleanName: 'Glue',
          isPersonal: false,
          quantity: 1,
        ),
        ExtractedItemEntry(
          rawName: 'Notebook',
          cleanName: 'Notebook',
          isPersonal: false,
          quantity: 1,
        ),
      ]);

      expect(products.map((product) => product.imageUrl), [
        dataUri,
        'assets/items/glue.png',
      ]);
      expect(requestCount, 1);
    });

    test('review candidates decode and Scene7 inspection reaches backend',
        () async {
      const scene7 =
          'https://target.scene7.com:443/is/image/Target/GUEST_abc?wid=1200';
      final paths = <String>[];
      late String inspectedUrl;
      final gateway = BackendProxyGateway(
        backendBaseUrl: 'https://backend.test/',
        httpClient: MockClient((request) async {
          paths.add(request.url.path);
          if (request.url.path.endsWith('/review-candidates')) {
            return _jsonResponse({
              'candidates': [
                _candidateJson(imageUrl: 'assets/items/review.png'),
              ],
            });
          }
          final requestJson = jsonDecode(request.body) as Map<String, dynamic>;
          inspectedUrl = requestJson['url'] as String;
          return _jsonResponse(const {'candidate': null});
        }),
      );

      final candidates = await gateway.fetchLiveCandidates(_item('item_1'));
      final inspected = await gateway.fetchProductByTargetUrl(scene7);

      expect(candidates.single.id, 'candidate_1');
      expect(candidates.single.imageUrl, 'assets/items/review.png');
      expect(inspected, isNull);
      expect(
        inspectedUrl,
        'https://target.scene7.com/is/image/Target/GUEST_abc?wid=1200',
      );
      expect(paths, [
        '/v1/catalog/review-candidates',
        '/v1/catalog/inspect',
      ]);
    });

    test(
        'rescrape validates counts, restores request order, and reports progress',
        () async {
      final first = _item('first');
      final second = _item('second');
      final gateway = BackendProxyGateway(
        backendBaseUrl: 'https://backend.test/',
        httpClient: MockClient((request) async => _jsonResponse({
              'items': [second.toJson(), first.toJson()],
              'successful_item_count': 1,
              'failed_item_count': 1,
            })),
      );
      final progress = <String>[];

      final result = await gateway.rescrapeAll(
        items: [first, second],
        onProgress: (completed, total, current) {
          progress.add('$completed/$total:${current.id}');
        },
      );

      expect(result.items.map((item) => item.id), ['first', 'second']);
      expect(result.successfulItemCount, 1);
      expect(result.failedItemCount, 1);
      expect(progress, ['1/2:first', '2/2:second']);
    });

    test('rejects non-JSON, malformed schema, HTTP errors, and timeouts',
        () async {
      final nonJson = BackendProxyGateway(
        backendBaseUrl: 'https://backend.test/',
        httpClient: MockClient(
          (_) async => http.Response('<html>', 200,
              headers: const {'content-type': 'text/html'}),
        ),
      );
      await expectLater(
        nonJson.extractItemsFromImage('list.jpg', imageBytes: const [1]),
        throwsA(
          isA<BackendProxyException>().having(
            (error) => error.kind,
            'kind',
            BackendProxyFailureKind.invalidResponse,
          ),
        ),
      );

      final malformed = BackendProxyGateway(
        backendBaseUrl: 'https://backend.test/',
        httpClient: MockClient((_) async => _jsonResponse({
              'items': [
                {
                  'raw_name': 'Glue',
                  'clean_name': 'Glue',
                  'is_personal': false,
                  'quantity': 1.5,
                },
              ],
            })),
      );
      await expectLater(
        malformed.extractItemsFromImage('list.jpg', imageBytes: const [1]),
        throwsA(isA<BackendProxyException>()),
      );

      const secretBody = 'secret-upstream-diagnostics';
      const secretToken = 'secret-token';
      final httpError = BackendProxyGateway(
        backendBaseUrl: 'https://backend.test/',
        authToken: secretToken,
        httpClient: MockClient((_) async => http.Response(secretBody, 502)),
      );
      try {
        await httpError.extractItemsFromImage(
          'list.jpg',
          imageBytes: const [1],
        );
        fail('Expected an HTTP exception.');
      } on BackendProxyException catch (error) {
        expect(error.kind, BackendProxyFailureKind.httpStatus);
        expect(error.statusCode, 502);
        expect(error.toString(), isNot(contains(secretBody)));
        expect(error.toString(), isNot(contains(secretToken)));
      }

      const requestId = 'abcdef123-2';
      final unavailableModel = BackendProxyGateway(
        backendBaseUrl: 'http://127.0.0.1:8787/',
        httpClient: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'error': {
                'status': 502,
                'code': 'ocr_engine_unavailable',
                'message': 'server-controlled message is not displayed',
                'request_id': requestId,
              },
            }),
            502,
            headers: const {
              'content-type': 'application/json; charset=utf-8',
              'x-request-id': requestId,
            },
          ),
        ),
      );
      try {
        await unavailableModel.extractItemsFromImage(
          'list.jpg',
          imageBytes: const [1],
        );
        fail('Expected an unavailable-model exception.');
      } on BackendProxyException catch (error) {
        expect(error.statusCode, 502);
        expect(error.requestId, requestId);
        expect(error.message, contains('CURATOR_TESSERACT_BIN'));
        expect(error.message, contains(requestId));
        expect(error.message, isNot(contains('server-controlled message')));
      }

      final missingEndpoint = BackendProxyGateway(
        backendBaseUrl: 'http://localhost:52143/',
        httpClient: MockClient((_) async => http.Response('Not found', 404)),
      );
      try {
        await missingEndpoint.extractItemsFromImage(
          'list.jpg',
          imageBytes: const [1],
        );
        fail('Expected an HTTP exception.');
      } on BackendProxyException catch (error) {
        expect(error.statusCode, 404);
        expect(error.endpoint, '/v1/ocr/extract');
        expect(error.message, contains('CURATOR_BACKEND_URL'));
        expect(error.message, contains('reverse-proxy /v1 route'));
        expect(error.toString(), isNot(contains('Not found')));
      }

      final missingOcrEngine = BackendProxyGateway(
        backendBaseUrl: 'http://127.0.0.1:8787/',
        httpClient: MockClient((_) async => http.Response('Unavailable', 503)),
      );
      try {
        await missingOcrEngine.extractItemsFromImage(
          'list.jpg',
          imageBytes: const [1],
        );
        fail('Expected an HTTP exception.');
      } on BackendProxyException catch (error) {
        expect(error.statusCode, 503);
        expect(error.kind, BackendProxyFailureKind.configuration);
        expect(error.message, contains('Tesseract'));
        expect(error.toString(), isNot(contains('Unavailable')));
      }

      const transportSecret = 'private-transport-details';
      final unreachable = BackendProxyGateway(
        backendBaseUrl: 'http://127.0.0.1:8787/',
        httpClient: MockClient((_) async => throw StateError(transportSecret)),
      );
      try {
        await unreachable.extractItemsFromImage(
          'list.jpg',
          imageBytes: const [1],
        );
        fail('Expected a transport exception.');
      } on BackendProxyException catch (error) {
        expect(error.kind, BackendProxyFailureKind.transport);
        expect(error.message, contains('curator_proxy_server.dart'));
        expect(error.toString(), isNot(contains(transportSecret)));
      }

      final pending = Completer<http.Response>();
      final timeout = BackendProxyGateway(
        backendBaseUrl: 'https://backend.test/',
        requestTimeout: const Duration(milliseconds: 1),
        httpClient: MockClient((_) => pending.future),
      );
      await expectLater(
        timeout.extractItemsFromImage('list.jpg', imageBytes: const [1]),
        throwsA(
          isA<BackendProxyException>().having(
            (error) => error.kind,
            'kind',
            BackendProxyFailureKind.timeout,
          ),
        ),
      );
    });

    test('rejects foreign proxy URLs, non-images, and oversized images',
        () async {
      Future<void> expectImageFailure(
        BackendProxyGateway gateway,
        BackendProxyFailureKind kind,
      ) async {
        await expectLater(
          gateway.fetchTargetProducts(const [
            ExtractedItemEntry(
              rawName: 'Glue',
              cleanName: 'Glue',
              isPersonal: false,
              quantity: 1,
            ),
          ]),
          throwsA(
            isA<BackendProxyException>()
                .having((error) => error.kind, 'kind', kind),
          ),
        );
      }

      final foreign = BackendProxyGateway(
        backendBaseUrl: 'https://backend.test/',
        httpClient: MockClient((_) async => _jsonResponse({
              'products': [
                _productJson(
                  imageUrl:
                      'https://evil.test/v1/catalog/image?url=https%3A%2F%2Ftarget.scene7.com%2Fa.png',
                ),
              ],
            })),
      );
      await expectImageFailure(
        foreign,
        BackendProxyFailureKind.invalidResponse,
      );

      for (final suffix in [
        '&raster=unknown',
        '&raster=png-v1&raster=png-v1',
        '&extra=1'
      ]) {
        final gateway = BackendProxyGateway(
            backendBaseUrl: 'https://backend.test/',
            httpClient: MockClient((_) async => _jsonResponse({
                  'products': [
                    _productJson(
                        imageUrl:
                            '${_proxyPath('https://target.scene7.com/is/image/Target/GUEST_item')}$suffix')
                  ],
                })));
        addTearDown(gateway.close);
        await expectImageFailure(
            gateway, BackendProxyFailureKind.invalidResponse);
      }

      final invalidUpstream = BackendProxyGateway(
        backendBaseUrl: 'https://backend.test/',
        httpClient: MockClient((_) async => _jsonResponse({
              'products': [
                _productJson(
                  imageUrl: _proxyPath(
                    'https://images.example.test/is/image/Target/GUEST_item',
                  ),
                ),
              ],
            })),
      );
      await expectImageFailure(
        invalidUpstream,
        BackendProxyFailureKind.invalidResponse,
      );

      final proxyPath =
          _proxyPath('https://target.scene7.com/is/image/Target/GUEST_item');
      final nonImage = BackendProxyGateway(
        backendBaseUrl: 'https://backend.test/',
        authToken: 'token',
        httpClient: MockClient((request) async {
          if (request.method == 'GET') {
            return http.Response(
              'not an image',
              200,
              headers: const {'content-type': 'text/plain'},
            );
          }
          return _jsonResponse({
            'products': [_productJson(imageUrl: proxyPath)],
          });
        }),
      );
      await expectImageFailure(
        nonImage,
        BackendProxyFailureKind.invalidImage,
      );

      final oversized = BackendProxyGateway(
        backendBaseUrl: 'https://backend.test/',
        authToken: 'token',
        maxImageBytes: _tinyPng.length - 1,
        httpClient: MockClient((request) async {
          if (request.method == 'GET') {
            return http.Response.bytes(
              _tinyPng,
              200,
              headers: const {'content-type': 'image/png'},
            );
          }
          return _jsonResponse({
            'products': [_productJson(imageUrl: proxyPath)],
          });
        }),
      );
      await expectImageFailure(
        oversized,
        BackendProxyFailureKind.invalidImage,
      );
    });
  });
}

const _tinyPng = <int>[137, 80, 78, 71, 13, 10, 26, 10];

http.Response _jsonResponse(Object body, {int statusCode = 200}) {
  return http.Response(
    jsonEncode(body),
    statusCode,
    headers: const {'content-type': 'application/json; charset=utf-8'},
  );
}

String _proxyPath(String upstream) => Uri(
      path: '/v1/catalog/image',
      queryParameters: {'url': upstream},
    ).toString();

Map<String, Object> _productJson({required String imageUrl}) => {
      'id': 'product_1',
      'name': 'Glue Stick',
      'category': 'Shared',
      'is_personal': false,
      'quantity': 1,
      'price': 2.99,
      'price_currency': 'USD',
      'description': 'Target product',
      'target_url': 'https://www.target.com/p/-/A-17088992',
      'image_url': imageUrl,
    };

Map<String, Object> _candidateJson({required String imageUrl}) => {
      'id': 'candidate_1',
      'name': 'Candidate Glue',
      'price': 3.49,
      'description': 'Alternative',
      'target_url': 'https://www.target.com/p/-/A-17088992',
      'image_url': imageUrl,
    };

CuratorItem _item(String id) => CuratorItem(
      id: id,
      name: 'Glue Stick',
      category: 'Shared',
      isPersonal: false,
      quantity: 1,
      price: 2.99,
      priceCurrency: 'USD',
      description: 'Target product',
      targetUrl: 'https://www.target.com/p/-/A-17088992',
      imageUrl: 'assets/items/glue.png',
      bounds: const ItemLayoutBounds(x: 1, y: 2, width: 20, height: 30),
      polygon: const [
        CuratorPoint(1, 2),
        CuratorPoint(21, 2),
        CuratorPoint(21, 32),
      ],
      centroid: const CuratorPoint(14, 12),
      isApproved: false,
      isPreciselySegmented: true,
    );

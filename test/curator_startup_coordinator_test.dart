import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shopitem_curator/core/bloc/curator_event.dart';
import 'package:shopitem_curator/core/services/backend_proxy_gateway.dart';
import 'package:shopitem_curator/core/services/curator_startup_coordinator.dart';
import 'package:test/test.dart';

void main() {
  test('managed catalog startup does not resurrect the bundled initial image',
      () async {
    final events = <CuratorEvent>[];
    final gateway = BackendProxyGateway(
      backendBaseUrl: 'http://127.0.0.1:8787/',
      httpClient: MockClient((_) async => _jsonResponse(const {
            'status': 'ready',
            'service': 'shopitem-curator-proxy',
            'api_version': 'v1',
            'dependencies': {'ocr': 'ready'},
          })),
    );
    final coordinator = CuratorStartupCoordinator(
      backendGateway: gateway,
      dispatchEvent: events.add,
      readyEvent: const LoadSourceDocumentsEvent(selectFirst: true),
      loadSourceImage: (_) => throw StateError('must not load bundled asset'),
    );
    await coordinator.start();
    await coordinator.start();
    expect(events, hasLength(1));
    expect(events.single, isA<LoadSourceDocumentsEvent>());
  });

  test('late backend readiness submits the initial pipeline exactly once',
      () async {
    var readinessAttempts = 0;
    var imageLoads = 0;
    final methods = <String>[];
    final events = <CuratorEvent>[];
    final gateway = BackendProxyGateway(
      backendBaseUrl: 'http://127.0.0.1:8787/',
      httpClient: MockClient((request) async {
        methods.add(request.method);
        readinessAttempts++;
        if (readinessAttempts < 3) {
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
    final coordinator = CuratorStartupCoordinator(
      backendGateway: gateway,
      dispatchEvent: events.add,
      loadSourceImage: (_) async {
        imageLoads++;
        return const [1, 2, 3];
      },
      pollInterval: const Duration(milliseconds: 1),
      maximumPollInterval: const Duration(milliseconds: 2),
      attemptTimeout: const Duration(milliseconds: 20),
    );

    final firstStart = coordinator.start();
    final duplicateStart = coordinator.start();
    await Future.wait([firstStart, duplicateStart]);

    expect(methods, everyElement('GET'));
    expect(readinessAttempts, 3);
    expect(imageLoads, 1);
    expect(events.whereType<InitializationWaitingEvent>(), hasLength(2));
    final submitted = events.whereType<SelectSourceImageEvent>().toList();
    expect(submitted, hasLength(1));
    expect(submitted.single.sourceImagePath, 'assets/images/new.jpg');
    expect(submitted.single.imageBytes, const [1, 2, 3]);
  });

  test('cancelling startup during readiness never loads or submits an image',
      () async {
    final requestStarted = Completer<void>();
    final pendingResponse = Completer<http.Response>();
    var imageLoads = 0;
    final events = <CuratorEvent>[];
    final gateway = BackendProxyGateway(
      backendBaseUrl: 'http://127.0.0.1:8787/',
      httpClient: MockClient((_) {
        if (!requestStarted.isCompleted) requestStarted.complete();
        return pendingResponse.future;
      }),
    );
    final coordinator = CuratorStartupCoordinator(
      backendGateway: gateway,
      dispatchEvent: events.add,
      loadSourceImage: (_) async {
        imageLoads++;
        return const [1];
      },
      pollInterval: const Duration(milliseconds: 1),
      maximumPollInterval: const Duration(milliseconds: 2),
      attemptTimeout: const Duration(seconds: 1),
    );

    final startup = coordinator.start();
    await requestStarted.future;
    coordinator.cancel();
    await startup;

    expect(coordinator.isCancelled, isTrue);
    expect(imageLoads, 0);
    expect(events.whereType<SelectSourceImageEvent>(), isEmpty);
    expect(events.whereType<InitializationFailedEvent>(), isEmpty);
  });

  test('an incompatible readiness response remains a terminal safe failure',
      () async {
    var imageLoads = 0;
    final events = <CuratorEvent>[];
    final gateway = BackendProxyGateway(
      backendBaseUrl: 'http://127.0.0.1:8787/',
      httpClient: MockClient(
        (_) async => _jsonResponse(const {'status': 'ready'}),
      ),
    );
    final coordinator = CuratorStartupCoordinator(
      backendGateway: gateway,
      dispatchEvent: events.add,
      loadSourceImage: (_) async {
        imageLoads++;
        return const [1];
      },
      pollInterval: const Duration(milliseconds: 1),
      maximumPollInterval: const Duration(milliseconds: 2),
      attemptTimeout: const Duration(milliseconds: 20),
    );

    await coordinator.start();

    expect(imageLoads, 0);
    expect(events.whereType<SelectSourceImageEvent>(), isEmpty);
    expect(events.whereType<InitializationFailedEvent>(), hasLength(1));
  });

  test('terminal startup retry passes through readiness before one submission',
      () async {
    var readinessAttempts = 0;
    var imageLoads = 0;
    final methods = <String>[];
    final events = <CuratorEvent>[];
    final gateway = BackendProxyGateway(
      backendBaseUrl: 'http://127.0.0.1:8787/',
      httpClient: MockClient((request) async {
        methods.add(request.method);
        readinessAttempts++;
        if (readinessAttempts == 1) {
          return _jsonResponse(const {'status': 'wrong-service'});
        }
        return _jsonResponse(const {
          'status': 'ready',
          'service': 'shopitem-curator-proxy',
          'api_version': 'v1',
          'dependencies': {'ocr': 'ready'},
        });
      }),
    );
    final coordinator = CuratorStartupCoordinator(
      backendGateway: gateway,
      dispatchEvent: events.add,
      loadSourceImage: (_) async {
        imageLoads++;
        return const [4, 5, 6];
      },
      pollInterval: const Duration(milliseconds: 1),
      maximumPollInterval: const Duration(milliseconds: 2),
      attemptTimeout: const Duration(milliseconds: 20),
    );

    await coordinator.start();
    final firstRetry = coordinator.retry();
    final duplicateRetry = coordinator.retry();
    await Future.wait([firstRetry, duplicateRetry]);

    expect(methods, everyElement('GET'));
    expect(readinessAttempts, 2);
    expect(imageLoads, 1);
    expect(events.whereType<InitializationFailedEvent>(), hasLength(1));
    expect(events.whereType<InitializationRetryStartedEvent>(), hasLength(1));
    expect(events.whereType<SelectSourceImageEvent>(), hasLength(1));
  });
}

http.Response _jsonResponse(Object body, {int statusCode = 200}) {
  return http.Response(
    jsonEncode(body),
    statusCode,
    headers: const {'content-type': 'application/json; charset=utf-8'},
  );
}

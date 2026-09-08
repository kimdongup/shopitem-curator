// Pure Dart backend-proxy adapter (Zero Flutter Dependencies)

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../contracts/backend_readiness_gateway.dart';
import '../contracts/browser_project_gateway.dart';
import '../models/browser_project.dart';
import '../models/matching_options.dart';
import '../contracts/catalog_gateways.dart';
import '../contracts/curator_use_cases.dart';
import '../contracts/user_visible_failure.dart';
import '../contracts/source_document_repository.dart';
import '../models/curator_item.dart';
import '../models/target_purchase_url.dart';

/// Stable categories callers can use without inspecting transport messages.
enum BackendProxyFailureKind {
  configuration,
  timeout,
  transport,
  httpStatus,
  invalidJson,
  invalidResponse,
  invalidImage,
}

/// Sanitized failure raised by [BackendProxyGateway].
///
/// [endpoint] is always a local API path. Request URLs, authorization tokens,
/// upstream image URLs, and response bodies are deliberately omitted from
/// [toString] so telemetry cannot accidentally disclose them.
final class BackendProxyException implements Exception, UserVisibleFailure {
  const BackendProxyException({
    required this.kind,
    required this.endpoint,
    required this.message,
    this.statusCode,
    this.requestId,
    this.cause,
  });

  final BackendProxyFailureKind kind;
  final String endpoint;
  final String message;
  final int? statusCode;
  final String? requestId;
  final Object? cause;

  @override
  String get userVisibleMessage => message;

  @override
  String toString() {
    final status = statusCode == null ? '' : ' ($statusCode)';
    return 'BackendProxyException[$kind] $endpoint$status: $message';
  }
}

/// HTTP adapter for the server-side OCR and Target catalog proxy.
///
/// Core code sees only the application ports implemented here; credentials,
/// CORS-sensitive catalog requests, and authenticated image downloads remain
/// behind the backend boundary.
final class BackendProxyGateway
    implements
        BackendReadinessGateway,
        BrowserProjectGateway,
        ItemExtractionGateway,
        TargetProductGateway,
        ProductReviewGateway,
        SourceDocumentRepository,
        CatalogRescraper {
  BackendProxyGateway({
    required String backendBaseUrl,
    String? authToken,
    http.Client? httpClient,
    this.requestTimeout = const Duration(seconds: 60),
    this.maxJsonResponseBytes = 2 * 1024 * 1024,
    this.maxImageBytes = 8 * 1024 * 1024,
    MatchingOptions? matchingOptions,
  })  : _backendBaseUri = _parseBackendBaseUrl(backendBaseUrl),
        _matchingOptions = matchingOptions ?? MatchingOptions(),
        _authToken = _parseAuthToken(authToken),
        _client = httpClient ?? http.Client(),
        _ownsHttpClient = httpClient == null {
    if (requestTimeout <= Duration.zero) {
      throw ArgumentError.value(
        requestTimeout,
        'requestTimeout',
        'Must be greater than zero.',
      );
    }
    if (maxJsonResponseBytes <= 0) {
      throw ArgumentError.value(
        maxJsonResponseBytes,
        'maxJsonResponseBytes',
        'Must be greater than zero.',
      );
    }
    if (maxImageBytes <= 0) {
      throw ArgumentError.value(
        maxImageBytes,
        'maxImageBytes',
        'Must be greater than zero.',
      );
    }
  }

  @override
  Future<BrowserProject> openBrowserProject(String sourceImagePath) async =>
      BrowserProject.fromJson(await _jsonRequest('/v1/browser-projects/open',
          body: {'source_image_path': sourceImagePath}));

  @override
  Future<BrowserProject> refreshBrowserProject(String projectId) async =>
      BrowserProject.fromJson(await _jsonRequest('/v1/browser-projects/read',
          body: {'project_id': projectId}));

  @override
  Future<String> pairBrowserProject(String projectId) async =>
      (await _jsonRequest('/v1/browser-projects/pair',
          body: {'project_id': projectId}))['code'] as String;

  @override
  Future<CuratorManifest> readBrowserSelection(BrowserProject project) async {
    final items = <CuratorItem>[];
    for (final entry in project.entries.where((e) => e.status == 'selected')) {
      if (!TargetPurchaseUrl.isValid(entry.targetUrl)) {
        throw _invalidResponse(
            '/v1/browser-projects/read', 'Invalid product URL.');
      }
      final response = await _jsonRequest('/v1/browser-projects/image',
          body: {
            'project_id': project.id,
            'item_id': entry.id,
            'image_version': entry.imageVersion,
          },
          responseLimit: 3 * 1024 * 1024);
      final encoded = response['image_base64'] as String;
      final bytes = base64Decode(encoded);
      if (bytes.length > 2 * 1024 * 1024 ||
          bytes.length < 8 ||
          bytes[0] != 137 ||
          bytes[1] != 80 ||
          bytes[2] != 78 ||
          bytes[3] != 71) {
        throw _invalidResponse(
            '/v1/browser-projects/image', 'Invalid PNG crop.');
      }
      items.add(CuratorItem(
          id: entry.id,
          name: entry.name,
          category: 'Browser selection',
          isPersonal: entry.isPersonal,
          quantity: entry.quantity,
          price: entry.price,
          priceCurrency: 'USD',
          description: '사용자가 Target 페이지에서 직접 선택한 이미지 · 가격 재확인 필요',
          targetUrl: entry.targetUrl,
          imageUrl: 'data:image/png;base64,$encoded',
          bounds: const ItemLayoutBounds(x: 0, y: 0, width: 200, height: 200),
          polygon: const [],
          centroid: const CuratorPoint(100, 100),
          isPreciselySegmented: false));
    }
    // A later selection must never silently overwrite a newer snapshot.
    final latest = await refreshBrowserProject(project.id);
    if (latest.revision != project.revision) {
      throw const BackendProxyException(
          kind: BackendProxyFailureKind.invalidResponse,
          endpoint: '/v1/browser-projects/read',
          message: '선택 내용이 변경되었습니다. 새로고침 후 다시 적용해 주세요.');
    }
    return CuratorManifest(
        sourceImage: project.sourceImagePath,
        canvasWidth: 1200,
        canvasHeight: 820,
        items: items);
  }

  static const _ocrEndpoint = '/v1/ocr/extract';
  static const _readinessEndpoint = '/ready';
  static const _productsEndpoint = '/v1/catalog/products';
  static const _reviewCandidatesEndpoint = '/v1/catalog/review-candidates';
  static const _inspectEndpoint = '/v1/catalog/inspect';
  static const _rescrapeEndpoint = '/v1/catalog/rescrape';
  static const _imageEndpoint = '/v1/catalog/image';

  final Uri _backendBaseUri;
  final String? _authToken;
  final http.Client _client;
  final bool _ownsHttpClient;
  final MatchingOptions _matchingOptions;

  /// Immutable per-workflow adapter: changing UI flags cannot mutate requests
  /// already executing for another document or another browser tab.
  BackendProxyGateway withMatchingOptions(MatchingOptions options) =>
      BackendProxyGateway(
          backendBaseUrl: _backendBaseUri.toString(),
          authToken: _authToken,
          httpClient: _client,
          requestTimeout: requestTimeout,
          maxJsonResponseBytes: maxJsonResponseBytes,
          maxImageBytes: maxImageBytes,
          matchingOptions: options);

  Future<List<MatchingCapability>> matchingCapabilities() async {
    final json = await _jsonRequest('/v1/catalog/strategies', method: 'GET');
    return MatchingCapability.parse(json['strategies']);
  }

  final Duration requestTimeout;
  final int maxJsonResponseBytes;
  final int maxImageBytes;

  /// Normalized base URL. A configured path prefix is retained.
  Uri get backendBaseUri => _backendBaseUri;

  @override
  Future<List<String>> listDocuments() async {
    final json = await _jsonRequest('/v1/documents', method: 'GET');
    final documents = json['documents'];
    if (documents is! List || documents.any((value) => value is! String)) {
      throw _invalidResponse('/v1/documents', 'Invalid document list.');
    }
    return List<String>.from(documents);
  }

  @override
  Future<List<int>> readDocument(String sourceImagePath) async {
    const endpoint = '/v1/documents/read';
    final json = await _jsonRequest(endpoint,
        body: {'source_image_path': sourceImagePath},
        responseLimit: ((maxImageBytes + 2) ~/ 3) * 4 + 1024);
    try {
      final bytes = base64Decode(json['image_base64'] as String);
      if (bytes.isEmpty || bytes.length > maxImageBytes) {
        throw const FormatException();
      }
      return bytes;
    } catch (_) {
      throw _invalidResponse(endpoint, 'Invalid document image.');
    }
  }

  @override
  Future<String> importDocument(String filename, List<int> bytes) async {
    if (bytes.isEmpty || bytes.length > maxImageBytes) {
      throw const BackendProxyException(
          kind: BackendProxyFailureKind.invalidImage,
          endpoint: '/v1/documents',
          message: '8 MiB 이하의 JPEG 또는 PNG 문서를 선택하세요.');
    }
    final json = await _postJson('/v1/documents',
        {'filename': filename, 'image_base64': base64Encode(bytes)});
    final path = json['source_image_path'];
    if (path is! String || path.isEmpty) {
      throw _invalidResponse('/v1/documents', 'Invalid document path.');
    }
    return path;
  }

  @override
  Future<void> deleteDocument(String sourceImagePath) async {
    await _jsonRequest('/v1/documents',
        method: 'DELETE', body: {'source_image_path': sourceImagePath});
  }

  /// Waits for the proxy process and its required OCR configuration.
  ///
  /// Only this safe GET probe is retried during a cold start. Mutating or
  /// potentially billable POST requests are deliberately never replayed.
  @override
  Future<BackendReadinessOutcome> waitUntilReady({
    Duration? timeout = const Duration(seconds: 8),
    Duration pollInterval = const Duration(milliseconds: 200),
    Duration maximumPollInterval = const Duration(seconds: 2),
    Duration attemptTimeout = const Duration(seconds: 1),
    bool retryConfigurationFailures = false,
    Future<void>? cancelSignal,
    void Function(UserVisibleFailure failure)? onWaiting,
  }) async {
    if ((timeout != null && timeout <= Duration.zero) ||
        pollInterval <= Duration.zero ||
        maximumPollInterval < pollInterval ||
        attemptTimeout <= Duration.zero) {
      throw ArgumentError(
        'Readiness durations must be positive and the maximum poll interval '
        'must not be shorter than the initial interval.',
      );
    }

    final cancellation = _ReadinessCancellationRelay(cancelSignal);
    if (cancellation.isCancelled) {
      return BackendReadinessOutcome.cancelled;
    }

    final stopwatch = Stopwatch()..start();
    BackendProxyException? lastTransientFailure;
    var currentPollInterval = pollInterval;
    while (timeout == null || stopwatch.elapsed < timeout) {
      final remaining = timeout == null ? null : timeout - stopwatch.elapsed;
      final currentAttemptTimeout =
          remaining == null || remaining > attemptTimeout
              ? attemptTimeout
              : remaining;
      try {
        final outcome = await _runReadinessAttempt(
          currentAttemptTimeout,
          cancellation,
        );
        if (outcome == BackendReadinessOutcome.cancelled) return outcome;
        return BackendReadinessOutcome.ready;
      } on BackendProxyException catch (error) {
        final isRetryable = _isTransientReadinessFailure(error) ||
            (retryConfigurationFailures &&
                error.kind == BackendProxyFailureKind.configuration);
        if (!isRetryable) rethrow;
        lastTransientFailure = error;
        onWaiting?.call(error);
      }

      final delayRemaining =
          timeout == null ? null : timeout - stopwatch.elapsed;
      if (delayRemaining != null && delayRemaining <= Duration.zero) break;
      final delay =
          delayRemaining == null || delayRemaining > currentPollInterval
              ? currentPollInterval
              : delayRemaining;
      if (await _waitForDelayOrCancellation(delay, cancellation)) {
        return BackendReadinessOutcome.cancelled;
      }
      currentPollInterval = _nextPollInterval(
        currentPollInterval,
        maximumPollInterval,
      );
    }

    throw BackendProxyException(
      kind: BackendProxyFailureKind.timeout,
      endpoint: _readinessEndpoint,
      message: 'Curator proxy did not become ready in time. Start '
          '`dart run server/curator_proxy_server.dart` and verify '
          'the server OCR credential.',
      cause: lastTransientFailure,
    );
  }

  Future<BackendReadinessOutcome> _runReadinessAttempt(
    Duration timeout,
    _ReadinessCancellationRelay cancellation,
  ) async {
    if (cancellation.isCancelled) {
      return BackendReadinessOutcome.cancelled;
    }

    final abortTrigger = Completer<void>();
    final timeoutSignal = Completer<_ReadinessAttemptSignal>();
    final cancellationSignal = Completer<_ReadinessAttemptSignal>();
    var timedOut = false;

    void abortRequest() {
      if (!abortTrigger.isCompleted) abortTrigger.complete();
    }

    final timer = Timer(timeout, () {
      timedOut = true;
      abortRequest();
      if (!timeoutSignal.isCompleted) {
        timeoutSignal.complete(_ReadinessAttemptSignal.timedOut);
      }
    });
    final removeCancellationListener = cancellation.addListener(() {
      abortRequest();
      if (!cancellationSignal.isCompleted) {
        cancellationSignal.complete(_ReadinessAttemptSignal.cancelled);
      }
    });
    final request = _checkReadiness(abortTrigger.future)
        .then((_) => _ReadinessAttemptSignal.ready);

    try {
      late final _ReadinessAttemptSignal signal;
      try {
        signal = await Future.any([
          request,
          timeoutSignal.future,
          cancellationSignal.future,
        ]);
      } on http.RequestAbortedException catch (cause) {
        if (cancellation.isCancelled) {
          return BackendReadinessOutcome.cancelled;
        }
        if (timedOut) throw _readinessTimeout(cause);
        rethrow;
      }

      if (signal == _ReadinessAttemptSignal.cancelled) {
        return BackendReadinessOutcome.cancelled;
      }
      if (signal == _ReadinessAttemptSignal.timedOut) {
        // BrowserClient and IOClient honour AbortableRequest. Do not start the
        // next probe until the previous request has actually terminated, so a
        // stalled reverse proxy cannot accumulate overlapping `/ready` GETs.
        try {
          await request;
        } on Object catch (cause) {
          throw _readinessTimeout(cause);
        }
        throw _readinessTimeout();
      }
      return BackendReadinessOutcome.ready;
    } finally {
      timer.cancel();
      removeCancellationListener();
    }
  }

  Future<bool> _waitForDelayOrCancellation(
    Duration delay,
    _ReadinessCancellationRelay cancellation,
  ) async {
    if (cancellation.isCancelled) return true;

    final result = Completer<bool>();
    final timer = Timer(delay, () {
      if (!result.isCompleted) result.complete(false);
    });
    final removeCancellationListener = cancellation.addListener(() {
      timer.cancel();
      if (!result.isCompleted) result.complete(true);
    });
    try {
      return await result.future;
    } finally {
      timer.cancel();
      removeCancellationListener();
    }
  }

  BackendProxyException _readinessTimeout([Object? cause]) {
    return BackendProxyException(
      kind: BackendProxyFailureKind.timeout,
      endpoint: _readinessEndpoint,
      message: 'Curator proxy readiness check timed out.',
      cause: cause,
    );
  }

  static Duration _nextPollInterval(Duration current, Duration maximum) {
    final doubled = Duration(microseconds: current.inMicroseconds * 2);
    return doubled > maximum ? maximum : doubled;
  }

  @override
  Future<List<ExtractedItemEntry>> extractItemsFromImage(
    String imagePath, {
    List<int>? imageBytes,
  }) async {
    final sourcePath = imagePath.trim();
    if (sourcePath.isEmpty || _containsControlCharacter(sourcePath)) {
      throw ArgumentError.value(
        imagePath,
        'imagePath',
        'Must be a non-empty safe path.',
      );
    }
    if (imageBytes == null || imageBytes.isEmpty) {
      throw ArgumentError.value(
        imageBytes,
        'imageBytes',
        'Backend OCR requires the source image bytes.',
      );
    }
    if (imageBytes.length > maxImageBytes ||
        imageBytes.any((byte) => byte < 0 || byte > 255)) {
      throw ArgumentError.value(
        imageBytes.length,
        'imageBytes',
        'Image bytes are invalid or exceed the configured limit.',
      );
    }

    final payload = await _postJson(
      _ocrEndpoint,
      {
        'source_image_path': sourcePath,
        'image_base64': base64Encode(imageBytes),
      },
    );
    final rawItems = _requiredList(payload, const ['items'], _ocrEndpoint);
    if (rawItems.isEmpty) {
      throw _invalidResponse(
        _ocrEndpoint,
        'items must contain at least one entry.',
      );
    }

    final items = <ExtractedItemEntry>[];
    for (var index = 0; index < rawItems.length; index++) {
      final item = _requiredMap(
        rawItems[index],
        _ocrEndpoint,
        'items[$index]',
      );
      items.add(
        ExtractedItemEntry(
          rawName: _requiredString(
            item,
            const ['raw_name', 'rawName'],
            _ocrEndpoint,
          ),
          cleanName: _requiredString(
            item,
            const ['clean_name', 'cleanName'],
            _ocrEndpoint,
          ),
          isPersonal: _requiredBool(
            item,
            const ['is_personal', 'isPersonal'],
            _ocrEndpoint,
          ),
          quantity: _requiredInteger(
            item,
            const ['quantity'],
            _ocrEndpoint,
            minimum: 1,
          ),
        ),
      );
    }
    return List.unmodifiable(items);
  }

  @override
  Future<List<TargetProductData>> fetchTargetProducts(
    List<ExtractedItemEntry> entries, {
    void Function(int completed, int total, ExtractedItemEntry currentItem)?
        onProgress,
  }) async {
    if (entries.isEmpty) return const [];
    if (!_matchingOptions.isDefault && entries.length > 1) {
      final products = <TargetProductData>[];
      for (var i = 0; i < entries.length; i++) {
        final product = (await fetchTargetProducts([entries[i]])).single;
        products.add(TargetProductData(
            id: 'item_${i + 1}',
            name: product.name,
            category: product.category,
            isPersonal: product.isPersonal,
            quantity: product.quantity,
            price: product.price,
            priceCurrency: product.priceCurrency,
            description: product.description,
            targetUrl: product.targetUrl,
            imageUrl: product.imageUrl));
        onProgress?.call(i + 1, entries.length, entries[i]);
      }
      return List.unmodifiable(products);
    }

    final payload = await _postJson(
      _productsEndpoint,
      {
        'items': entries.map(_encodeExtractedEntry).toList(growable: false),
      },
    );
    final rawProducts =
        _requiredList(payload, const ['products'], _productsEndpoint);
    if (rawProducts.length != entries.length) {
      throw _invalidResponse(
        _productsEndpoint,
        'products length must match the request.',
      );
    }

    final products = <TargetProductData>[];
    final seenIds = <String>{};
    for (var index = 0; index < rawProducts.length; index++) {
      final map = _requiredMap(
        rawProducts[index],
        _productsEndpoint,
        'products[$index]',
      );
      final product = await _decodeProduct(map);
      if (!seenIds.add(product.id)) {
        throw _invalidResponse(
          _productsEndpoint,
          'products contains a duplicate id.',
        );
      }
      products.add(product);
      onProgress?.call(index + 1, entries.length, entries[index]);
    }
    return List.unmodifiable(products);
  }

  @override
  Future<List<TargetProductCandidate>> fetchLiveCandidates(
    CuratorItem item,
  ) async {
    final payload = await _postJson(
      _reviewCandidatesEndpoint,
      {'item': item.toJson()},
    );
    final rawCandidates = _requiredList(
      payload,
      const ['candidates'],
      _reviewCandidatesEndpoint,
    );
    final candidates = <TargetProductCandidate>[];
    final seenIds = <String>{};
    for (var index = 0; index < rawCandidates.length; index++) {
      final map = _requiredMap(
        rawCandidates[index],
        _reviewCandidatesEndpoint,
        'candidates[$index]',
      );
      final candidate = await _decodeCandidate(
        map,
        _reviewCandidatesEndpoint,
      );
      if (!seenIds.add(candidate.id)) {
        throw _invalidResponse(
          _reviewCandidatesEndpoint,
          'candidates contains a duplicate id.',
        );
      }
      candidates.add(candidate);
    }
    return List.unmodifiable(candidates);
  }

  @override
  Future<TargetProductCandidate?> fetchProductByTargetUrl(String url) async {
    final inspectionUrl = _normalizeInspectionUrl(url);
    if (inspectionUrl == null) return null;

    final payload = await _postJson(
      _inspectEndpoint,
      {'url': inspectionUrl},
    );
    if (!_containsAnyKey(payload, const ['candidate'])) {
      throw _invalidResponse(
        _inspectEndpoint,
        'Missing required candidate field.',
      );
    }
    final rawCandidate = _valueForKeys(payload, const ['candidate']);
    if (rawCandidate == null) return null;

    return _decodeCandidate(
      _requiredMap(rawCandidate, _inspectEndpoint, 'candidate'),
      _inspectEndpoint,
    );
  }

  @override
  Future<CatalogRescrapeResult> rescrapeAll({
    required List<CuratorItem> items,
    CatalogRescrapeProgressCallback? onProgress,
  }) async {
    if (items.isEmpty) {
      return CatalogRescrapeResult(
        items: const [],
        successfulItemCount: 0,
        failedItemCount: 0,
      );
    }

    final inputIds = <String>{};
    for (final item in items) {
      if (item.id.trim().isEmpty || !inputIds.add(item.id)) {
        throw ArgumentError.value(
          item.id,
          'items',
          'Every item must have a unique non-empty id.',
        );
      }
    }

    if (!_matchingOptions.isDefault && items.length > 1) {
      final combined = <CuratorItem>[];
      var succeeded = 0, failed = 0;
      for (var i = 0; i < items.length; i++) {
        final result = await rescrapeAll(items: [items[i]]);
        combined.addAll(result.items);
        succeeded += result.successfulItemCount;
        failed += result.failedItemCount;
        onProgress?.call(i + 1, items.length, items[i]);
      }
      return CatalogRescrapeResult(
          items: combined,
          successfulItemCount: succeeded,
          failedItemCount: failed);
    }

    final payload = await _postJson(
      _rescrapeEndpoint,
      {'items': items.map((item) => item.toJson()).toList(growable: false)},
    );
    final rawItems = _requiredList(payload, const ['items'], _rescrapeEndpoint);
    final successfulItemCount = _requiredInteger(
      payload,
      const ['successful_item_count', 'successfulItemCount'],
      _rescrapeEndpoint,
      minimum: 0,
    );
    final failedItemCount = _requiredInteger(
      payload,
      const ['failed_item_count', 'failedItemCount'],
      _rescrapeEndpoint,
      minimum: 0,
    );
    if (rawItems.length != items.length ||
        successfulItemCount + failedItemCount != items.length) {
      throw _invalidResponse(
        _rescrapeEndpoint,
        'items and result counts must match the request.',
      );
    }

    final decodedById = <String, CuratorItem>{};
    for (var index = 0; index < rawItems.length; index++) {
      final decoded = await _decodeCuratorItem(
        _requiredMap(
          rawItems[index],
          _rescrapeEndpoint,
          'items[$index]',
        ),
      );
      if (!inputIds.contains(decoded.id) ||
          decodedById.putIfAbsent(decoded.id, () => decoded) != decoded) {
        throw _invalidResponse(
          _rescrapeEndpoint,
          'items contains an unknown or duplicate id.',
        );
      }
    }

    final ordered = <CuratorItem>[];
    for (var index = 0; index < items.length; index++) {
      final decoded = decodedById[items[index].id];
      if (decoded == null) {
        throw _invalidResponse(
          _rescrapeEndpoint,
          'items is missing a requested id.',
        );
      }
      ordered.add(decoded);
      onProgress?.call(index + 1, items.length, items[index]);
    }

    return CatalogRescrapeResult(
      items: ordered,
      successfulItemCount: successfulItemCount,
      failedItemCount: failedItemCount,
    );
  }

  /// Closes only a client created by this gateway. Injected clients remain
  /// owned by the application composition root.
  void close() {
    if (_ownsHttpClient) _client.close();
  }

  Future<void> _checkReadiness(Future<void> abortTrigger) async {
    late final http.Response response;
    try {
      final request = http.AbortableRequest(
        'GET',
        _endpointUri(_readinessEndpoint),
        abortTrigger: abortTrigger,
      )..headers.addAll({
          'Accept': 'application/json',
          if (_authToken != null) 'Authorization': 'Bearer $_authToken',
        });
      response = await http.Response.fromStream(await _client.send(request));
    } on http.RequestAbortedException {
      rethrow;
    } on Object catch (cause) {
      throw BackendProxyException(
        kind: BackendProxyFailureKind.transport,
        endpoint: _readinessEndpoint,
        message: 'Curator proxy is not accepting connections yet.',
        cause: cause,
      );
    }

    if (response.statusCode == 200) {
      final payload = _decodeReadinessPayload(response);
      if (payload['status'] != 'ready' ||
          payload['service'] != 'shopitem-curator-proxy' ||
          payload['api_version'] != 'v1') {
        throw _invalidResponse(
          _readinessEndpoint,
          'Readiness response identifies an incompatible backend.',
        );
      }
      return;
    }

    final isMissingOcrConfiguration = response.statusCode == 503 &&
        _readinessReportsMissingOcrConfiguration(response);
    throw BackendProxyException(
      kind: isMissingOcrConfiguration
          ? BackendProxyFailureKind.configuration
          : BackendProxyFailureKind.httpStatus,
      endpoint: _readinessEndpoint,
      statusCode: response.statusCode,
      message: switch (response.statusCode) {
        404 => 'Curator readiness endpoint was not found. Check '
            'CURATOR_BACKEND_URL or the reverse-proxy /ready route.',
        401 || 403 => 'Authentication is required before Curator can start.',
        503 when isMissingOcrConfiguration =>
          '서버의 Tesseract 엔진과 OCR 언어 데이터를 확인하세요.',
        _ => 'Curator backend is not ready.',
      },
    );
  }

  Map<String, dynamic> _decodeReadinessPayload(http.Response response) {
    const maximumBytes = 16 * 1024;
    _validateDeclaredLength(response, maximumBytes, _readinessEndpoint);
    if (response.bodyBytes.length > maximumBytes ||
        !_isJsonMime(_responseContentType(response))) {
      throw _invalidResponse(
        _readinessEndpoint,
        'Readiness response must be a small JSON object.',
      );
    }
    try {
      final source = utf8.decode(response.bodyBytes, allowMalformed: false);
      return _requiredMap(
        jsonDecode(source),
        _readinessEndpoint,
        'response',
      );
    } on BackendProxyException {
      rethrow;
    } on FormatException catch (cause) {
      throw BackendProxyException(
        kind: BackendProxyFailureKind.invalidJson,
        endpoint: _readinessEndpoint,
        message: 'Readiness response contained malformed JSON.',
        cause: cause,
      );
    }
  }

  bool _readinessReportsMissingOcrConfiguration(http.Response response) {
    try {
      final payload = _decodeReadinessPayload(response);
      final dependencies = payload['dependencies'];
      return dependencies is Map && dependencies['ocr'] == 'not_configured';
    } on BackendProxyException {
      return false;
    }
  }

  static bool _isTransientReadinessFailure(BackendProxyException error) {
    return error.kind == BackendProxyFailureKind.transport ||
        error.kind == BackendProxyFailureKind.timeout ||
        error.statusCode == 502 ||
        error.statusCode == 504 ||
        (error.statusCode == 503 &&
            error.kind != BackendProxyFailureKind.configuration);
  }

  Map<String, Object> _encodeExtractedEntry(ExtractedItemEntry entry) {
    final rawName = entry.rawName.trim();
    final cleanName = entry.cleanName.trim();
    if (rawName.isEmpty ||
        cleanName.isEmpty ||
        _containsControlCharacter(rawName) ||
        _containsControlCharacter(cleanName) ||
        entry.quantity < 1) {
      throw ArgumentError.value(
        entry,
        'entries',
        'Each entry must contain safe names and a positive quantity.',
      );
    }
    return {
      'raw_name': rawName,
      'clean_name': cleanName,
      'is_personal': entry.isPersonal,
      'quantity': entry.quantity,
    };
  }

  Future<TargetProductData> _decodeProduct(Map<String, dynamic> map) async {
    final targetUrl = _validatedTargetUrl(
      _requiredString(
        map,
        const ['target_url', 'targetUrl'],
        _productsEndpoint,
        allowEmpty: true,
      ),
      _productsEndpoint,
    );
    final imageUrl = await _normalizeImageSource(
      _requiredString(
        map,
        const ['image_url', 'imageUrl'],
        _productsEndpoint,
        allowEmpty: true,
      ),
      endpoint: _productsEndpoint,
      allowEmpty: true,
    );
    return TargetProductData(
      id: _requiredString(map, const ['id'], _productsEndpoint),
      name: _requiredString(map, const ['name'], _productsEndpoint),
      category: _requiredString(map, const ['category'], _productsEndpoint),
      isPersonal: _requiredBool(
        map,
        const ['is_personal', 'isPersonal'],
        _productsEndpoint,
      ),
      quantity: _requiredInteger(
        map,
        const ['quantity'],
        _productsEndpoint,
        minimum: 1,
      ),
      price: _requiredFiniteDouble(
        map,
        const ['price'],
        _productsEndpoint,
        minimum: 0,
      ),
      priceCurrency: _requiredString(
        map,
        const ['price_currency', 'priceCurrency'],
        _productsEndpoint,
      ),
      description: _requiredString(
        map,
        const ['description'],
        _productsEndpoint,
        allowEmpty: true,
      ),
      targetUrl: targetUrl,
      imageUrl: imageUrl,
    );
  }

  Future<TargetProductCandidate> _decodeCandidate(
    Map<String, dynamic> map,
    String endpoint,
  ) async {
    final targetUrl = _validatedTargetUrl(
      _requiredString(
        map,
        const ['target_url', 'targetUrl'],
        endpoint,
        allowEmpty: true,
      ),
      endpoint,
    );
    final imageUrl = await _normalizeImageSource(
      _requiredString(
        map,
        const ['image_url', 'imageUrl'],
        endpoint,
      ),
      endpoint: endpoint,
    );
    return TargetProductCandidate(
      id: _requiredString(map, const ['id'], endpoint),
      name: _requiredString(map, const ['name'], endpoint),
      price: _requiredFiniteDouble(
        map,
        const ['price'],
        endpoint,
        minimum: 0,
      ),
      imageUrl: imageUrl,
      targetUrl: targetUrl,
      description: _requiredString(
        map,
        const ['description'],
        endpoint,
        allowEmpty: true,
      ),
    );
  }

  Future<CuratorItem> _decodeCuratorItem(Map<String, dynamic> map) async {
    const endpoint = _rescrapeEndpoint;
    final rawBounds = _requiredMap(
      _requiredValue(map, const ['bounds'], endpoint),
      endpoint,
      'bounds',
    );
    final bounds = ItemLayoutBounds(
      x: _requiredFiniteDouble(
        rawBounds,
        const ['x'],
        endpoint,
        minimum: 0,
      ),
      y: _requiredFiniteDouble(
        rawBounds,
        const ['y'],
        endpoint,
        minimum: 0,
      ),
      width: _requiredFiniteDouble(
        rawBounds,
        const ['width'],
        endpoint,
        exclusiveMinimum: 0,
      ),
      height: _requiredFiniteDouble(
        rawBounds,
        const ['height'],
        endpoint,
        exclusiveMinimum: 0,
      ),
    );

    var polygon = _decodePointList(
      _requiredValue(map, const ['polygon'], endpoint),
      endpoint,
      'polygon',
    );
    final rawContours = _requiredList(map, const ['contours'], endpoint);
    final contours = <List<CuratorPoint>>[];
    for (var index = 0; index < rawContours.length; index++) {
      contours.add(
        _decodePointList(
          rawContours[index],
          endpoint,
          'contours[$index]',
        ),
      );
    }
    if (polygon.isEmpty && contours.isNotEmpty) {
      polygon = List<CuratorPoint>.of(contours.first);
    }

    final centroid = _decodePoint(
      _requiredValue(map, const ['centroid'], endpoint),
      endpoint,
      'centroid',
    );
    final targetUrl = _validatedTargetUrl(
      _requiredString(
        map,
        const ['target_url', 'targetUrl'],
        endpoint,
        allowEmpty: true,
      ),
      endpoint,
    );
    final imageUrl = await _normalizeImageSource(
      _requiredString(
        map,
        const ['image_url', 'imageUrl'],
        endpoint,
        allowEmpty: true,
      ),
      endpoint: endpoint,
      allowEmpty: true,
    );

    return CuratorItem(
      id: _requiredString(map, const ['id'], endpoint),
      name: _requiredString(map, const ['name'], endpoint),
      category: _requiredString(map, const ['category'], endpoint),
      isPersonal: _requiredBool(
        map,
        const ['is_personal', 'isPersonal'],
        endpoint,
      ),
      quantity: _requiredInteger(
        map,
        const ['quantity'],
        endpoint,
        minimum: 1,
      ),
      price: _requiredFiniteDouble(
        map,
        const ['price'],
        endpoint,
        minimum: 0,
      ),
      priceCurrency: _requiredString(
        map,
        const ['price_currency', 'priceCurrency'],
        endpoint,
      ),
      description: _requiredString(
        map,
        const ['description'],
        endpoint,
        allowEmpty: true,
      ),
      targetUrl: targetUrl,
      imageUrl: imageUrl,
      bounds: bounds,
      polygon: polygon,
      contours: contours,
      centroid: centroid,
      isApproved: _requiredBool(
        map,
        const ['is_approved', 'isApproved'],
        endpoint,
      ),
      isPreciselySegmented: _requiredBool(
        map,
        const ['is_precisely_segmented', 'isPreciselySegmented'],
        endpoint,
      ),
    );
  }

  List<CuratorPoint> _decodePointList(
    Object? value,
    String endpoint,
    String field,
  ) {
    if (value is! List) {
      throw _invalidResponse(endpoint, '$field must be an array.');
    }
    return List<CuratorPoint>.unmodifiable([
      for (var index = 0; index < value.length; index++)
        _decodePoint(value[index], endpoint, '$field[$index]'),
    ]);
  }

  CuratorPoint _decodePoint(
    Object? value,
    String endpoint,
    String field,
  ) {
    if (value is! List || value.length != 2) {
      throw _invalidResponse(endpoint, '$field must contain two numbers.');
    }
    final x = _finiteNumber(value[0], endpoint, '$field[0]');
    final y = _finiteNumber(value[1], endpoint, '$field[1]');
    return CuratorPoint(x, y);
  }

  String _validatedTargetUrl(String raw, String endpoint) {
    if (raw.isEmpty) return '';
    final parsed = TargetPurchaseUrl.tryParse(raw);
    if (parsed == null) {
      throw _invalidResponse(
        endpoint,
        'target_url must be an approved Target product URL.',
      );
    }
    return parsed.value;
  }

  static String? _normalizeInspectionUrl(String raw) {
    final source = raw.trim();
    final purchaseUrl = TargetPurchaseUrl.tryParse(source);
    if (purchaseUrl != null) return purchaseUrl.value;
    if (source.isEmpty || _containsControlCharacter(source)) return null;

    final uri = Uri.tryParse(source);
    if (uri == null || !_isAllowedScene7ImageUri(uri)) return null;
    return uri.toString();
  }

  static bool _isAllowedScene7ImageUri(Uri uri) {
    if (uri.scheme.toLowerCase() != 'https' ||
        uri.host.toLowerCase() != 'target.scene7.com' ||
        uri.userInfo.isNotEmpty ||
        (uri.hasPort && uri.port != 443) ||
        uri.hasFragment ||
        !uri.path.startsWith('/is/image/Target/')) {
      return false;
    }
    final imageId = uri.path.substring('/is/image/Target/'.length);
    return imageId.isNotEmpty &&
        !uri.pathSegments.any((segment) => segment == '.' || segment == '..');
  }

  Future<String> _normalizeImageSource(
    String raw, {
    required String endpoint,
    bool allowEmpty = false,
  }) async {
    final source = raw.trim();
    if (source.isEmpty) {
      if (allowEmpty) return '';
      throw _invalidResponse(endpoint, 'image_url must not be empty.');
    }
    if (_containsControlCharacter(source)) {
      throw _invalidResponse(endpoint, 'image_url contains unsafe text.');
    }

    if (source.startsWith('assets/')) {
      final uri = Uri.tryParse(source);
      final segments = source.split('/');
      if (uri == null ||
          uri.hasAuthority ||
          uri.hasQuery ||
          uri.hasFragment ||
          source.contains(r'\') ||
          segments.any((segment) =>
              segment.isEmpty || segment == '.' || segment == '..')) {
        throw _invalidResponse(endpoint, 'image_url has an unsafe asset path.');
      }
      return source;
    }

    if (source.startsWith('data:')) {
      return _validateDataImage(source, endpoint);
    }

    final uri = Uri.tryParse(source);
    if (uri == null) {
      throw _invalidResponse(endpoint, 'image_url is not a valid URI.');
    }
    final proxyUri = _resolveAndValidateProxyUri(uri, endpoint);
    if (_authToken == null) return proxyUri.toString();
    return _fetchAuthenticatedImage(proxyUri, endpoint);
  }

  String _validateDataImage(String source, String endpoint) {
    try {
      final data = Uri.parse(source).data;
      if (data == null || !data.isBase64) {
        throw const FormatException('Not base64 image data.');
      }
      final mime = _normalizeRasterMime(data.mimeType);
      if (mime == null) {
        throw const FormatException('Unsupported image MIME type.');
      }
      final bytes = data.contentAsBytes();
      if (bytes.isEmpty || bytes.length > maxImageBytes) {
        throw const FormatException('Invalid image byte length.');
      }
      if (!_matchesRasterSignature(bytes, mime)) {
        throw const FormatException('Image signature does not match MIME.');
      }
      return source;
    } on FormatException catch (cause) {
      throw BackendProxyException(
        kind: BackendProxyFailureKind.invalidImage,
        endpoint: endpoint,
        message: 'image_url contains invalid inline image data.',
        cause: cause,
      );
    }
  }

  Uri _resolveAndValidateProxyUri(Uri uri, String endpoint) {
    late final Uri resolved;
    if (!uri.hasScheme) {
      if (uri.hasAuthority || !uri.path.startsWith('/')) {
        throw _invalidResponse(
          endpoint,
          'image_url must be an absolute proxy path.',
        );
      }
      // A server response uses the portable `/v1/...` form. Resolve it as a
      // path relative to the configured deployment root so a base such as
      // `https://example.test/curator/` keeps `/curator/`.
      resolved = _backendBaseUri.resolve(uri.toString().substring(1));
    } else {
      if ((uri.scheme != 'http' && uri.scheme != 'https') ||
          uri.userInfo.isNotEmpty ||
          !_isSameOrigin(uri, _originUri)) {
        throw _invalidResponse(
          endpoint,
          'image_url must use the configured backend origin.',
        );
      }
      resolved = uri;
    }

    final query = resolved.queryParametersAll;
    final upstreamValues = query['url'];
    final raster = query['raster'];
    if (resolved.path != _endpointUri(_imageEndpoint).path ||
        resolved.hasFragment ||
        query.keys.any((key) => key != 'url' && key != 'raster') ||
        (raster != null && (raster.length != 1 || raster.single != 'png-v1')) ||
        upstreamValues == null ||
        upstreamValues.length != 1 ||
        upstreamValues.single.trim().isEmpty) {
      throw _invalidResponse(
        endpoint,
        'image_url must use the catalog image proxy contract.',
      );
    }
    final upstream = Uri.tryParse(upstreamValues.single);
    if (upstream == null || !_isAllowedScene7ImageUri(upstream)) {
      throw _invalidResponse(
        endpoint,
        'image_url contains an invalid upstream image URL.',
      );
    }
    return resolved;
  }

  Future<String> _fetchAuthenticatedImage(Uri uri, String endpoint) async {
    late final http.Response response;
    try {
      response = await _client.get(
        uri,
        headers: {
          'Accept': 'image/png,image/jpeg,image/webp,image/gif,image/avif',
          'Authorization': 'Bearer $_authToken',
        },
      ).timeout(requestTimeout);
    } on TimeoutException catch (cause) {
      throw BackendProxyException(
        kind: BackendProxyFailureKind.timeout,
        endpoint: endpoint,
        message: 'Image proxy request timed out.',
        cause: cause,
      );
    } on Object catch (cause) {
      throw BackendProxyException(
        kind: BackendProxyFailureKind.transport,
        endpoint: endpoint,
        message: 'Image proxy request failed.',
        cause: cause,
      );
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw BackendProxyException(
        kind: BackendProxyFailureKind.httpStatus,
        endpoint: endpoint,
        message: 'Image proxy returned a non-success status.',
        statusCode: response.statusCode,
      );
    }
    _validateDeclaredLength(response, maxImageBytes, endpoint);

    final mime = _normalizeRasterMime(_responseContentType(response));
    final bytes = response.bodyBytes;
    if (mime == null ||
        bytes.isEmpty ||
        bytes.length > maxImageBytes ||
        !_matchesRasterSignature(bytes, mime)) {
      throw BackendProxyException(
        kind: BackendProxyFailureKind.invalidImage,
        endpoint: endpoint,
        message: 'Image proxy returned invalid or unsupported image data.',
      );
    }
    return 'data:$mime;base64,${base64Encode(bytes)}';
  }

  Future<Map<String, dynamic>> _postJson(
    String endpoint,
    Map<String, Object?> body,
  ) =>
      _jsonRequest(endpoint, body: body);

  Future<Map<String, dynamic>> _jsonRequest(
    String endpoint, {
    String method = 'POST',
    Map<String, Object?> body = const {},
    int? responseLimit,
  }) async {
    late final http.Response response;
    try {
      final request = http.Request(method, _endpointUri(endpoint))
        ..headers.addAll({
          'Accept': 'application/json',
          'Content-Type': 'application/json; charset=utf-8',
          if (_authToken != null) 'Authorization': 'Bearer $_authToken',
        });
      if (method != 'GET') {
        request.body = jsonEncode({
          ...body,
          if (endpoint.startsWith('/v1/catalog/') &&
              !_matchingOptions.isDefault)
            'matching_options': _matchingOptions.toJson(),
        });
      }
      response = await _client
          .send(request)
          .then(http.Response.fromStream)
          .timeout(requestTimeout);
    } on TimeoutException catch (cause) {
      throw BackendProxyException(
        kind: BackendProxyFailureKind.timeout,
        endpoint: endpoint,
        message: 'Backend request timed out.',
        cause: cause,
      );
    } on Object catch (cause) {
      throw BackendProxyException(
        kind: BackendProxyFailureKind.transport,
        endpoint: endpoint,
        message: 'Curator proxy is unreachable. Start '
            '`dart run server/curator_proxy_server.dart` before Flutter and '
            'check CURATOR_BACKEND_URL.',
        cause: cause,
      );
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      final errorMetadata = _safeErrorMetadata(response);
      throw BackendProxyException(
        kind: response.statusCode == 503 && endpoint == _ocrEndpoint
            ? BackendProxyFailureKind.configuration
            : BackendProxyFailureKind.httpStatus,
        endpoint: endpoint,
        message: _backendErrorMessage(
          response.statusCode,
          endpoint,
          errorMetadata,
        ),
        statusCode: response.statusCode,
        requestId: errorMetadata.requestId,
      );
    }
    final limit = responseLimit ?? maxJsonResponseBytes;
    _validateDeclaredLength(response, limit, endpoint);
    if (response.bodyBytes.length > limit) {
      throw _invalidResponse(endpoint, 'JSON response exceeds the size limit.');
    }

    final contentType = _responseContentType(response);
    if (!_isJsonMime(contentType)) {
      throw _invalidResponse(
        endpoint,
        'Backend response must use a JSON content type.',
      );
    }

    late final String source;
    try {
      source = utf8.decode(response.bodyBytes, allowMalformed: false);
    } on FormatException catch (cause) {
      throw BackendProxyException(
        kind: BackendProxyFailureKind.invalidJson,
        endpoint: endpoint,
        message: 'Backend returned invalid UTF-8 JSON.',
        cause: cause,
      );
    }

    late final Object? decoded;
    try {
      decoded = jsonDecode(source);
    } on FormatException catch (cause) {
      throw BackendProxyException(
        kind: BackendProxyFailureKind.invalidJson,
        endpoint: endpoint,
        message: 'Backend returned malformed JSON.',
        cause: cause,
      );
    }
    return _requiredMap(decoded, endpoint, 'response');
  }

  _BackendErrorMetadata _safeErrorMetadata(http.Response response) {
    const maximumErrorBytes = 16 * 1024;
    if (response.bodyBytes.isEmpty ||
        response.bodyBytes.length > maximumErrorBytes ||
        !_isJsonMime(_responseContentType(response))) {
      return const _BackendErrorMetadata();
    }

    try {
      final decoded = jsonDecode(
        utf8.decode(response.bodyBytes, allowMalformed: false),
      );
      if (decoded is! Map<String, dynamic>) {
        return const _BackendErrorMetadata();
      }
      final error = decoded['error'];
      if (error is! Map<String, dynamic> ||
          error['status'] != response.statusCode) {
        return const _BackendErrorMetadata();
      }

      final rawCode = error['code'];
      final code =
          rawCode is String && _knownBackendErrorCodes.contains(rawCode)
              ? rawCode
              : null;
      final bodyRequestId = _safeRequestId(error['request_id']);
      final headerRequestId = _safeRequestId(
        _responseHeader(response, 'x-request-id'),
      );
      final requestId = bodyRequestId != null && headerRequestId != null
          ? bodyRequestId == headerRequestId
              ? bodyRequestId
              : null
          : bodyRequestId ?? headerRequestId;
      return _BackendErrorMetadata(code: code, requestId: requestId);
    } on Object {
      return const _BackendErrorMetadata();
    }
  }

  String _backendErrorMessage(
    int statusCode,
    String endpoint,
    _BackendErrorMetadata metadata,
  ) {
    if (endpoint.startsWith('/v1/documents')) {
      return switch (statusCode) {
        400 => 'JPEG/PNG 문서인지, 파일 이름과 이미지 크기(1,600만 화소 이하)를 확인하세요.',
        401 || 403 => '문서 관리 권한이 없습니다. 백엔드 인증 설정을 확인하세요.',
        404 => '문서를 찾지 못했습니다. 목록을 새로고침하고, 백엔드를 최신 코드로 다시 시작했는지 확인하세요.',
        409 => '에셋의 소유 관계 또는 경로를 확인할 수 없어 삭제하지 않았습니다. 서버의 매니페스트를 확인하세요.',
        413 => '문서가 비어 있거나 8 MiB 제한을 초과했습니다.',
        _ => '문서 저장소 요청에 실패했습니다 (HTTP $statusCode). 다시 시도하세요.',
      };
    }
    final message = switch ((metadata.code, statusCode, endpoint)) {
      ('matching_strategy_unavailable', _, _) =>
        '선택한 전략이 준비되지 않았거나 설정이 잘못되었습니다. 1단계의 전략 상태를 새로고침하고 서버 설정을 확인하세요.',
      ('target_access_denied', _, _) =>
        'Target이 접근을 거부했습니다. 승인된 상품 데이터 접근 권한을 확인하세요.',
      ('target_rate_limited', _, _) => 'Target 요청 한도에 도달했습니다. 잠시 후 다시 시도하세요.',
      ('target_timeout', _, _) => 'Target 상품 조회 시간이 초과되었습니다.',
      ('target_no_product_data', _, _) =>
        'Target 검색 페이지에 조회 가능한 상품 데이터가 없습니다. 승인된 상품 데이터 피드 또는 직접 구매 URL 확인이 필요합니다.',
      ('target_invalid_response', _, _) => 'Target 응답 형식이 예상과 다릅니다.',
      ('target_upstream_failed', _, _) => 'Target 상품 서버에 연결하지 못했습니다.',
      ('ocr_engine_unavailable', _, _) =>
        '서버의 로컬 OCR 엔진을 사용할 수 없습니다. Tesseract와 언어 데이터를 설치하고 '
            'CURATOR_TESSERACT_BIN / CURATOR_OCR_LANGUAGE 설정을 확인하세요.',
      ('ocr_invalid_image', _, _) =>
        '이미지를 읽을 수 없습니다. 8 MiB / 1,600만 화소 이하의 JPEG 또는 PNG를 사용하세요.',
      ('ocr_no_items', _, _) =>
        '물품 목록 또는 수량을 읽지 못했습니다. 글자가 선명한 목록·표 이미지를 선택하세요.',
      ('ocr_busy', _, _) => '서버가 다른 이미지를 분석 중입니다. 잠시 후 다시 시도하세요.',
      ('ocr_failed', _, _) => '로컬 OCR 처리에 실패했습니다. 이미지를 확인하고 다시 시도하세요.',
      (_, 404, _) =>
        'Curator proxy endpoint was not found. Start the proxy and check '
            'CURATOR_BACKEND_URL or the reverse-proxy /v1 route.',
      (_, 503, _ocrEndpoint) => '서버의 Tesseract 엔진과 OCR 언어 데이터를 확인하세요.',
      _ => 'Backend returned a non-success status (HTTP $statusCode).',
    };
    final requestId = metadata.requestId;
    return requestId == null ? message : '$message (요청 ID: $requestId)';
  }

  static String? _safeRequestId(Object? value) {
    if (value is! String ||
        !RegExp(r'^[a-f0-9]{1,32}-[a-f0-9]{1,8}$').hasMatch(value)) {
      return null;
    }
    return value;
  }

  void _validateDeclaredLength(
    http.Response response,
    int maximum,
    String endpoint,
  ) {
    final rawLength = _responseHeader(response, 'content-length');
    if (rawLength == null) return;
    final declaredLength = int.tryParse(rawLength);
    if (declaredLength == null || declaredLength < 0) {
      throw _invalidResponse(endpoint, 'Invalid Content-Length header.');
    }
    if (declaredLength > maximum) {
      throw _invalidResponse(endpoint, 'Response exceeds the size limit.');
    }
  }

  Uri _endpointUri(String endpoint) {
    final relative =
        endpoint.startsWith('/') ? endpoint.substring(1) : endpoint;
    return _backendBaseUri.resolve(relative);
  }

  Uri get _originUri => Uri(
        scheme: _backendBaseUri.scheme,
        host: _backendBaseUri.host,
        port: _backendBaseUri.hasPort ? _backendBaseUri.port : null,
        path: '/',
      );

  static Uri _parseBackendBaseUrl(String value) {
    final source = value.trim();
    if (source.isEmpty || _containsControlCharacter(source)) {
      throw ArgumentError.value(
        value,
        'backendBaseUrl',
        'Must be an absolute HTTP(S) URL.',
      );
    }
    final parsed = Uri.tryParse(source);
    if (parsed == null ||
        (parsed.scheme != 'http' && parsed.scheme != 'https') ||
        (parsed.scheme == 'http' && !_isLoopbackBackendHost(parsed.host)) ||
        parsed.host.isEmpty ||
        parsed.userInfo.isNotEmpty ||
        parsed.hasQuery ||
        parsed.hasFragment) {
      throw ArgumentError.value(
        value,
        'backendBaseUrl',
        'Must use HTTPS, except for an HTTP loopback development URL, and must '
            'not contain credentials, a query, or a fragment.',
      );
    }
    final path = parsed.path.isEmpty
        ? '/'
        : '${parsed.path.replaceFirst(RegExp(r'/+$'), '')}/';
    return parsed.replace(path: path);
  }

  static bool _isLoopbackBackendHost(String host) {
    final normalized = host.toLowerCase();
    return normalized == 'localhost' ||
        normalized == '127.0.0.1' ||
        normalized == '::1' ||
        normalized == '0:0:0:0:0:0:0:1';
  }

  static String? _parseAuthToken(String? value) {
    if (value == null || value.trim().isEmpty) return null;
    final token = value.trim();
    if (token.codeUnits.any((unit) => unit <= 0x20 || unit == 0x7f)) {
      throw ArgumentError.value(
        value,
        'authToken',
        'Must not contain whitespace or control characters.',
      );
    }
    return token;
  }

  static bool _isSameOrigin(Uri first, Uri second) =>
      first.scheme.toLowerCase() == second.scheme.toLowerCase() &&
      first.host.toLowerCase() == second.host.toLowerCase() &&
      first.port == second.port;

  static bool _containsControlCharacter(String value) =>
      value.codeUnits.any((unit) => unit < 0x20 || unit == 0x7f);

  static String? _responseHeader(http.Response response, String name) {
    final lowerName = name.toLowerCase();
    for (final entry in response.headers.entries) {
      if (entry.key.toLowerCase() == lowerName) return entry.value.trim();
    }
    return null;
  }

  static String? _responseContentType(http.Response response) {
    final value = _responseHeader(response, 'content-type');
    return value?.split(';').first.trim().toLowerCase();
  }

  static bool _isJsonMime(String? value) {
    if (value == null) return false;
    return value == 'application/json' || value.endsWith('+json');
  }

  static String? _normalizeRasterMime(String? value) {
    switch (value?.toLowerCase()) {
      case 'image/png':
      case 'image/x-png':
        return 'image/png';
      case 'image/jpeg':
      case 'image/jpg':
      case 'image/pjpeg':
        return 'image/jpeg';
      case 'image/webp':
        return 'image/webp';
      case 'image/gif':
        return 'image/gif';
      case 'image/avif':
        return 'image/avif';
      default:
        return null;
    }
  }

  static bool _matchesRasterSignature(List<int> bytes, String mime) {
    switch (mime) {
      case 'image/png':
        return _startsWith(bytes, const [137, 80, 78, 71, 13, 10, 26, 10]);
      case 'image/jpeg':
        return _startsWith(bytes, const [255, 216, 255]);
      case 'image/gif':
        return _asciiAt(bytes, 0, 'GIF87a') || _asciiAt(bytes, 0, 'GIF89a');
      case 'image/webp':
        return _asciiAt(bytes, 0, 'RIFF') && _asciiAt(bytes, 8, 'WEBP');
      case 'image/avif':
        if (!_asciiAt(bytes, 4, 'ftyp')) return false;
        final prefixLength = bytes.length < 32 ? bytes.length : 32;
        final prefix = ascii.decode(
          bytes.sublist(0, prefixLength),
          allowInvalid: true,
        );
        return prefix.contains('avif') || prefix.contains('avis');
      default:
        return false;
    }
  }

  static bool _startsWith(List<int> bytes, List<int> signature) {
    if (bytes.length < signature.length) return false;
    for (var index = 0; index < signature.length; index++) {
      if (bytes[index] != signature[index]) return false;
    }
    return true;
  }

  static bool _asciiAt(List<int> bytes, int offset, String expected) {
    if (bytes.length < offset + expected.length) return false;
    for (var index = 0; index < expected.length; index++) {
      if (bytes[offset + index] != expected.codeUnitAt(index)) return false;
    }
    return true;
  }

  Map<String, dynamic> _requiredMap(
    Object? value,
    String endpoint,
    String field,
  ) {
    if (value is! Map) {
      throw _invalidResponse(endpoint, '$field must be a JSON object.');
    }
    final result = <String, dynamic>{};
    for (final entry in value.entries) {
      if (entry.key is! String) {
        throw _invalidResponse(endpoint, '$field has a non-string key.');
      }
      result[entry.key as String] = entry.value;
    }
    return result;
  }

  List<dynamic> _requiredList(
    Map<String, dynamic> map,
    List<String> keys,
    String endpoint,
  ) {
    final value = _requiredValue(map, keys, endpoint);
    if (value is! List) {
      throw _invalidResponse(endpoint, '${keys.first} must be an array.');
    }
    return value;
  }

  String _requiredString(
    Map<String, dynamic> map,
    List<String> keys,
    String endpoint, {
    bool allowEmpty = false,
  }) {
    final value = _requiredValue(map, keys, endpoint);
    if (value is! String) {
      throw _invalidResponse(endpoint, '${keys.first} must be a string.');
    }
    final normalized = value.trim();
    if ((!allowEmpty && normalized.isEmpty) ||
        _containsControlCharacter(normalized)) {
      throw _invalidResponse(endpoint, '${keys.first} has an invalid value.');
    }
    return normalized;
  }

  bool _requiredBool(
    Map<String, dynamic> map,
    List<String> keys,
    String endpoint,
  ) {
    final value = _requiredValue(map, keys, endpoint);
    if (value is! bool) {
      throw _invalidResponse(endpoint, '${keys.first} must be a boolean.');
    }
    return value;
  }

  int _requiredInteger(
    Map<String, dynamic> map,
    List<String> keys,
    String endpoint, {
    required int minimum,
  }) {
    final value = _requiredValue(map, keys, endpoint);
    if (value is! num ||
        !value.isFinite ||
        value != value.truncateToDouble() ||
        value < minimum) {
      throw _invalidResponse(
        endpoint,
        '${keys.first} must be an integer greater than or equal to $minimum.',
      );
    }
    return value.toInt();
  }

  double _requiredFiniteDouble(
    Map<String, dynamic> map,
    List<String> keys,
    String endpoint, {
    double? minimum,
    double? exclusiveMinimum,
  }) {
    final value = _requiredValue(map, keys, endpoint);
    final number = _finiteNumber(value, endpoint, keys.first);
    if ((minimum != null && number < minimum) ||
        (exclusiveMinimum != null && number <= exclusiveMinimum)) {
      throw _invalidResponse(endpoint, '${keys.first} is out of range.');
    }
    return number;
  }

  double _finiteNumber(Object? value, String endpoint, String field) {
    if (value is! num || !value.isFinite) {
      throw _invalidResponse(endpoint, '$field must be a finite number.');
    }
    return value.toDouble();
  }

  Object? _requiredValue(
    Map<String, dynamic> map,
    List<String> keys,
    String endpoint,
  ) {
    if (!_containsAnyKey(map, keys)) {
      throw _invalidResponse(
        endpoint,
        'Missing required ${keys.first} field.',
      );
    }
    final value = _valueForKeys(map, keys);
    if (value == null) {
      throw _invalidResponse(endpoint, '${keys.first} must not be null.');
    }
    return value;
  }

  static bool _containsAnyKey(
    Map<String, dynamic> map,
    List<String> keys,
  ) =>
      keys.any(map.containsKey);

  static Object? _valueForKeys(
    Map<String, dynamic> map,
    List<String> keys,
  ) {
    for (final key in keys) {
      if (map.containsKey(key)) return map[key];
    }
    return null;
  }

  static BackendProxyException _invalidResponse(
    String endpoint,
    String message,
  ) =>
      BackendProxyException(
        kind: BackendProxyFailureKind.invalidResponse,
        endpoint: endpoint,
        message: message,
      );
}

enum _ReadinessAttemptSignal { ready, timedOut, cancelled }

const _knownBackendErrorCodes = <String>{
  'matching_strategy_unavailable',
  'target_access_denied',
  'target_rate_limited',
  'target_timeout',
  'target_no_product_data',
  'target_invalid_response',
  'target_upstream_failed',
  'ocr_engine_unavailable',
  'ocr_invalid_image',
  'ocr_no_items',
  'ocr_busy',
  'ocr_failed',
};

final class _BackendErrorMetadata {
  const _BackendErrorMetadata({this.code, this.requestId});

  final String? code;
  final String? requestId;
}

/// Relays one external cancellation future to short-lived listeners without
/// retaining one callback per retry attempt on that future.
final class _ReadinessCancellationRelay {
  _ReadinessCancellationRelay(Future<void>? signal) {
    signal?.then<void>(
      (_) => _cancel(),
      onError: (Object _, StackTrace __) => _cancel(),
    );
  }

  final Set<void Function()> _listeners = {};
  bool _isCancelled = false;

  bool get isCancelled => _isCancelled;

  void Function() addListener(void Function() listener) {
    if (_isCancelled) {
      listener();
      return _noop;
    }
    _listeners.add(listener);
    return () => _listeners.remove(listener);
  }

  void _cancel() {
    if (_isCancelled) return;
    _isCancelled = true;
    final listeners = List<void Function()>.of(_listeners);
    _listeners.clear();
    for (final listener in listeners) {
      listener();
    }
  }

  static void _noop() {}
}

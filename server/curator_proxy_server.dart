import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'avif_image_decoder.dart';
import 'tesseract_text_recognizer.dart';
import 'file_source_document_repository.dart';

import 'package:shopitem_curator/core/contracts/source_document_repository.dart';
import 'package:shopitem_curator/core/contracts/curator_use_cases.dart';
import 'package:shopitem_curator/core/models/curator_item.dart';
import 'package:shopitem_curator/core/models/target_purchase_url.dart';
import 'package:shopitem_curator/core/services/ocr_extractor_service.dart';
import 'package:shopitem_curator/core/services/target_catalog_rescraper.dart';
import 'package:shopitem_curator/core/services/target_fetcher_service.dart';
import 'package:shopitem_curator/core/services/scraper/target_request_policy.dart';

const _healthPath = '/health';
const _readinessPath = '/ready';
const _serviceName = 'shopitem-curator-proxy';
const _apiVersion = 'v1';
const _ocrPath = '/v1/ocr/extract';
const _productsPath = '/v1/catalog/products';
const _candidatesPath = '/v1/catalog/review-candidates';
const _inspectPath = '/v1/catalog/inspect';
const _rescrapePath = '/v1/catalog/rescrape';
const _imagePath = '/v1/catalog/image';

const _allowedRasterMimeTypes = <String>{
  'image/avif',
  'image/gif',
  'image/jpeg',
  'image/png',
  'image/webp',
};

typedef ProxyOcrExtractor = Future<List<ExtractedItemEntry>> Function({
  required String sourceImagePath,
  required List<int> imageBytes,
});

typedef ProxyProductFetcher = Future<List<TargetProductData>> Function(
  List<ExtractedItemEntry> items,
);

typedef ProxyCandidateFetcher = Future<List<TargetProductCandidate>> Function(
  CuratorItem item,
);

typedef ProxyProductInspector = Future<TargetProductCandidate?> Function(
  String url,
);

typedef ProxyCatalogRescraper = Future<CatalogRescrapeResult> Function(
  List<CuratorItem> items,
);

/// Environment-backed configuration for the standalone Dart VM proxy.
///
/// Authentication policy:
/// - `/health` and `/ready` never require authentication.
/// - A configured `CURATOR_PROXY_TOKEN` is accepted as a Bearer token.
/// - `CURATOR_TRUSTED_AUTH_HEADER` is intended for a same-origin reverse proxy.
///   The proxy must strip the client-supplied header, authenticate the request,
///   and inject `<header>: 1`. This mode is forced to a loopback bind address.
/// - With neither mechanism configured, unauthenticated traffic is allowed only
///   on loopback when `CURATOR_ALLOW_UNAUTHENTICATED_LOOPBACK=true` (the default
///   development policy). A public bind without authentication is rejected.
final class CuratorProxyConfig {
  CuratorProxyConfig({
    required this.bindAddress,
    this.port = 8787,
    this.allowedOrigin,
    String? bearerToken,
    String? trustedAuthHeader,
    this.allowUnauthenticatedLoopback = true,
    this.maxBodyBytes = 12 * 1024 * 1024,
    this.maxImageBytes = 8 * 1024 * 1024,
    this.maxCatalogItems = 50,
    this.upstreamTimeout = const Duration(seconds: 45),
    this.rateLimit = 60,
    this.rateWindow = const Duration(minutes: 1),
  })  : _bearerToken = _nonEmptyOrNull(bearerToken),
        _trustedAuthHeader = _nonEmptyOrNull(trustedAuthHeader) {
    if (port < 0 || port > 65535) {
      throw ArgumentError.value(port, 'port', 'must be between 0 and 65535');
    }
    if (maxBodyBytes < 1 || maxImageBytes < 1) {
      throw ArgumentError('Body and image limits must be positive.');
    }
    if (maxCatalogItems < 1) {
      throw ArgumentError.value(
        maxCatalogItems,
        'maxCatalogItems',
        'must be positive',
      );
    }
    if (upstreamTimeout <= Duration.zero || rateWindow <= Duration.zero) {
      throw ArgumentError('Timeouts and rate windows must be positive.');
    }
    if (rateLimit < 1) {
      throw ArgumentError.value(rateLimit, 'rateLimit', 'must be positive');
    }
    if (_trustedAuthHeader != null &&
        !RegExp(r'^[A-Za-z0-9-]{1,64}$').hasMatch(_trustedAuthHeader)) {
      throw ArgumentError('CURATOR_TRUSTED_AUTH_HEADER is not a safe header.');
    }
    if (_trustedAuthHeader != null && !_isLoopbackAddress(bindAddress)) {
      throw ArgumentError(
        'Trusted-header authentication requires a loopback bind address.',
      );
    }
    if (_bearerToken == null &&
        _trustedAuthHeader == null &&
        !(allowUnauthenticatedLoopback && _isLoopbackAddress(bindAddress))) {
      throw ArgumentError(
        'CURATOR_PROXY_TOKEN or CURATOR_TRUSTED_AUTH_HEADER is required '
        'outside loopback development.',
      );
    }
    final originList = allowedOrigin
        ?.split(',')
        .map((origin) => origin.trim())
        .where((origin) => origin.isNotEmpty)
        .toList(growable: false);
    if (originList != null) {
      if (originList.isEmpty || originList.contains('*')) {
        throw ArgumentError(
          'CURATOR_CORS_ALLOW_ORIGIN must contain exact origins, not "*".',
        );
      }
      for (final origin in originList) {
        if (_normalizedHttpOrigin(origin) == null) {
          throw ArgumentError(
            'CURATOR_CORS_ALLOW_ORIGIN contains an invalid origin.',
          );
        }
      }
    }
  }

  factory CuratorProxyConfig.fromPlatformEnvironment() {
    final environment = Platform.environment;
    final host = (environment['CURATOR_PROXY_HOST'] ?? '127.0.0.1').trim();
    final address = InternetAddress.tryParse(host);
    if (address == null) {
      throw StateError('CURATOR_PROXY_HOST must be an IP address.');
    }

    return CuratorProxyConfig(
      bindAddress: address,
      port: _readEnvironmentInt(
        environment,
        'CURATOR_PROXY_PORT',
        fallback: 8787,
        minimum: 0,
        maximum: 65535,
      ),
      allowedOrigin: _nonEmptyOrNull(
        environment['CURATOR_CORS_ALLOW_ORIGIN'],
      ),
      bearerToken: environment['CURATOR_PROXY_TOKEN'],
      trustedAuthHeader: environment['CURATOR_TRUSTED_AUTH_HEADER'],
      allowUnauthenticatedLoopback: _readEnvironmentBool(
        environment,
        'CURATOR_ALLOW_UNAUTHENTICATED_LOOPBACK',
        fallback: true,
      ),
      maxBodyBytes: _readEnvironmentInt(
        environment,
        'CURATOR_MAX_BODY_BYTES',
        fallback: 12 * 1024 * 1024,
        minimum: 1024,
        maximum: 64 * 1024 * 1024,
      ),
      maxImageBytes: _readEnvironmentInt(
        environment,
        'CURATOR_MAX_IMAGE_BYTES',
        fallback: 8 * 1024 * 1024,
        minimum: 1024,
        maximum: 32 * 1024 * 1024,
      ),
      maxCatalogItems: _readEnvironmentInt(
        environment,
        'CURATOR_MAX_CATALOG_ITEMS',
        fallback: 50,
        minimum: 1,
        maximum: 200,
      ),
      upstreamTimeout: Duration(
        seconds: _readEnvironmentInt(
          environment,
          'CURATOR_UPSTREAM_TIMEOUT_SECONDS',
          fallback: 45,
          minimum: 1,
          maximum: 120,
        ),
      ),
      rateLimit: _readEnvironmentInt(
        environment,
        'CURATOR_RATE_LIMIT_PER_MINUTE',
        fallback: 60,
        minimum: 1,
        maximum: 10000,
      ),
    );
  }

  final InternetAddress bindAddress;
  final int port;
  final String? allowedOrigin;
  final String? _bearerToken;
  final String? _trustedAuthHeader;
  final bool allowUnauthenticatedLoopback;
  final int maxBodyBytes;
  final int maxImageBytes;
  final int maxCatalogItems;
  final Duration upstreamTimeout;
  final int rateLimit;
  final Duration rateWindow;
}

/// Testable adapter around the existing Pure Dart OCR and Target services.
final class CuratorProxyDependencies {
  const CuratorProxyDependencies({
    required this.extractOcr,
    required this.fetchProducts,
    required this.fetchCandidates,
    required this.inspectProduct,
    required this.rescrape,
    this.ocrConfigured = true,
    this.checkOcrReady,
    this.close,
  });

  final ProxyOcrExtractor extractOcr;
  final ProxyProductFetcher fetchProducts;
  final ProxyCandidateFetcher fetchCandidates;
  final ProxyProductInspector inspectProduct;
  final ProxyCatalogRescraper rescrape;
  final bool ocrConfigured;
  final Future<bool> Function()? checkOcrReady;
  final FutureOr<void> Function()? close;
}

final class CuratorProxyImage {
  CuratorProxyImage({required List<int> bytes, required this.contentType})
      : bytes = Uint8List.fromList(bytes);

  final Uint8List bytes;
  final String contentType;
}

abstract interface class CuratorProxyImageFetcher {
  Future<CuratorProxyImage> fetch(
    Uri uri, {
    required int maxBytes,
    required Duration timeout,
  });

  FutureOr<void> close();
}

/// Standalone, dependency-free HTTP server boundary for Flutter Web clients.
final class CuratorProxyServer {
  CuratorProxyServer({
    required this.config,
    required CuratorProxyDependencies dependencies,
    CuratorProxyImageFetcher? imageFetcher,
    AvifImageDecoder? avifDecoder,
    SourceDocumentRepository? documentRepository,
  })  : _dependencies = dependencies,
        _documentRepository = documentRepository,
        _imageFetcher = imageFetcher ?? _DartIoTargetImageFetcher(),
        _avifDecoder = avifDecoder ?? AvifDecImageDecoder.fromEnvironment();

  factory CuratorProxyServer.fromPlatformEnvironment() {
    final config = CuratorProxyConfig.fromPlatformEnvironment();

    final recognizer = TesseractTextRecognizer.fromEnvironment(
      timeout: config.upstreamTimeout,
    );
    final ocrService = OcrExtractorService(recognizer: recognizer);
    final targetService = TargetFetcherService(
        preferLiveCatalog: true,
        redSkyApiKey: Platform.environment['CURATOR_TARGET_REDSKY_KEY']);
    final rescraper = TargetCatalogRescraper(targetService);

    return CuratorProxyServer(
      config: config,
      documentRepository: FileSourceDocumentRepository(
        assetsDirectory:
            Directory(Platform.environment['CURATOR_ASSETS_DIR'] ?? 'assets'),
        maxImageBytes: config.maxImageBytes,
      ),
      dependencies: CuratorProxyDependencies(
        checkOcrReady: recognizer.isAvailable,
        extractOcr: ({required sourceImagePath, required imageBytes}) =>
            ocrService.extractItemsFromImage(
          sourceImagePath,
          imageBytes: imageBytes,
        ),
        fetchProducts: targetService.fetchTargetProducts,
        fetchCandidates: targetService.fetchLiveCandidates,
        inspectProduct: targetService.fetchProductByTargetUrl,
        rescrape: (items) => rescraper.rescrapeAll(items: items),
        close: () {
          recognizer.close();
          targetService.close();
        },
      ),
    );
  }

  final CuratorProxyConfig config;
  final CuratorProxyDependencies _dependencies;
  final SourceDocumentRepository? _documentRepository;
  final CuratorProxyImageFetcher _imageFetcher;
  final AvifImageDecoder _avifDecoder;
  final Map<String, _RateBucket> _rateBuckets = {};

  HttpServer? _server;
  Future<void>? _closing;
  bool _closed = false;
  int _requestSequence = 0;

  bool get isRunning => _server != null && !_closed;

  Uri get baseUri {
    final server = _server;
    if (server == null) throw StateError('The proxy server has not started.');
    final host = server.address.type == InternetAddressType.IPv6
        ? '[${server.address.address}]'
        : server.address.address;
    return Uri.parse('http://$host:${server.port}');
  }

  Future<HttpServer> start() async {
    if (_closed) throw StateError('A closed proxy server cannot be restarted.');
    if (_server != null) {
      throw StateError('The proxy server is already running.');
    }

    final server = await HttpServer.bind(config.bindAddress, config.port);
    server.autoCompress = true;
    _server = server;
    server.listen((request) {
      unawaited(_handleRequest(request).catchError((Object _) {
        // Client disconnects and already-closed response streams are harmless.
        // Deliberately do not log exception strings because upstream errors can
        // contain sensitive request details.
      }));
    });
    return server;
  }

  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    _closed = true;
    final server = _server;
    _server = null;
    Object? firstError;
    StackTrace? firstStackTrace;

    Future<void> closeResource(FutureOr<void> Function() action) async {
      try {
        await action();
      } catch (error, stackTrace) {
        firstError ??= error;
        firstStackTrace ??= stackTrace;
      }
    }

    if (server != null) {
      await closeResource(() => server.close(force: false));
    }
    await closeResource(_imageFetcher.close);
    await closeResource(_avifDecoder.close);
    final closeDependencies = _dependencies.close;
    if (closeDependencies != null) {
      await closeResource(closeDependencies);
    }
    _rateBuckets.clear();
    if (firstError != null) {
      Error.throwWithStackTrace(firstError!, firstStackTrace!);
    }
  }

  Future<void> _handleRequest(HttpRequest request) async {
    final requestId = _nextRequestId();
    try {
      _applySecurityHeaders(request.response);
      request.response.headers.set('X-Request-Id', requestId);
      _applyCors(request);

      if (request.uri.path == _healthPath) {
        _requireMethod(request, 'GET');
        _writeJson(request.response, HttpStatus.ok, const {
          'status': 'ok',
          'service': _serviceName,
          'api_version': _apiVersion,
        });
        return;
      }

      if (request.uri.path == _readinessPath) {
        _requireMethod(request, 'GET');
        final ocrConfigured = await _isOcrReady();
        final ready = isRunning && ocrConfigured;
        _writeJson(
          request.response,
          ready ? HttpStatus.ok : HttpStatus.serviceUnavailable,
          {
            'status': ready ? 'ready' : 'not_ready',
            'service': _serviceName,
            'api_version': _apiVersion,
            'dependencies': {
              'ocr': ocrConfigured ? 'ready' : 'not_configured',
            },
          },
        );
        return;
      }

      if (request.method == 'OPTIONS') {
        request.response.statusCode = HttpStatus.noContent;
        request.response.headers
          ..set(HttpHeaders.accessControlAllowMethodsHeader,
              'GET, POST, DELETE, OPTIONS')
          ..set(
            HttpHeaders.accessControlAllowHeadersHeader,
            'Authorization, Content-Type',
          )
          ..set(HttpHeaders.accessControlMaxAgeHeader, '600');
        return;
      }

      _enforceRateLimit(request);
      _authenticate(request);

      switch (request.uri.path) {
        case '/v1/documents':
        case '/v1/documents/read':
          await _handleDocuments(request);
          return;
        case _ocrPath:
          _requireMethod(request, 'POST');
          await _handleOcr(request);
          return;
        case _productsPath:
          _requireMethod(request, 'POST');
          await _handleProducts(request);
          return;
        case _candidatesPath:
          _requireMethod(request, 'POST');
          await _handleCandidates(request);
          return;
        case _inspectPath:
          _requireMethod(request, 'POST');
          await _handleInspect(request);
          return;
        case _rescrapePath:
          _requireMethod(request, 'POST');
          await _handleRescrape(request);
          return;
        case _imagePath:
          _requireMethod(request, 'GET');
          await _handleImage(request);
          return;
        default:
          throw const _ProxyHttpException(
            HttpStatus.notFound,
            'Endpoint not found.',
          );
      }
    } on TargetLookupException catch (error) {
      _writeJsonError(
          request.response,
          error.kind == TargetLookupFailure.rateLimited ? 429 : 502,
          error.message,
          requestId,
          code: error.code);
    } on DocumentStorageException catch (error) {
      _writeJsonError(
          request.response, error.statusCode, error.message, requestId,
          code: 'document_storage_error');
    } on _ProxyHttpException catch (error) {
      _writeJsonError(
        request.response,
        error.statusCode,
        error.publicMessage,
        requestId,
        code: error.code,
      );
    } on TimeoutException {
      _writeJsonError(
        request.response,
        HttpStatus.gatewayTimeout,
        'The upstream request timed out.',
        requestId,
      );
    } catch (_) {
      _writeJsonError(
        request.response,
        HttpStatus.internalServerError,
        'The proxy could not process the request.',
        requestId,
      );
    } finally {
      await request.response.close();
    }
  }

  Future<bool> _isOcrReady() async {
    if (!_dependencies.ocrConfigured) return false;
    try {
      return await _dependencies.checkOcrReady?.call() ?? true;
    } on Object {
      return false;
    }
  }

  Future<void> _handleDocuments(HttpRequest request) async {
    final repository = _documentRepository;
    if (repository == null) {
      throw const _ProxyHttpException(
          503, 'Document storage is not configured.');
    }
    if (request.uri.path == '/v1/documents/read') {
      _requireMethod(request, 'POST');
      final body = await _readJsonObject(request);
      final path = _requiredString(body['source_image_path'],
          field: 'source_image_path', maxLength: 512);
      final bytes = await repository.readDocument(path);
      _writeJson(request.response, 200, {'image_base64': base64Encode(bytes)});
    } else if (request.method == 'GET') {
      _writeJson(request.response, 200,
          {'documents': await repository.listDocuments()});
    } else if (request.method == 'DELETE') {
      final body = await _readJsonObject(request);
      final path = _requiredString(body['source_image_path'],
          field: 'source_image_path', maxLength: 512);
      await repository.deleteDocument(path);
      _writeJson(request.response, 200, {'deleted': path});
    } else {
      _requireMethod(request, 'POST');
      final body = await _readJsonObject(request);
      final filename =
          _requiredString(body['filename'], field: 'filename', maxLength: 180);
      final encoded = _requiredString(body['image_base64'],
          field: 'image_base64', maxLength: config.maxBodyBytes);
      late final Uint8List bytes;
      try {
        bytes = base64Decode(encoded);
      } on FormatException {
        throw const _ProxyHttpException(400, 'Invalid document Base64.');
      }
      final path = await repository.importDocument(filename, bytes);
      _writeJson(request.response, 201, {'source_image_path': path});
    }
  }

  Future<void> _handleOcr(HttpRequest request) async {
    if (!await _isOcrReady()) {
      throw const _ProxyHttpException(
        HttpStatus.serviceUnavailable,
        'Local OCR engine or language data is unavailable.',
        code: 'ocr_engine_unavailable',
      );
    }
    final body = await _readJsonObject(request);
    final sourceImagePath = _optionalString(
          body['source_image_path'],
          field: 'source_image_path',
          maxLength: 512,
        ) ??
        'upload.jpg';
    final encodedImage = _requiredString(
      body['image_base64'],
      field: 'image_base64',
      maxLength: config.maxBodyBytes,
    );

    late final Uint8List imageBytes;
    try {
      imageBytes = base64Decode(encodedImage);
    } on FormatException {
      throw const _ProxyHttpException(
        HttpStatus.badRequest,
        'image_base64 is not valid Base64.',
      );
    }
    if (imageBytes.isEmpty || imageBytes.length > config.maxImageBytes) {
      throw const _ProxyHttpException(
        HttpStatus.requestEntityTooLarge,
        'The image is empty or exceeds the configured size limit.',
      );
    }

    late final List<ExtractedItemEntry> items;
    try {
      items = await _dependencies
          .extractOcr(
            sourceImagePath: sourceImagePath,
            imageBytes: imageBytes,
          )
          .timeout(config.upstreamTimeout);
    } on TimeoutException {
      rethrow;
    } on OcrException catch (error) {
      throw _ocrProxyFailure(error);
    } catch (_) {
      throw const _ProxyHttpException(
        HttpStatus.badGateway,
        'Local OCR processing failed.',
        code: 'ocr_failed',
      );
    }

    _writeJson(request.response, HttpStatus.ok, {
      'items': items.map(_ocrItemToJson).toList(growable: false),
    });
  }

  Future<void> _handleProducts(HttpRequest request) async {
    final body = await _readJsonObject(request);
    final items = _parseOcrItems(body['items']);

    late final List<TargetProductData> products;
    try {
      products = await _dependencies
          .fetchProducts(items)
          .timeout(config.upstreamTimeout);
    } on TargetLookupException {
      rethrow;
    } on TimeoutException {
      rethrow;
    } catch (_) {
      throw const _ProxyHttpException(
        HttpStatus.badGateway,
        'Target product lookup failed.',
      );
    }

    _writeJson(request.response, HttpStatus.ok, {
      'products': products.map(_productToJson).toList(growable: false),
    });
  }

  Future<void> _handleCandidates(HttpRequest request) async {
    final body = await _readJsonObject(request);
    final item = _parseCuratorItem(body['item']);

    late final List<TargetProductCandidate> candidates;
    try {
      candidates = await _dependencies
          .fetchCandidates(item)
          .timeout(config.upstreamTimeout);
    } on TargetLookupException {
      rethrow;
    } on TimeoutException {
      rethrow;
    } catch (_) {
      throw const _ProxyHttpException(
        HttpStatus.badGateway,
        'Target candidate lookup failed.',
      );
    }

    _writeJson(request.response, HttpStatus.ok, {
      'candidates': candidates.map(_candidateToJson).toList(growable: false),
    });
  }

  Future<void> _handleInspect(HttpRequest request) async {
    final body = await _readJsonObject(request);
    final url = _requiredString(
      body['url'],
      field: 'url',
      maxLength: 4096,
    );
    if (!_isInspectableTargetUri(url)) {
      throw const _ProxyHttpException(
        HttpStatus.badRequest,
        'Only HTTPS Target PDP or Target Scene7 image URLs are allowed.',
      );
    }

    late final TargetProductCandidate? candidate;
    try {
      candidate = await _dependencies
          .inspectProduct(url)
          .timeout(config.upstreamTimeout);
    } on TargetLookupException {
      rethrow;
    } on TimeoutException {
      rethrow;
    } catch (_) {
      throw const _ProxyHttpException(
        HttpStatus.badGateway,
        'Target product inspection failed.',
      );
    }

    _writeJson(request.response, HttpStatus.ok, {
      'candidate': candidate == null ? null : _candidateToJson(candidate),
    });
  }

  Future<void> _handleRescrape(HttpRequest request) async {
    final body = await _readJsonObject(request);
    final rawItems = body['items'];
    if (rawItems is! List) {
      throw const _ProxyHttpException(
        HttpStatus.badRequest,
        'items must be a JSON array.',
      );
    }
    if (rawItems.length > config.maxCatalogItems) {
      throw const _ProxyHttpException(
        HttpStatus.requestEntityTooLarge,
        'Too many catalog items were submitted.',
      );
    }
    final items = rawItems.map(_parseCuratorItem).toList(growable: false);

    late final CatalogRescrapeResult result;
    try {
      result = await _dependencies.rescrape(items).timeout(
            config.upstreamTimeout,
          );
    } on TargetLookupException {
      rethrow;
    } on TimeoutException {
      rethrow;
    } catch (_) {
      throw const _ProxyHttpException(
        HttpStatus.badGateway,
        'Target catalog refresh failed.',
      );
    }
    if (result.successfulItemCount < 0 ||
        result.failedItemCount < 0 ||
        result.totalItemCount != result.items.length ||
        result.items.length != items.length) {
      throw const _ProxyHttpException(
        HttpStatus.badGateway,
        'Target catalog refresh returned an invalid result.',
      );
    }

    _writeJson(request.response, HttpStatus.ok, {
      'items': result.items.map(_curatorItemToJson).toList(growable: false),
      'successful_item_count': result.successfulItemCount,
      'failed_item_count': result.failedItemCount,
    });
  }

  Future<void> _handleImage(HttpRequest request) async {
    final values = request.uri.queryParametersAll['url'];
    if (values == null || values.length != 1 || values.single.isEmpty) {
      throw const _ProxyHttpException(
        HttpStatus.badRequest,
        'Exactly one image url is required.',
      );
    }
    final uri = Uri.tryParse(values.single);
    if (uri == null || !_isAllowedScene7ImageUri(uri)) {
      throw const _ProxyHttpException(
        HttpStatus.badRequest,
        'Only HTTPS Target Scene7 raster URLs are allowed.',
      );
    }

    late final CuratorProxyImage image;
    try {
      image = await _imageFetcher
          .fetch(
            uri,
            maxBytes: config.maxImageBytes,
            timeout: config.upstreamTimeout,
          )
          .timeout(config.upstreamTimeout);
    } on TimeoutException {
      rethrow;
    } on _ProxyHttpException {
      rethrow;
    } catch (_) {
      throw const _ProxyHttpException(
        HttpStatus.badGateway,
        'Target image fetch failed.',
      );
    }
    var mimeType = image.contentType.toLowerCase().split(';').first.trim();
    if (image.bytes.isEmpty ||
        !_allowedRasterMimeTypes.contains(mimeType) ||
        image.bytes.length > config.maxImageBytes) {
      throw const _ProxyHttpException(
        HttpStatus.badGateway,
        'Target image response was not an allowed raster image.',
      );
    }

    var bytes = image.bytes;
    if (mimeType == 'image/avif' || isAvifImage(bytes)) {
      try {
        bytes = await _avifDecoder.decodeToPng(bytes,
            maxOutputBytes: config.maxImageBytes,
            timeout: config.upstreamTimeout);
        mimeType = 'image/png';
      } on AvifDecodeException catch (error) {
        final (status, message, code) = switch (error.kind) {
          AvifDecodeFailure.unavailable => (
              HttpStatus.serviceUnavailable,
              'AVIF decoder unavailable. Install libavif and check CURATOR_AVIFDEC_BIN.',
              'avif_decoder_unavailable'
            ),
          AvifDecodeFailure.invalidImage => (
              HttpStatus.badGateway,
              'Target AVIF image could not be decoded.',
              'avif_decode_failed'
            ),
          AvifDecodeFailure.oversized => (
              HttpStatus.requestEntityTooLarge,
              'Decoded Target image exceeds the size limit.',
              'avif_image_too_large'
            ),
          AvifDecodeFailure.busy => (
              HttpStatus.tooManyRequests,
              'Image decoder is busy. Try again shortly.',
              'avif_decoder_busy'
            ),
        };
        throw _ProxyHttpException(status, message, code: code);
      }
    }
    if (bytes.isEmpty || bytes.length > config.maxImageBytes) {
      throw const _ProxyHttpException(HttpStatus.badGateway,
          'Normalized Target image exceeds the allowed size.');
    }

    request.response.statusCode = HttpStatus.ok;
    request.response.headers
      ..contentType = ContentType.parse(mimeType)
      ..contentLength = bytes.length
      ..set(HttpHeaders.cacheControlHeader, 'private, max-age=300');
    _appendVary(request.response.headers, HttpHeaders.authorizationHeader);
    request.response.add(bytes);
  }

  Future<Map<String, dynamic>> _readJsonObject(HttpRequest request) async {
    final contentType = request.headers.contentType;
    if (contentType == null || contentType.mimeType != 'application/json') {
      throw const _ProxyHttpException(
        HttpStatus.unsupportedMediaType,
        'Content-Type must be application/json.',
      );
    }
    final contentLength = request.contentLength;
    if (contentLength > config.maxBodyBytes) {
      throw const _ProxyHttpException(
        HttpStatus.requestEntityTooLarge,
        'The request body exceeds the configured size limit.',
      );
    }

    final bytes = BytesBuilder(copy: false);
    await for (final chunk in request) {
      if (bytes.length + chunk.length > config.maxBodyBytes) {
        throw const _ProxyHttpException(
          HttpStatus.requestEntityTooLarge,
          'The request body exceeds the configured size limit.',
        );
      }
      bytes.add(chunk);
    }
    if (bytes.length == 0) {
      throw const _ProxyHttpException(
        HttpStatus.badRequest,
        'A JSON request body is required.',
      );
    }

    try {
      final decoded = jsonDecode(utf8.decode(bytes.takeBytes()));
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException();
      }
      return decoded;
    } on FormatException {
      throw const _ProxyHttpException(
        HttpStatus.badRequest,
        'The request body is not a valid JSON object.',
      );
    }
  }

  List<ExtractedItemEntry> _parseOcrItems(Object? value) {
    if (value is! List || value.isEmpty) {
      throw const _ProxyHttpException(
        HttpStatus.badRequest,
        'items must be a non-empty JSON array.',
      );
    }
    if (value.length > config.maxCatalogItems) {
      throw const _ProxyHttpException(
        HttpStatus.requestEntityTooLarge,
        'Too many catalog items were submitted.',
      );
    }

    return value.map((rawItem) {
      if (rawItem is! Map<String, dynamic>) {
        throw const _ProxyHttpException(
          HttpStatus.badRequest,
          'Every OCR item must be a JSON object.',
        );
      }
      final cleanName = _requiredString(
        rawItem['clean_name'],
        field: 'clean_name',
        maxLength: 200,
      );
      final rawName = _optionalString(
            rawItem['raw_name'],
            field: 'raw_name',
            maxLength: 300,
          ) ??
          cleanName;
      final isPersonal = rawItem['is_personal'] ?? false;
      if (isPersonal is! bool) {
        throw const _ProxyHttpException(
          HttpStatus.badRequest,
          'is_personal must be a boolean.',
        );
      }
      final quantity = _positiveInteger(
        rawItem['quantity'] ?? 1,
        field: 'quantity',
        maximum: 1000,
      );
      return ExtractedItemEntry(
        rawName: rawName,
        cleanName: cleanName,
        isPersonal: isPersonal,
        quantity: quantity,
      );
    }).toList(growable: false);
  }

  CuratorItem _parseCuratorItem(Object? value) {
    if (value is! Map<String, dynamic>) {
      throw const _ProxyHttpException(
        HttpStatus.badRequest,
        'item must be a JSON object.',
      );
    }
    if (value['bounds'] is! Map<String, dynamic>) {
      throw const _ProxyHttpException(
        HttpStatus.badRequest,
        'item.bounds must be a JSON object.',
      );
    }

    late final CuratorItem item;
    try {
      item = CuratorItem.fromJson(value);
    } catch (_) {
      throw const _ProxyHttpException(
        HttpStatus.badRequest,
        'item contains invalid fields.',
      );
    }
    final bounds = item.bounds;
    if (item.id.trim().isEmpty ||
        item.name.trim().isEmpty ||
        item.quantity < 1 ||
        !item.price.isFinite ||
        item.price < 0 ||
        !bounds.x.isFinite ||
        !bounds.y.isFinite ||
        !bounds.width.isFinite ||
        !bounds.height.isFinite ||
        bounds.width <= 0 ||
        bounds.height <= 0 ||
        item.id.length > 200 ||
        item.name.length > 300 ||
        item.targetUrl.length > 4096 ||
        item.imageUrl.length > config.maxBodyBytes) {
      throw const _ProxyHttpException(
        HttpStatus.badRequest,
        'item violates catalog validation rules.',
      );
    }
    return item;
  }

  Map<String, dynamic> _productToJson(TargetProductData product) => {
        'id': product.id,
        'name': product.name,
        'category': product.category,
        'is_personal': product.isPersonal,
        'quantity': product.quantity,
        'price': product.price,
        'price_currency': product.priceCurrency,
        'description': product.description,
        'target_url': product.targetUrl,
        'image_url': _safeClientImageUrl(product.imageUrl),
      };

  Map<String, dynamic> _candidateToJson(TargetProductCandidate candidate) => {
        'id': candidate.id,
        'name': candidate.name,
        'price': candidate.price,
        'description': candidate.description,
        'target_url': candidate.targetUrl,
        'image_url': _safeClientImageUrl(candidate.imageUrl),
      };

  Map<String, dynamic> _curatorItemToJson(CuratorItem item) {
    final json = item.toJson();
    json['image_url'] = _safeClientImageUrl(item.imageUrl);
    return json;
  }

  String _safeClientImageUrl(String value) {
    final candidate = value.trim();
    if (candidate.isEmpty || _containsControlCharacter(candidate)) return '';

    final uri = Uri.tryParse(candidate);
    if (uri != null && _isAllowedScene7ImageUri(uri)) {
      return Uri(
        path: _imagePath,
        queryParameters: {'url': uri.toString(), 'raster': 'png-v1'},
      ).toString();
    }
    if (uri != null &&
        uri.scheme.isEmpty &&
        !uri.hasAuthority &&
        uri.path == _imagePath) {
      final values = uri.queryParametersAll['url'];
      final nested = values?.length == 1 ? Uri.tryParse(values!.single) : null;
      if (nested != null && _isAllowedScene7ImageUri(nested)) {
        return Uri(
          path: _imagePath,
          queryParameters: {'url': nested.toString(), 'raster': 'png-v1'},
        ).toString();
      }
    }
    final maximumDataUriLength = (config.maxImageBytes * 4 ~/ 3) + 128;
    if (candidate.length <= maximumDataUriLength &&
        _isSafeRasterDataUri(candidate)) {
      return candidate;
    }
    if (_isSafeAssetPath(candidate)) return candidate;
    return '';
  }

  void _authenticate(HttpRequest request) {
    final trustedHeader = config._trustedAuthHeader;
    if (trustedHeader != null && request.headers.value(trustedHeader) == '1') {
      return;
    }

    final expectedToken = config._bearerToken;
    if (expectedToken != null) {
      final authorization =
          request.headers.value(HttpHeaders.authorizationHeader);
      const prefix = 'Bearer ';
      if (authorization != null &&
          authorization.startsWith(prefix) &&
          _constantTimeEquals(
              authorization.substring(prefix.length), expectedToken)) {
        return;
      }
      request.response.headers.set(
        HttpHeaders.wwwAuthenticateHeader,
        'Bearer realm="curator-proxy"',
      );
      throw const _ProxyHttpException(
        HttpStatus.unauthorized,
        'Authentication is required.',
      );
    }

    final remoteAddress = request.connectionInfo?.remoteAddress;
    if (trustedHeader == null &&
        config.allowUnauthenticatedLoopback &&
        _isLoopbackAddress(config.bindAddress) &&
        remoteAddress != null &&
        _isLoopbackAddress(remoteAddress)) {
      return;
    }

    throw const _ProxyHttpException(
      HttpStatus.unauthorized,
      'Authentication is required.',
    );
  }

  void _enforceRateLimit(HttpRequest request) {
    final now = DateTime.now();
    _rateBuckets.removeWhere(
      (_, bucket) =>
          now.difference(bucket.windowStartedAt) >= config.rateWindow,
    );
    final key = request.connectionInfo?.remoteAddress.address ?? 'unknown';
    final bucket = _rateBuckets.putIfAbsent(key, () => _RateBucket(now));
    if (now.difference(bucket.windowStartedAt) >= config.rateWindow) {
      bucket
        ..windowStartedAt = now
        ..requestCount = 0;
    }
    if (bucket.requestCount >= config.rateLimit) {
      final remaining =
          config.rateWindow - now.difference(bucket.windowStartedAt);
      request.response.headers.set(
        HttpHeaders.retryAfterHeader,
        remaining.inSeconds.clamp(1, config.rateWindow.inSeconds),
      );
      throw const _ProxyHttpException(
        HttpStatus.tooManyRequests,
        'Rate limit exceeded.',
      );
    }
    bucket.requestCount++;
  }

  void _applyCors(HttpRequest request) {
    final requestOrigin = request.headers.value('Origin');
    if (requestOrigin == null) return;
    final normalizedRequestOrigin = _normalizedHttpOrigin(requestOrigin);
    final configuredOrigins = config.allowedOrigin
        ?.split(',')
        .map((origin) => _normalizedHttpOrigin(origin.trim()))
        .whereType<String>()
        .toSet();
    final isExplicitlyAllowed = normalizedRequestOrigin != null &&
        configuredOrigins != null &&
        configuredOrigins.contains(normalizedRequestOrigin);
    final isLoopbackDevelopmentOrigin = config.allowedOrigin == null &&
        config._bearerToken == null &&
        config._trustedAuthHeader == null &&
        config.allowUnauthenticatedLoopback &&
        _isLoopbackAddress(config.bindAddress) &&
        normalizedRequestOrigin != null &&
        _isLoopbackOrigin(normalizedRequestOrigin);
    if (!isExplicitlyAllowed && !isLoopbackDevelopmentOrigin) {
      throw const _ProxyHttpException(
        HttpStatus.forbidden,
        'The request origin is not allowed.',
      );
    }

    request.response.headers.set(
      HttpHeaders.accessControlAllowOriginHeader,
      normalizedRequestOrigin,
    );
    request.response.headers.set(
      'Access-Control-Expose-Headers',
      'X-Request-Id',
    );
    _appendVary(request.response.headers, 'Origin');
  }

  String _nextRequestId() {
    _requestSequence = (_requestSequence + 1) & 0x7fffffff;
    return '${DateTime.now().microsecondsSinceEpoch.toRadixString(16)}-'
        '${_requestSequence.toRadixString(16)}';
  }

  static void _applySecurityHeaders(HttpResponse response) {
    response.headers
      ..set('X-Content-Type-Options', 'nosniff')
      ..set('Referrer-Policy', 'no-referrer')
      ..set(HttpHeaders.cacheControlHeader, 'no-store');
  }
}

final class _DartIoTargetImageFetcher implements CuratorProxyImageFetcher {
  _DartIoTargetImageFetcher() {
    _client.connectionTimeout = const Duration(seconds: 10);
  }

  final HttpClient _client = HttpClient();

  @override
  Future<CuratorProxyImage> fetch(
    Uri uri, {
    required int maxBytes,
    required Duration timeout,
  }) async {
    var current = uri;
    for (var redirectCount = 0; redirectCount <= 3; redirectCount++) {
      if (!_isAllowedScene7ImageUri(current)) {
        throw const _ProxyHttpException(
          HttpStatus.badRequest,
          'The image host is not allowed.',
        );
      }

      final outgoing = await _client.getUrl(current).timeout(timeout);
      outgoing
        ..followRedirects = false
        ..maxRedirects = 0;
      outgoing.headers
        ..set(HttpHeaders.acceptHeader,
            'image/avif,image/webp,image/png,image/jpeg')
        ..set(HttpHeaders.userAgentHeader, 'ShopItemCuratorProxy/1.0');
      final response = await outgoing.close().timeout(timeout);

      if (_isRedirectStatus(response.statusCode)) {
        final location = response.headers.value(HttpHeaders.locationHeader);
        await response.drain<void>();
        if (location == null || redirectCount == 3) {
          throw const _ProxyHttpException(
            HttpStatus.badGateway,
            'Target image redirect could not be followed.',
          );
        }
        final redirected = current.resolve(location);
        if (!_isAllowedScene7ImageUri(redirected)) {
          throw const _ProxyHttpException(
            HttpStatus.badGateway,
            'Target image redirected to a disallowed host.',
          );
        }
        current = redirected;
        continue;
      }

      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        throw const _ProxyHttpException(
          HttpStatus.badGateway,
          'Target image upstream returned an error.',
        );
      }
      final mimeType = response.headers.contentType?.mimeType.toLowerCase();
      if (mimeType == null || !_allowedRasterMimeTypes.contains(mimeType)) {
        await response.drain<void>();
        throw const _ProxyHttpException(
          HttpStatus.badGateway,
          'Target image upstream returned a disallowed content type.',
        );
      }
      final contentLength = response.contentLength;
      if (contentLength > maxBytes) {
        await response.drain<void>();
        throw const _ProxyHttpException(
          HttpStatus.requestEntityTooLarge,
          'Target image exceeds the configured size limit.',
        );
      }

      final bytes = BytesBuilder(copy: false);
      await for (final chunk in response.timeout(timeout)) {
        if (bytes.length + chunk.length > maxBytes) {
          throw const _ProxyHttpException(
            HttpStatus.requestEntityTooLarge,
            'Target image exceeds the configured size limit.',
          );
        }
        bytes.add(chunk);
      }
      return CuratorProxyImage(
        bytes: bytes.takeBytes(),
        contentType: mimeType,
      );
    }

    throw const _ProxyHttpException(
      HttpStatus.badGateway,
      'Target image fetch failed.',
    );
  }

  @override
  void close() => _client.close(force: true);
}

final class _RateBucket {
  _RateBucket(this.windowStartedAt);

  DateTime windowStartedAt;
  int requestCount = 0;
}

final class _ProxyHttpException implements Exception {
  const _ProxyHttpException(
    this.statusCode,
    this.publicMessage, {
    this.code,
  });

  final int statusCode;
  final String publicMessage;
  final String? code;
}

_ProxyHttpException _ocrProxyFailure(OcrException error) {
  return switch (error.kind) {
    OcrFailureKind.engineUnavailable => const _ProxyHttpException(
        503, 'Local OCR engine or language data is unavailable.',
        code: 'ocr_engine_unavailable'),
    OcrFailureKind.invalidImage => const _ProxyHttpException(
        400, 'OCR requires a valid JPEG or PNG within the image limits.',
        code: 'ocr_invalid_image'),
    OcrFailureKind.noItems => const _ProxyHttpException(
        422, 'No readable item list or quantities were found in the image.',
        code: 'ocr_no_items'),
    OcrFailureKind.busy => const _ProxyHttpException(
        429, 'Local OCR is busy. Try again shortly.',
        code: 'ocr_busy'),
    OcrFailureKind.failed => const _ProxyHttpException(
        500, 'Local OCR processing failed.',
        code: 'ocr_failed'),
  };
}

Map<String, dynamic> _ocrItemToJson(ExtractedItemEntry item) => {
      'raw_name': item.rawName,
      'clean_name': item.cleanName,
      'is_personal': item.isPersonal,
      'quantity': item.quantity,
    };

void _requireMethod(HttpRequest request, String expected) {
  if (request.method == expected) return;
  request.response.headers.set(HttpHeaders.allowHeader, expected);
  throw const _ProxyHttpException(
    HttpStatus.methodNotAllowed,
    'HTTP method is not allowed for this endpoint.',
  );
}

void _writeJson(HttpResponse response, int statusCode, Object body) {
  response
    ..statusCode = statusCode
    ..headers.contentType = ContentType.json
    ..write(jsonEncode(body));
}

void _writeJsonError(
    HttpResponse response, int statusCode, String message, String requestId,
    {String? code}) {
  _writeJson(response, statusCode, {
    'error': {
      'status': statusCode,
      'message': message,
      'request_id': requestId,
      if (code != null) 'code': code,
    },
  });
}

String _requiredString(
  Object? value, {
  required String field,
  required int maxLength,
}) {
  final result = _optionalString(value, field: field, maxLength: maxLength);
  if (result == null) {
    throw _ProxyHttpException(
      HttpStatus.badRequest,
      '$field must be a non-empty string.',
    );
  }
  return result;
}

String? _optionalString(
  Object? value, {
  required String field,
  required int maxLength,
}) {
  if (value == null) return null;
  if (value is! String) {
    throw _ProxyHttpException(
      HttpStatus.badRequest,
      '$field must be a string.',
    );
  }
  final result = value.trim();
  if (result.isEmpty) return null;
  if (result.length > maxLength || _containsControlCharacter(result)) {
    throw _ProxyHttpException(
      HttpStatus.badRequest,
      '$field exceeds its validation limits.',
    );
  }
  return result;
}

int _positiveInteger(Object? value,
    {required String field, required int maximum}) {
  if (value is! num || !value.isFinite) {
    throw _ProxyHttpException(
      HttpStatus.badRequest,
      '$field must be an integer.',
    );
  }
  final result = value.toInt();
  if (value != result || result < 1 || result > maximum) {
    throw _ProxyHttpException(
      HttpStatus.badRequest,
      '$field is outside its allowed range.',
    );
  }
  return result;
}

bool _isInspectableTargetUri(String value) {
  final uri = Uri.tryParse(value);
  if (uri == null ||
      uri.userInfo.isNotEmpty ||
      (uri.hasPort && uri.port != 443)) {
    return false;
  }
  return TargetPurchaseUrl.tryParse(value) != null ||
      _isAllowedScene7ImageUri(uri);
}

bool _isAllowedScene7ImageUri(Uri uri) {
  return uri.scheme.toLowerCase() == 'https' &&
      uri.host.toLowerCase() == 'target.scene7.com' &&
      uri.userInfo.isEmpty &&
      (!uri.hasPort || uri.port == 443) &&
      uri.path.startsWith('/is/image/Target/') &&
      !_containsControlCharacter(uri.toString());
}

bool _isSafeRasterDataUri(String value) => RegExp(
      r'^data:image/(?:avif|gif|jpe?g|png|webp);base64,[A-Za-z0-9+/]*={0,2}$',
      caseSensitive: false,
    ).hasMatch(value);

bool _isSafeAssetPath(String value) {
  if (!(value.startsWith('assets/') || value.startsWith('packages/'))) {
    return false;
  }
  return !value.contains('..') &&
      !value.contains(r'\') &&
      !_containsControlCharacter(value);
}

bool _containsControlCharacter(String value) =>
    value.codeUnits.any((unit) => unit < 0x20 || unit == 0x7f);

bool _constantTimeEquals(String actual, String expected) {
  var difference = actual.length ^ expected.length;
  final length =
      actual.length > expected.length ? actual.length : expected.length;
  for (var index = 0; index < length; index++) {
    final actualUnit = index < actual.length ? actual.codeUnitAt(index) : 0;
    final expectedUnit =
        index < expected.length ? expected.codeUnitAt(index) : 0;
    difference |= actualUnit ^ expectedUnit;
  }
  return difference == 0;
}

bool _isLoopbackAddress(InternetAddress address) =>
    address.address == InternetAddress.loopbackIPv4.address ||
    address.address == InternetAddress.loopbackIPv6.address;

String? _normalizedHttpOrigin(String value) {
  final uri = Uri.tryParse(value);
  if (uri == null ||
      !uri.hasAuthority ||
      uri.host.isEmpty ||
      (uri.scheme.toLowerCase() != 'http' &&
          uri.scheme.toLowerCase() != 'https') ||
      uri.userInfo.isNotEmpty ||
      (uri.path.isNotEmpty && uri.path != '/') ||
      uri.hasQuery ||
      uri.hasFragment) {
    return null;
  }
  return uri.origin;
}

bool _isLoopbackOrigin(String normalizedOrigin) {
  final uri = Uri.parse(normalizedOrigin);
  if (uri.host.toLowerCase() == 'localhost') return true;
  final address = InternetAddress.tryParse(uri.host);
  return address != null && _isLoopbackAddress(address);
}

bool _isRedirectStatus(int statusCode) =>
    statusCode == HttpStatus.movedPermanently ||
    statusCode == HttpStatus.found ||
    statusCode == HttpStatus.seeOther ||
    statusCode == HttpStatus.temporaryRedirect ||
    statusCode == HttpStatus.permanentRedirect;

void _appendVary(HttpHeaders headers, String value) {
  final existing = headers.value(HttpHeaders.varyHeader);
  if (existing == null || existing.isEmpty) {
    headers.set(HttpHeaders.varyHeader, value);
    return;
  }
  final values = existing.split(',').map((entry) => entry.trim().toLowerCase());
  if (!values.contains(value.toLowerCase())) {
    headers.set(HttpHeaders.varyHeader, '$existing, $value');
  }
}

String? _nonEmptyOrNull(String? value) {
  if (value == null) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

int _readEnvironmentInt(
  Map<String, String> environment,
  String name, {
  required int fallback,
  required int minimum,
  required int maximum,
}) {
  final raw = environment[name];
  if (raw == null || raw.trim().isEmpty) return fallback;
  final value = int.tryParse(raw.trim());
  if (value == null || value < minimum || value > maximum) {
    throw StateError('$name is outside its allowed numeric range.');
  }
  return value;
}

bool _readEnvironmentBool(
  Map<String, String> environment,
  String name, {
  required bool fallback,
}) {
  final raw = environment[name]?.trim().toLowerCase();
  if (raw == null || raw.isEmpty) return fallback;
  if (raw == 'true' || raw == '1') return true;
  if (raw == 'false' || raw == '0') return false;
  throw StateError('$name must be true or false.');
}

Future<void> main() async {
  final proxy = CuratorProxyServer.fromPlatformEnvironment();
  final server = await proxy.start();
  stdout.writeln(
    'ShopItem Curator proxy listening on '
    '${server.address.address}:${server.port}',
  );

  final shutdown = Completer<void>();
  var isShuttingDown = false;
  Future<void> stop() async {
    if (isShuttingDown) return;
    isShuttingDown = true;
    await proxy.close();
    if (!shutdown.isCompleted) shutdown.complete();
  }

  final subscriptions = <StreamSubscription<ProcessSignal>>[];
  for (final signal in [ProcessSignal.sigint, ProcessSignal.sigterm]) {
    try {
      subscriptions.add(signal.watch().listen((_) => unawaited(stop())));
    } on UnsupportedError {
      // Some platforms expose only one of these signals.
    }
  }
  await shutdown.future;
  for (final subscription in subscriptions) {
    await subscription.cancel();
  }
}

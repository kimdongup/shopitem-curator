import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'core/bloc/curator_bloc.dart';
import 'core/bloc/curator_event.dart';
import 'core/repositories/item_repository.dart';
import 'core/services/backend_proxy_gateway.dart';
import 'core/services/curation_pipeline_service.dart';
import 'core/services/curator_startup_coordinator.dart';
import 'core/services/html_export_service.dart';
import 'ui/adapters/flutter_binary_resource_loader.dart';
import 'ui/screens/curator_screen.dart';
import 'ui/theme/app_colors.dart';

const _configuredBackendUrl = String.fromEnvironment('CURATOR_BACKEND_URL');

/// Resolves the only public build/run setting used by the Flutter client.
///
/// Local Web and native runs default to the loopback proxy. A Web app served
/// from a non-loopback host defaults to its own origin so production can route
/// `/v1/*` to the private proxy.
Uri resolveBackendBaseUri({
  String configuredUrl = _configuredBackendUrl,
  bool? web,
  Uri? applicationBaseUri,
}) {
  final isWeb = web ?? kIsWeb;
  final appBase = applicationBaseUri ?? Uri.base;
  final configured = configuredUrl.trim();

  final useLoopbackDefault = !isWeb || _isLoopbackHost(appBase.host);
  final candidate = configured.isEmpty
      ? useLoopbackDefault
          ? Uri.parse('http://127.0.0.1:8787/')
          : Uri(
              scheme: appBase.scheme,
              userInfo: appBase.userInfo,
              host: appBase.host,
              port: appBase.hasPort ? appBase.port : null,
              path: '/',
            )
      : Uri.tryParse(configured);

  if (candidate == null ||
      !candidate.isAbsolute ||
      (candidate.scheme != 'http' && candidate.scheme != 'https') ||
      (candidate.scheme == 'http' && !_isLoopbackHost(candidate.host)) ||
      candidate.host.isEmpty ||
      candidate.userInfo.isNotEmpty ||
      candidate.hasQuery ||
      candidate.hasFragment) {
    throw ArgumentError.value(
      configuredUrl,
      'CURATOR_BACKEND_URL',
      'must use HTTPS, except for an HTTP loopback development URL, and must '
          'not contain credentials, a query, or a fragment',
    );
  }

  final normalizedPath = candidate.path.isEmpty
      ? '/'
      : candidate.path.endsWith('/')
          ? candidate.path
          : '${candidate.path}/';
  return candidate.replace(path: normalizedPath).normalizePath();
}

bool _isLoopbackHost(String host) {
  final normalized = host.toLowerCase();
  return normalized == 'localhost' ||
      normalized == '127.0.0.1' ||
      normalized == '::1' ||
      normalized == '0:0:0:0:0:0:0:1';
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  final httpClient = http.Client();
  final backendGateway = BackendProxyGateway(
    backendBaseUrl: resolveBackendBaseUri().toString(),
    httpClient: httpClient,
  );
  final resourceLoader = FlutterBinaryResourceLoader(
    httpClient: httpClient,
  );
  final htmlExportService = HtmlExportService(
    resourceLoader: resourceLoader,
  );
  final pipelineService = CurationPipelineService(
    ocrService: backendGateway,
    targetFetcherService: backendGateway,
    resourceLoader: resourceLoader,
  );

  // Flutter is the composition root; the BLoC sees Pure Dart ports only.
  final curatorBloc = CuratorBloc(
    itemRepository: const DefaultItemRepository(),
    pipelineService: pipelineService,
    manifestRebuilder: pipelineService,
    productReviewGateway: backendGateway,
    catalogRescraper: backendGateway,
    documentRepository: backendGateway,
    onDispose: () {
      backendGateway.close();
      httpClient.close();
    },
  );
  final startupCoordinator = CuratorStartupCoordinator(
    backendGateway: backendGateway,
    dispatchEvent: curatorBloc.add,
    readyEvent: const LoadSourceDocumentsEvent(selectFirst: true),
    loadSourceImage: (path) async {
      final byteData = await rootBundle.load(path);
      return byteData.buffer.asUint8List(
        byteData.offsetInBytes,
        byteData.lengthInBytes,
      );
    },
  );

  runApp(ShopItemCuratorApp(
    curatorBloc: curatorBloc,
    htmlExportService: htmlExportService,
    onShutdown: startupCoordinator.cancel,
    onRetryInitialization: () {
      unawaited(startupCoordinator.retry());
    },
  ));

  // Mount the UI before startup polling. Only the safe readiness GET repeats;
  // the OCR/catalog POST pipeline is submitted exactly once after readiness.
  unawaited(startupCoordinator.start());
}

class ShopItemCuratorApp extends StatefulWidget {
  const ShopItemCuratorApp({
    super.key,
    required this.curatorBloc,
    this.htmlExportService = const HtmlExportService(),
    this.catalogProxyEnabled = true,
    this.onShutdown,
    this.onRetryInitialization,
  });

  final CuratorBloc curatorBloc;
  final HtmlExportService htmlExportService;
  final bool catalogProxyEnabled;
  final VoidCallback? onShutdown;
  final VoidCallback? onRetryInitialization;

  @override
  State<ShopItemCuratorApp> createState() => _ShopItemCuratorAppState();
}

class _ShopItemCuratorAppState extends State<ShopItemCuratorApp> {
  @override
  void dispose() {
    widget.onShutdown?.call();
    unawaited(widget.curatorBloc.close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ShopItem Curator',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: AppColors.background,
        colorScheme: const ColorScheme.dark(
          primary: AppColors.targetRed,
          surface: AppColors.surface,
        ),
        useMaterial3: true,
      ),
      home: CuratorScreen(
        bloc: widget.curatorBloc,
        htmlExportService: widget.htmlExportService,
        catalogProxyEnabled: widget.catalogProxyEnabled,
        onRetryInitialization: widget.onRetryInitialization,
      ),
    );
  }
}

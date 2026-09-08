import 'dart:convert';
import 'dart:io';

import 'package:shopitem_curator/core/models/matching_options.dart';
import 'package:shopitem_curator/core/services/scraper/concurrency/concurrent_executor.dart';
import 'package:shopitem_curator/core/services/scraper/concurrency/rate_limiter.dart';
import 'package:shopitem_curator/core/services/scraper/session/session_pool.dart';
import 'package:shopitem_curator/core/services/scraper/target_request_policy.dart';
import 'package:shopitem_curator/core/services/target_fetcher_service.dart';
import 'matching_browser_client.dart';
import 'matching_http_client.dart';

final class MatchingStrategyException implements Exception {
  const MatchingStrategyException(this.statusCode, this.message);
  final int statusCode;
  final String message;
}

/// Process-wide registry: per-option caches and clients, shared access breaker.
/// UI flags cannot register proxies, inject headers or start arbitrary commands.
final class MatchingStrategyRegistry {
  MatchingStrategyRegistry(
      {required this.browser,
      this.proxies = const [],
      this.proxyConfigurationInvalid = false,
      this.redSkyApiKey,
      List<Map<String, String>>? headerProfiles,
      MatchingRequestScheduler? scheduler})
      : _headers = headerProfiles,
        _scheduler = scheduler ?? MatchingRequestScheduler();

  factory MatchingStrategyRegistry.fromEnvironment() {
    final env = Platform.environment;
    var invalid = false;
    var proxies = <MatchingProxy>[];
    try {
      final raw = jsonDecode(env['CURATOR_MATCHING_PROXY_POOL'] ?? '[]');
      if (raw is! List || raw.length > 16) throw const FormatException();
      proxies = raw.map(MatchingProxy.fromJson).toList();
    } on Object {
      invalid = true;
    }
    return MatchingStrategyRegistry(
        proxies: proxies,
        proxyConfigurationInvalid: invalid,
        redSkyApiKey: env['CURATOR_TARGET_REDSKY_KEY'],
        browser: MatchingBrowserRuntime(
            node: env['CURATOR_BROWSER_NODE'] ?? 'node',
            executable: env['CURATOR_BROWSER_EXECUTABLE'] ??
                (Platform.isMacOS
                    ? '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'
                    : '/usr/bin/chromium')));
  }

  final MatchingBrowserRuntime browser;
  final List<MatchingProxy> proxies;
  final bool proxyConfigurationInvalid;
  final String? redSkyApiKey;
  final TargetAccessState accessState = TargetAccessState();
  final MatchingRequestScheduler _scheduler;
  List<Map<String, String>>? _headers;
  final Map<String, TargetFetcherService> _services = {};
  final List<void Function()> _closeClients = [];
  int _profile = 0;
  bool _closed = false;

  Future<List<MatchingCapability>> capabilities() async {
    final probe = await browser.probe();
    final version = probe['chrome_version'];
    if (_headers == null &&
        version is String &&
        RegExp(r'^\d+\.\d+\.\d+\.\d+$').hasMatch(version)) {
      _headers = chromeProfiles(version);
    }
    final hasBrowser = probe['available'] == true;
    return [
      for (final strategy in MatchingStrategy.values)
        switch (strategy) {
          MatchingStrategy.headerRotation => MatchingCapability(
              strategy: strategy,
              available: _headers?.isNotEmpty ?? false,
              reason: (_headers?.isNotEmpty ?? false)
                  ? '설치된 Chrome 버전 기반 HTTP 프로필'
                  : 'Chrome 실행 파일과 Node 경로를 확인하세요.'),
          MatchingStrategy.proxyPool => MatchingCapability(
              strategy: strategy,
              available: proxies.isNotEmpty && !proxyConfigurationInvalid,
              reason: proxyConfigurationInvalid
                  ? '서버 프록시 설정 형식이 잘못되었습니다.'
                  : proxies.isEmpty
                      ? '서버 CURATOR_MATCHING_PROXY_POOL 설정 필요 · 자동 구매 없음'
                      : '운영자 등록 프록시 ${proxies.length}개'),
          MatchingStrategy.randomDelay => MatchingCapability(
              strategy: strategy,
              available: true,
              reason: '1.2~3.8초 · 요청 폭주 완화'),
          _ => MatchingCapability(
              strategy: strategy,
              available: hasBrowser,
              reason: hasBrowser
                  ? '별도 Chromium · 사용자 프로필 연결 안 함'
                  : 'server/browser에서 npm ci 실행 후 Node·Chrome 경로를 확인하고 백엔드를 재시작하세요.'),
        }
    ];
  }

  Future<TargetFetcherService?> service(Object? rawOptions) async {
    if (_closed) {
      throw const MatchingStrategyException(
          503, 'Matching strategies are closed.');
    }
    late final MatchingOptions options;
    try {
      options = MatchingOptions.fromJson(rawOptions);
    } on FormatException {
      throw const MatchingStrategyException(
          400, 'Invalid matching strategy selection.');
    }
    if (options.isDefault) return null;
    final available = await capabilities();
    for (final selected in options.enabled) {
      if (!available.any((c) => c.strategy == selected && c.available)) {
        throw const MatchingStrategyException(
            503, 'The selected matching strategy is not configured.');
      }
    }
    return _services.putIfAbsent(options.key, () {
      final selectedProxies =
          options.has(MatchingStrategy.proxyPool) ? proxies : <MatchingProxy>[];
      final client = options.usesBrowser
          ? MatchingBrowserClient(
              runtime: browser,
              options: options,
              accessState: accessState,
              proxies: selectedProxies)
          : MatchingHttpClient(proxies: selectedProxies);
      _closeClients.add(client.close);
      final requests = TargetRequestPolicy(
          accessState: accessState,
          beforeRequest: () => _scheduler.wait(
              randomized: options.has(MatchingStrategy.randomDelay)),
          headersFor:
              options.has(MatchingStrategy.headerRotation) ? headersFor : null,
          transportTimeout: options.usesBrowser
              ? const Duration(seconds: 22)
              : const Duration(seconds: 10));
      return TargetFetcherService(
          httpClient: client,
          preferLiveCatalog: true,
          // Browser mode observes requests made by the page, not copied API keys.
          redSkyApiKey: options.usesBrowser ? null : redSkyApiKey,
          preferObservedProducts: options.has(MatchingStrategy.observedJson),
          sessionPool: SessionPool(requestPolicy: requests),
          concurrentExecutor: const ConcurrentExecutor(
              defaultConcurrency: 1,
              rateLimiter: RateLimiter(minDelayMs: 0, maxDelayMs: 0)));
    });
  }

  Map<String, String> headersFor(Uri uri) {
    final profiles = _headers;
    if (profiles == null || profiles.isEmpty) {
      return TargetRequestPolicy.headers;
    }
    return {
      ...profiles[_profile++ % profiles.length],
      'Accept': uri.host == 'redsky.target.com'
          ? 'application/json'
          : 'text/html,application/xhtml+xml,application/json;q=0.9,*/*;q=0.8',
      'Referer': 'https://www.target.com/',
    };
  }

  static List<Map<String, String>> chromeProfiles(String version) {
    final major = version.split('.').first;
    return [
      for (final platform in ['macOS', 'Windows'])
        {
          'User-Agent':
              'Mozilla/5.0 (${platform == 'macOS' ? 'Macintosh; Intel Mac OS X 10_15_7' : 'Windows NT 10.0; Win64; x64'}) '
                  'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/$version Safari/537.36',
          'Accept-Language': 'en-US,en;q=0.9',
          'Sec-CH-UA':
              '"Chromium";v="$major", "Google Chrome";v="$major", "Not_A Brand";v="99"',
          'Sec-CH-UA-Mobile': '?0', 'Sec-CH-UA-Platform': '"$platform"',
          // No Cookie, Authorization, Host, or unsupported compression claims.
        }
    ];
  }

  void close() {
    _closed = true;
    _scheduler.close();
    browser.close();
    for (final service in _services.values) {
      service.close();
    }
    for (final close in _closeClients) {
      close();
    }
    _services.clear();
    _closeClients.clear();
  }
}

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:shopitem_curator/core/services/scraper/target_request_policy.dart';

/// Operator-provided HTTP CONNECT proxies. No discovery, signup or purchase.
final class MatchingProxy {
  const MatchingProxy(this.host, this.port, this.username, this.password);
  final String host;
  final int port;
  final String? username;
  final String? password;
  factory MatchingProxy.fromJson(Object? value) {
    if (value is! Map ||
        value.keys.any((k) => !['url', 'username', 'password'].contains(k))) {
      throw const FormatException('Invalid matching proxy configuration.');
    }
    final uri =
        value['url'] is String ? Uri.tryParse(value['url'] as String) : null;
    final user = value['username'], password = value['password'];
    if (uri == null ||
        uri.scheme != 'http' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        (uri.path.isNotEmpty && uri.path != '/') ||
        uri.port < 1 ||
        uri.port > 65535 ||
        (user != null && user is! String) ||
        (password != null && password is! String) ||
        (user == null) != (password == null)) {
      throw const FormatException(
          'Use an HTTP proxy URL and separate credentials.');
    }
    return MatchingProxy(
        uri.host, uri.port, user as String?, password as String?);
  }
  Map<String, Object?> browserJson() => {
        'server': 'http://${host.contains(':') ? '[$host]' : host}:$port',
        if (username != null) 'username': username,
        if (password != null) 'password': password
      };
  @override
  String toString() => 'MatchingProxy(<redacted>)';
}

/// Every advanced HTTP fetch is bounded and redirects are validated manually.
/// A failed proxy never silently falls back to the direct network connection.
final class MatchingHttpClient extends http.BaseClient {
  MatchingHttpClient(
      {List<MatchingProxy> proxies = const [],
      this.maxBytes = 2 * 1024 * 1024,
      http.Client Function(MatchingProxy?)? createClient})
      : _clients = (proxies.isEmpty ? <MatchingProxy?>[null] : proxies)
            .map((proxy) => (createClient ?? _createClient)(proxy))
            .toList();
  final List<http.Client> _clients;
  final int maxBytes;
  int _index = 0;
  bool _closed = false;
  static bool allowed(Uri uri) =>
      uri.scheme == 'https' &&
      uri.userInfo.isEmpty &&
      (!uri.hasPort || uri.port == 443) &&
      ['target.com', 'www.target.com', 'redsky.target.com', 'target.scene7.com']
          .contains(uri.host);

  static http.Client _createClient(MatchingProxy? proxy) {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 6);
    if (proxy != null) {
      client.findProxy = (_) =>
          'PROXY ${proxy.host.contains(':') ? '[${proxy.host}]' : proxy.host}:${proxy.port}';
      if (proxy.username != null) {
        client.authenticateProxy = (host, port, scheme, realm) async {
          if (host != proxy.host ||
              port != proxy.port ||
              scheme.toLowerCase() != 'basic') {
            return false;
          }
          client.addProxyCredentials(host, port, realm ?? '',
              HttpClientBasicCredentials(proxy.username!, proxy.password!));
          return true;
        };
      }
    } else {
      client.findProxy = (_) => 'DIRECT';
    }
    return IOClient(client);
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (_closed || request.method != 'GET' || !allowed(request.url)) {
      throw const TargetLookupException(TargetLookupFailure.invalidResponse);
    }
    final client = _clients[_index++ % _clients.length];
    final abort = Completer<void>();
    final deadline = Timer(const Duration(seconds: 8), () => abort.complete());
    var uri = request.url;
    try {
      for (var hop = 0; hop <= 3; hop++) {
        if (_closed || !allowed(uri)) {
          throw const TargetLookupException(
              TargetLookupFailure.invalidResponse);
        }
        final next =
            http.AbortableRequest('GET', uri, abortTrigger: abort.future)
              ..followRedirects = false;
        next.headers.addAll(request.headers);
        final response =
            await client.send(next).timeout(const Duration(seconds: 7));
        if ([301, 302, 303, 307, 308].contains(response.statusCode)) {
          await response.stream.take(1).drain<void>();
          final location = response.headers['location'];
          if (location == null || hop == 3) {
            throw const TargetLookupException(
                TargetLookupFailure.invalidResponse);
          }
          uri = uri.resolve(location);
          continue;
        }
        final bytes = <int>[];
        await for (final chunk
            in response.stream.timeout(const Duration(seconds: 7))) {
          if (bytes.length + chunk.length > maxBytes) {
            throw const TargetLookupException(
                TargetLookupFailure.invalidResponse);
          }
          bytes.addAll(chunk);
        }
        return http.StreamedResponse(Stream.value(bytes), response.statusCode,
            headers: response.headers,
            request: request,
            contentLength: bytes.length);
      }
      throw const TargetLookupException(TargetLookupFailure.invalidResponse);
    } finally {
      deadline.cancel();
      if (!abort.isCompleted) abort.complete();
    }
  }

  @override
  void close() {
    _closed = true;
    for (final client in _clients) {
      client.close();
    }
  }
}

/// Process-wide spacing, including clients using different strategy flags.
final class MatchingRequestScheduler {
  MatchingRequestScheduler(
      {Random? random, Future<void> Function(Duration)? delay})
      : _random = random ?? Random.secure(),
        _delay = delay ?? Future<void>.delayed;
  final Random _random;
  final Future<void> Function(Duration) _delay;
  Future<void> _tail = Future.value();
  bool _closed = false;
  Future<void> wait({required bool randomized}) {
    final result = _tail.then((_) async {
      if (_closed) {
        throw const TargetLookupException(TargetLookupFailure.upstreamFailure);
      }
      await _delay(Duration(
          milliseconds: randomized ? 1200 + _random.nextInt(2601) : 150));
      if (_closed) {
        throw const TargetLookupException(TargetLookupFailure.upstreamFailure);
      }
    });
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  void close() {
    _closed = true;
  }
}

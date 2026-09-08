import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

/// Single-owner preview gateway. This is not a multi-user account system.
/// All browser documents are session protected. The only exception is the
/// narrow extension bridge, authenticated by the proxy's project capabilities.
final class CuratorWebGateway {
  CuratorWebGateway({
    required this.publicOrigin,
    required this.upstream,
    required this.webDirectory,
    required String password,
    this.sessionLifetime = const Duration(hours: 8),
    this.maxBodyBytes = 12 * 1024 * 1024,
    this.requestTimeout = const Duration(seconds: 55),
    DateTime Function()? now,
  })  : _password = utf8.encode(password),
        _now = now ?? DateTime.now {
    if (password.length < 20 ||
        password.length > 256 ||
        publicOrigin.hasQuery ||
        publicOrigin.hasFragment ||
        publicOrigin.userInfo.isNotEmpty ||
        (publicOrigin.path.isNotEmpty && publicOrigin.path != '/') ||
        !(publicOrigin.scheme == 'https' ||
            (publicOrigin.scheme == 'http' &&
                publicOrigin.host == '127.0.0.1')) ||
        upstream.scheme != 'http' ||
        upstream.host != '127.0.0.1' ||
        upstream.userInfo.isNotEmpty ||
        upstream.hasQuery ||
        upstream.hasFragment ||
        upstream.path.isNotEmpty && upstream.path != '/' ||
        maxBodyBytes < 1 ||
        sessionLifetime <= Duration.zero) {
      throw ArgumentError('Invalid preview gateway configuration.');
    }
  }

  final Uri publicOrigin, upstream;
  final Directory webDirectory;
  final Duration sessionLifetime, requestTimeout;
  final int maxBodyBytes;
  final List<int> _password;
  final DateTime Function() _now;
  final _random = Random.secure();
  final _client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
  final Map<String, DateTime> _sessions = {};
  HttpServer? _server;
  DateTime? _window;
  int _loginAttempts = 0, _bridgeRequests = 0, _apiRequests = 0;
  int _inFlight = 0;
  static const trustedHeader = 'X-Curator-Authenticated';
  static const _cookieName = 'curator_preview';
  static final _extension = RegExp(r'^[a-p]{32}$');
  static const _bridgePaths = {
    '/v1/browser-bridge/pair',
    '/v1/browser-bridge/read',
    '/v1/browser-bridge/select',
    '/v1/browser-bridge/disconnect',
  };

  Future<HttpServer> start({InternetAddress? address, int port = 0}) async {
    if (_server != null) throw StateError('Gateway already running.');
    if (!await File('${webDirectory.path}/index.html').exists()) {
      throw StateError('Flutter Web build is missing.');
    }
    final server =
        await HttpServer.bind(address ?? InternetAddress.anyIPv4, port);
    server.idleTimeout = const Duration(seconds: 15);
    server.autoCompress = true;
    _server = server;
    server.listen((request) => unawaited(_handle(request)));
    return server;
  }

  Future<void> close() async {
    _sessions.clear();
    _client.close(force: true);
    await _server?.close(force: true);
    _server = null;
  }

  bool _signedIn(HttpRequest request) {
    _sessions.removeWhere((_, expiry) => !expiry.isAfter(_now()));
    final cookies =
        request.cookies.where((c) => c.name == _cookieName).toList();
    return cookies.length == 1 && _sessions.containsKey(cookies.single.value);
  }

  void _limits() {
    if (_window == null ||
        _now().difference(_window!) >= const Duration(minutes: 1)) {
      _window = _now();
      _loginAttempts = _bridgeRequests = _apiRequests = 0;
    }
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    Timer? deadline;
    var admitted = false;
    try {
      response.headers
        ..set('Cache-Control', 'no-store')
        ..set('X-Content-Type-Options', 'nosniff')
        // no-referrer makes Chrome send Origin: null on form POSTs, which
        // breaks the exact-origin CSRF check. Do not disclose to other sites.
        ..set('Referrer-Policy', 'same-origin')
        ..set('X-Frame-Options', 'DENY')
        ..set('X-Robots-Tag', 'noindex, nofollow')
        ..set('Content-Security-Policy',
            "default-src 'self'; script-src 'self' 'wasm-unsafe-eval'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; font-src 'self'; connect-src 'self'; worker-src 'self' blob:; object-src 'none'; base-uri 'self'; frame-ancestors 'none'; form-action 'self'");
      if (publicOrigin.scheme == 'https') {
        response.headers.set('Strict-Transport-Security', 'max-age=31536000');
      }
      final path = request.uri.path;
      final health = path == '/health' || path == '/ready';
      // Health probes can use an internal Host. No private data or mutations
      // are available there. All other routes require the configured Host.
      if (!health && request.headers.value('Host') != publicOrigin.authority) {
        throw const _WebError(421);
      }
      if (_inFlight >= 6) throw const _WebError(429);
      _inFlight++;
      admitted = true;
      _limits();
      deadline = Timer(requestTimeout, () {
        unawaited(response
            .detachSocket(writeHeaders: false)
            .then((s) => s.destroy())
            .catchError((Object _) {}));
      });
      if (health) {
        if (request.method != 'GET') throw const _WebError(405);
        await _forward(request, bridge: false, health: true);
        return;
      }
      if (path.startsWith('/v1/browser-bridge/')) {
        if (!_bridgePaths.contains(path)) throw const _WebError(404);
        if (++_bridgeRequests > 120) throw const _WebError(429);
        final origin = request.headers.value('Origin');
        final id = request.headers.value('X-Curator-Extension-Id');
        if (request.method == 'OPTIONS') {
          if (origin == null ||
              !RegExp(r'^chrome-extension://[a-p]{32}$').hasMatch(origin)) {
            throw const _WebError(403);
          }
          response.headers
            ..set('Access-Control-Allow-Origin', origin)
            ..set('Vary', 'Origin')
            ..set('Access-Control-Allow-Methods', 'POST, OPTIONS')
            ..set('Access-Control-Allow-Headers',
                'Authorization, Content-Type, X-Curator-Extension-Id');
          response.statusCode = 204;
          return;
        }
        if (id == null ||
            !_extension.hasMatch(id) ||
            (origin != null && origin != 'chrome-extension://$id')) {
          throw const _WebError(403);
        }
        if (request.method != 'POST') throw const _WebError(405);
        await _forward(request, bridge: true);
        return;
      }
      final origin = request.headers.value('Origin');
      if (origin != null && origin != publicOrigin.origin) {
        throw const _WebError(403);
      }
      if (!{'GET', 'HEAD'}.contains(request.method) &&
          origin != publicOrigin.origin) {
        throw const _WebError(403);
      }
      if (path == '/login') {
        await _login(request);
        return;
      }
      if (!_signedIn(request)) {
        if (path.startsWith('/v1/')) throw const _WebError(401);
        response
          ..statusCode = 303
          ..headers.set('Location', '/login');
        return;
      }
      if (path == '/logout') {
        if (request.method == 'GET') {
          response.headers.contentType = ContentType.html;
          response.write(
              '<!doctype html><html lang="ko"><meta charset="utf-8"><title>Curator 로그아웃</title><h1>로그아웃</h1><p>이 브라우저의 접속 세션을 종료합니다. 확장 연결은 확장 팝업에서 별도로 해제하세요.</p><form method="post" action="/logout"><button>로그아웃 확인</button></form><a href="/">앱으로 돌아가기</a></html>');
          return;
        }
        if (request.method != 'POST') throw const _WebError(405);
        for (final cookie
            in request.cookies.where((c) => c.name == _cookieName)) {
          _sessions.remove(cookie.value);
        }
        response.cookies.add(_cookie('', maxAge: 0));
        response
          ..statusCode = 303
          ..headers.set('Location', '/login');
        return;
      }
      if (path.startsWith('/v1/')) {
        if (++_apiRequests > 180) throw const _WebError(429);
        if (!{'GET', 'POST', 'DELETE'}.contains(request.method)) {
          throw const _WebError(405);
        }
        await _forward(request, bridge: false);
      } else {
        await _static(request);
      }
    } on _WebError catch (e) {
      try {
        response.statusCode = e.status;
        if (e.status == 429) response.headers.set('Retry-After', '60');
        response.headers.contentType = ContentType.json;
        response.write(jsonEncode({
          'error': {
            'status': e.status,
            'message': e.status == 401
                ? 'Session expired. Reload and sign in again.'
                : 'Request rejected by preview gateway.'
          }
        }));
      } catch (_) {
        // A streaming response may already have sent headers or timed out.
        // Never leak an unhandled error into the server's root isolate.
        try {
          (await response.detachSocket(writeHeaders: false)).destroy();
        } catch (_) {}
      }
    } catch (_) {
      try {
        response.statusCode = 502;
        response.write('Preview request failed.');
      } catch (_) {}
    } finally {
      deadline?.cancel();
      if (admitted) _inFlight--;
      try {
        await response.close();
      } catch (_) {}
    }
  }

  Cookie _cookie(String value, {int? maxAge}) => Cookie(_cookieName, value)
    ..httpOnly = true
    ..secure = publicOrigin.scheme == 'https'
    ..sameSite = SameSite.strict
    ..path = '/'
    ..maxAge = maxAge ?? sessionLifetime.inSeconds;

  Future<List<int>> _body(HttpRequest request, int limit) async {
    if (request.contentLength > limit) throw const _WebError(413);
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in request.timeout(const Duration(seconds: 15))) {
      if (bytes.length + chunk.length > limit) throw const _WebError(413);
      bytes.add(chunk);
    }
    return bytes.takeBytes();
  }

  Future<void> _login(HttpRequest request) async {
    if (request.method == 'GET') {
      request.response.headers.contentType = ContentType.html;
      request.response.write(
          '''<!doctype html><html lang="ko"><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>Curator 로그인</title>
<style>body{background:#101922;color:#eef5fa;font:18px system-ui;max-width:520px;margin:12vh auto;padding:24px}input,button{font:inherit;padding:12px;box-sizing:border-box;width:100%;margin:12px 0}small{color:#afc2d0}</style>
<h1>ShopItem Curator</h1><p>비밀번호로 보호된 개인용 체험 공간입니다.</p><form method="post" action="/login"><label>접속 비밀번호<input type="password" name="password" required maxlength="256" autocomplete="current-password"></label><button>로그인</button></form>
<small>무료 서버가 쉬거나 재시작되면 업로드 문서와 선택 상품이 사라집니다. 필요한 결과는 HTML로 다운로드하세요. 비밀번호를 공유하면 문서 열람·삭제 권한도 공유됩니다.</small></html>''');
      return;
    }
    if (request.method != 'POST') throw const _WebError(405);
    if (++_loginAttempts > 10) throw const _WebError(429);
    if (request.headers.contentType?.mimeType !=
        'application/x-www-form-urlencoded') {
      throw const _WebError(415);
    }
    final form = Uri.splitQueryString(utf8.decode(await _body(request, 2048)));
    final actual = utf8.encode(form['password'] ?? '');
    var difference = actual.length ^ _password.length;
    for (var i = 0; i < _password.length; i++) {
      difference |= _password[i] ^ (i < actual.length ? actual[i] : 0);
    }
    if (difference != 0) throw const _WebError(401);
    _sessions.removeWhere((_, expiry) => !expiry.isAfter(_now()));
    if (_sessions.length >= 10) _sessions.remove(_sessions.keys.first);
    final token =
        base64Url.encode(List.generate(32, (_) => _random.nextInt(256)));
    _sessions[token] = _now().add(sessionLifetime);
    request.response.cookies.add(_cookie(token));
    request.response
      ..statusCode = 303
      ..headers.set('Location', '/');
  }

  Future<void> _forward(HttpRequest request,
      {required bool bridge, bool health = false}) async {
    if (!health &&
        request.method != 'GET' &&
        request.headers.contentType?.mimeType != 'application/json') {
      throw const _WebError(415);
    }
    final body = await _body(request, maxBodyBytes);
    final target = upstream.replace(
        path: request.uri.path,
        query: request.uri.hasQuery ? request.uri.query : null);
    final outgoing = await _client.openUrl(request.method, target);
    outgoing.followRedirects = false;
    // Header allowlist: never forward cookies, forwarding headers or client auth
    // on app routes. Extension Authorization is a different project capability.
    outgoing.headers.set(trustedHeader, '1');
    outgoing.headers.contentType = request.headers.contentType;
    if (bridge) {
      for (final name in [
        'Authorization',
        'Origin',
        'X-Curator-Extension-Id'
      ]) {
        final value = request.headers.value(name);
        if (value != null) outgoing.headers.set(name, value);
      }
    }
    outgoing.contentLength = body.length;
    outgoing.add(body);
    final cancellation = Timer(requestTimeout, () => outgoing.abort());
    try {
      final result = await outgoing.close();
      request.response.statusCode = result.statusCode;
      for (final name in [
        'Content-Type',
        'X-Request-Id',
        'Retry-After',
        if (bridge) 'Access-Control-Allow-Origin',
        if (bridge) 'Vary'
      ]) {
        final value = result.headers.value(name);
        if (value != null) request.response.headers.set(name, value);
      }
      var bytes = 0;
      await for (final chunk in result) {
        bytes += chunk.length;
        if (bytes > 16 * 1024 * 1024) {
          outgoing.abort();
          throw const _WebError(502);
        }
        request.response.add(chunk);
      }
    } finally {
      cancellation.cancel();
    }
  }

  Future<void> _static(HttpRequest request) async {
    if (!{'GET', 'HEAD'}.contains(request.method)) throw const _WebError(405);
    final segments = request.uri.pathSegments;
    if (segments.any((s) =>
        s.startsWith('.') ||
        s.contains('/') ||
        s.contains('\\') ||
        s.contains('\x00'))) {
      throw const _WebError(404);
    }
    final root = await webDirectory.resolveSymbolicLinks();
    var parent = root;
    for (final segment in segments.where((s) => s.isNotEmpty)) {
      parent = '$parent/$segment';
      if (await FileSystemEntity.type(parent, followLinks: false) ==
          FileSystemEntityType.link) {
        throw const _WebError(404);
      }
    }
    var file = File('$root/${segments.join('/')}');
    if (!await file.exists()) {
      if (segments.isNotEmpty && segments.last.contains('.')) {
        throw const _WebError(404);
      }
      file = File('$root/index.html');
    }
    final resolved = await file.resolveSymbolicLinks();
    if (!resolved.startsWith('$root/')) throw const _WebError(404);
    final ext = resolved.split('.').last;
    final mime = {
          'html': 'text/html; charset=utf-8',
          'js': 'application/javascript',
          'json': 'application/json',
          'wasm': 'application/wasm',
          'css': 'text/css',
          'png': 'image/png',
          'jpg': 'image/jpeg',
          'svg': 'image/svg+xml',
          'ico': 'image/x-icon',
          'ttf': 'font/ttf',
          'otf': 'font/otf',
          'woff2': 'font/woff2'
        }[ext] ??
        'application/octet-stream';
    request.response.headers.contentType = ContentType.parse(mime);
    if (request.method == 'GET') {
      await request.response.addStream(file.openRead());
    }
  }
}

final class _WebError implements Exception {
  const _WebError(this.status);
  final int status;
}

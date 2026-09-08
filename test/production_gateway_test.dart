import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import '../server/curator_web_gateway.dart';

void main() {
  const password = 'only-a-test-password-not-for-deployment';
  const host = 'curator-preview.onrender.com';
  late Directory root;
  late HttpServer upstream;
  late HttpClient client;
  late CuratorWebGateway gateway;
  late Uri base;
  late List<Map<String, Object?>> forwarded;
  var now = DateTime(2026, 9, 7);

  setUp(() async {
    now = DateTime(2026, 9, 7);
    root = await Directory.systemTemp.createTemp('curator-gateway-test-');
    await File('${root.path}/index.html')
        .writeAsString('<html>PRIVATE_APP</html>');
    await File('${root.path}/main.dart.js').writeAsString('PRIVATE_BUNDLE');
    client = HttpClient();
    forwarded = [];
    upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    upstream.listen((request) async {
      final body = await utf8.decoder.bind(request).join();
      forwarded.add({
        'path': request.uri.path,
        'body': body,
        'trusted': request.headers.value(CuratorWebGateway.trustedHeader),
        'authorization': request.headers.value('Authorization'),
        'cookie': request.headers.value('Cookie'),
        'origin': request.headers.value('Origin'),
        'extension': request.headers.value('X-Curator-Extension-Id'),
        'forwarded': request.headers.value('X-Forwarded-For'),
      });
      request.response.headers.contentType = ContentType.json;
      request.response.write('{"status":"ready"}');
      await request.response.close();
    });
    gateway = CuratorWebGateway(
        publicOrigin: Uri.parse('https://$host'),
        upstream: Uri.parse('http://127.0.0.1:${upstream.port}'),
        webDirectory: root,
        password: password,
        maxBodyBytes: 128,
        now: () => now);
    final server = await gateway.start(address: InternetAddress.loopbackIPv4);
    base = Uri.parse('http://127.0.0.1:${server.port}');
  });
  tearDown(() async {
    client.close(force: true);
    await gateway.close();
    await upstream.close(force: true);
    await root.delete(recursive: true);
  });

  Future<({int status, String body, HttpHeaders headers})> send(String path,
      {String method = 'GET',
      Map<String, String> headers = const {},
      String? body}) async {
    final request = await client.openUrl(method, base.resolve(path));
    request.followRedirects = false;
    request.headers.set('Host', host);
    headers.forEach(request.headers.set);
    if (body != null) request.write(body);
    final response = await request.close();
    return (
      status: response.statusCode,
      headers: response.headers,
      body: await utf8.decoder.bind(response).join()
    );
  }

  Future<String> login() async {
    final response = await send('/login',
        method: 'POST',
        headers: {
          'Origin': 'https://$host',
          'Content-Type': 'application/x-www-form-urlencoded',
        },
        body: 'password=$password');
    expect(response.status, 303);
    final cookie = response.headers.value('Set-Cookie')!;
    expect(cookie.toLowerCase(), contains('httponly'));
    expect(cookie.toLowerCase(), contains('secure'));
    expect(cookie.toLowerCase(), contains('samesite=strict'));
    return cookie.split(';').first;
  }

  test('root/assets/API require a session; health remains available', () async {
    expect((await send('/')).status, 303);
    expect((await send('/main.dart.js')).status, 303);
    expect(
        (await send('/v1/documents', headers: {'X-Curator-Authenticated': '1'}))
            .status,
        401);
    expect(forwarded, isEmpty);
    expect((await send('/ready')).status, 200);
    expect((await send('/login')).body, contains('type="password"'));
    expect(
        (await send('/login')).headers.value('Referrer-Policy'), 'same-origin');
    expect((await send('/login')).body, isNot(contains(password)));
  });

  test('login rejects wrong password, foreign origin and missing origin',
      () async {
    for (final origin in ['https://evil.test', 'null', '']) {
      expect(
          (await send('/login',
                  method: 'POST',
                  headers: {
                    if (origin.isNotEmpty) 'Origin': origin,
                    'Content-Type': 'application/x-www-form-urlencoded',
                  },
                  body: 'password=$password'))
              .status,
          403);
    }
    expect(
        (await send('/login',
                method: 'POST',
                headers: {
                  'Origin': 'https://$host',
                  'Content-Type': 'application/x-www-form-urlencoded',
                },
                body: 'password=wrong'))
            .status,
        401);
  });

  test('authenticated forwarding strips spoofed headers and user credentials',
      () async {
    final cookie = await login();
    final response = await send('/v1/documents/read',
        method: 'POST',
        headers: {
          'Origin': 'https://$host',
          'Cookie': cookie,
          'Content-Type': 'application/json',
          'Authorization': 'Bearer attacker',
          'X-Curator-Authenticated': 'evil',
          'X-Forwarded-For': 'evil',
        },
        body: '{}');
    expect(response.status, 200);
    expect(forwarded.single, containsPair('trusted', '1'));
    for (final key in ['authorization', 'cookie', 'origin', 'forwarded']) {
      expect(forwarded.single[key], isNull);
    }
    expect((await send('/', headers: {'Cookie': cookie})).body,
        contains('PRIVATE_APP'));
    expect((await send('/main.dart.js', headers: {'Cookie': cookie})).body,
        'PRIVATE_BUNDLE');
    expect((await send('/project/example', headers: {'Cookie': cookie})).body,
        contains('PRIVATE_APP'));
    expect(
        (await send('/missing.js', headers: {'Cookie': cookie})).status, 404);
  });

  test('mutations reject CSRF, non-JSON and oversized bodies', () async {
    final cookie = await login();
    expect(
        (await send('/v1/documents',
                method: 'POST', headers: {'Cookie': cookie}))
            .status,
        403);
    final headers = {'Cookie': cookie, 'Origin': 'https://$host'};
    expect(
        (await send('/v1/documents',
                method: 'POST', headers: headers, body: '{}'))
            .status,
        415);
    expect(
        (await send('/v1/documents',
                method: 'POST',
                headers: {...headers, 'Content-Type': 'application/json'},
                body: 'x' * 129))
            .status,
        413);
    expect(forwarded, isEmpty);
  });

  test('logout and expiry revoke sessions', () async {
    var cookie = await login();
    expect(
        (await send('/logout',
                method: 'POST',
                headers: {'Cookie': cookie, 'Origin': 'https://$host'}))
            .status,
        303);
    expect(
        (await send('/v1/documents', headers: {'Cookie': cookie})).status, 401);
    cookie = await login();
    now = now.add(const Duration(hours: 9));
    expect(
        (await send('/v1/documents', headers: {'Cookie': cookie})).status, 401);
  });

  test(
      'bridge has narrow routes, requires extension identity, preserves only project auth',
      () async {
    const id = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
    final headers = {
      'Origin': 'chrome-extension://$id',
      'X-Curator-Extension-Id': id,
      'Authorization': 'Bearer PROJECT_CAPABILITY',
      'Content-Type': 'application/json',
      'Cookie': 'secret=cookie'
    };
    expect(
        (await send('/v1/browser-bridge/read',
                method: 'POST', headers: headers, body: '{}'))
            .status,
        200);
    expect(forwarded.single['authorization'], 'Bearer PROJECT_CAPABILITY');
    expect(forwarded.single['cookie'], isNull);
    expect(
        (await send('/v1/browser-bridge/read',
                method: 'POST',
                headers: {...headers, 'Origin': 'https://www.target.com'},
                body: '{}'))
            .status,
        403);
    expect(
        (await send('/v1/browser-bridge/read',
                method: 'POST',
                headers: {'Content-Type': 'application/json'},
                body: '{}'))
            .status,
        403);
    expect(
        (await send('/v1/browser-bridge/documents',
                method: 'POST', headers: headers, body: '{}'))
            .status,
        404);
    expect(
        (await send('/v1/documents',
                method: 'POST', headers: headers, body: '{}'))
            .status,
        403);
    expect(
        (await send('/v1/browser-bridge/pair',
                method: 'OPTIONS',
                headers: {'Origin': 'chrome-extension://$id'}))
            .status,
        204);
  });

  test('host spoofing, encoded traversal and symlink escapes are rejected',
      () async {
    final cookie = await login();
    expect(
        (await send('/', headers: {'Host': 'evil.test', 'Cookie': cookie}))
            .status,
        421);
    expect((await send('/%2eenv', headers: {'Cookie': cookie})).status, 404);
    expect(
        (await send('/assets%2f..%2fsecret', headers: {'Cookie': cookie}))
            .status,
        404);
    await Link('${root.path}/escape').create(root.parent.path);
    expect((await send('/escape', headers: {'Cookie': cookie})).status, 404);
  });

  test(
      'login rate limit is global and cannot be bypassed with forwarding headers',
      () async {
    for (var i = 0; i < 10; i++) {
      await send('/login',
          method: 'POST',
          headers: {
            'Origin': 'https://$host',
            'Content-Type': 'application/x-www-form-urlencoded',
            'X-Forwarded-For': '1.1.1.$i'
          },
          body: 'password=wrong');
    }
    expect(
        (await send('/login',
                method: 'POST',
                headers: {
                  'Origin': 'https://$host',
                  'Content-Type': 'application/x-www-form-urlencoded'
                },
                body: 'password=$password'))
            .status,
        429);
  });
}

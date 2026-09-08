import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:shopitem_curator/core/contracts/catalog_gateways.dart';
import 'package:shopitem_curator/core/contracts/curator_use_cases.dart';
import 'package:test/test.dart';
import '../server/browser_project_store.dart';
import '../server/curator_proxy_server.dart';
import '../server/curator_web_gateway.dart';
import '../server/file_source_document_repository.dart';

void main() {
  test(
      'hosted login -> import -> project -> extension capture -> authenticated image',
      () async {
    final temp = await Directory.systemTemp.createTemp('curator-hosted-flow-');
    final web = await Directory('${temp.path}/web').create();
    await File('${web.path}/index.html').writeAsString('<html>app</html>');
    final documents = FileSourceDocumentRepository(
        assetsDirectory: Directory('${temp.path}/assets'));
    final store = BrowserProjectStore(
        directory: Directory('${temp.path}/assets/.curator_projects'),
        documents: documents,
        extract: (_, __) async => const [
              ExtractedItemEntry(
                  rawName: 'notebook',
                  cleanName: 'notebook',
                  isPersonal: false,
                  quantity: 1)
            ]);
    var targetCalls = 0;
    final proxy = CuratorProxyServer(
        config: CuratorProxyConfig(
            bindAddress: InternetAddress.loopbackIPv4,
            port: 0,
            trustedAuthHeader: CuratorWebGateway.trustedHeader,
            allowUnauthenticatedLoopback: false,
            rateLimit: 500),
        documentRepository: documents,
        browserProjects: store,
        dependencies: CuratorProxyDependencies(
            extractOcr:
                ({required sourceImagePath, required imageBytes}) async => [],
            fetchProducts: (_) async {
              targetCalls++;
              return [];
            },
            fetchCandidates: (_) async {
              targetCalls++;
              return [];
            },
            inspectProduct: (_) async {
              targetCalls++;
              return null;
            },
            rescrape: (items) async => CatalogRescrapeResult(
                items: items, successfulItemCount: 0, failedItemCount: 0)));
    await proxy.start();
    final gateway = CuratorWebGateway(
        publicOrigin: Uri.parse('https://curator-test.onrender.com'),
        upstream: proxy.baseUri,
        webDirectory: web,
        password: 'test-only-password-twenty-characters');
    final server = await gateway.start(address: InternetAddress.loopbackIPv4);
    final base = Uri.parse('http://127.0.0.1:${server.port}');
    final client = http.Client();
    addTearDown(() async {
      client.close();
      await gateway.close();
      await proxy.close();
      await temp.delete(recursive: true);
    });
    final authHeaders = {
      'Host': 'curator-test.onrender.com',
      'Origin': 'https://curator-test.onrender.com'
    };
    final login = await http.Response.fromStream(
        await client.send(http.Request('POST', base.resolve('/login'))
          ..followRedirects = false
          ..headers.addAll(authHeaders)
          ..bodyFields = {'password': 'test-only-password-twenty-characters'}));
    expect(login.statusCode, 303);
    final appHeaders = {
      ...authHeaders,
      'Cookie': login.headers['set-cookie']!.split(';').first,
      'Content-Type': 'application/json'
    };
    Future<http.Response> app(String path, Map<String, Object?> body) => client
        .post(base.resolve(path), headers: appHeaders, body: jsonEncode(body));
    const extensionId = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
    Future<http.Response> bridge(String path, Map<String, Object?> body,
            [String? token]) =>
        client.post(base.resolve('/v1/browser-bridge/$path'),
            headers: {
              'Host': 'curator-test.onrender.com',
              'Origin': 'chrome-extension://$extensionId',
              'X-Curator-Extension-Id': extensionId,
              'Content-Type': 'application/json',
              if (token != null) 'Authorization': 'Bearer $token'
            },
            body: jsonEncode(body));
    Map<String, dynamic> json(http.Response response) {
      expect(response.statusCode, anyOf(200, 201));
      return jsonDecode(response.body) as Map<String, dynamic>;
    }

    final encoded =
        base64Encode(img.encodePng(img.Image(width: 32, height: 32)));
    final imported = json(await app(
        '/v1/documents', {'filename': 'preview.png', 'image_base64': encoded}));
    final project = json(await app('/v1/browser-projects/open',
        {'source_image_path': imported['source_image_path']}));
    final pairing = json(
        await app('/v1/browser-projects/pair', {'project_id': project['id']}));
    // Internal bridge cannot be reached without the gateway trust boundary.
    expect(
        (await client.post(proxy.baseUri.resolve('/v1/browser-bridge/pair'),
                headers: {
                  'Content-Type': 'application/json',
                  'X-Curator-Extension-Id': extensionId
                },
                body: jsonEncode({'code': pairing['code']})))
            .statusCode,
        401);
    expect((await bridge('pair', {'code': '0' * 32})).statusCode, 401);
    final token = json(await bridge('pair', {'code': pairing['code']}))['token']
        as String;
    expect((await bridge('pair', {'code': pairing['code']})).statusCode, 401);
    expect((await bridge('read', {}, 'invalid')).statusCode, 401);
    final selected = json(await bridge(
        'select',
        {
          'action': 'select',
          'item_id': 'item_0',
          'revision': 0,
          'operation_id': 'b' * 32,
          'target_url': 'https://www.target.com/p/notebook/-/A-12345678',
          'image_base64': encoded,
          'name': 'Notebook',
          'price': 4.99
        },
        token));
    expect(selected['revision'], 1);
    final entry = (selected['entries'] as List).single as Map;
    final image = json(await app('/v1/browser-projects/image', {
      'project_id': project['id'],
      'item_id': 'item_0',
      'image_version': entry['image_version']
    }));
    expect(img.decodePng(base64Decode(image['image_base64'] as String)),
        isNotNull);
    expect((await bridge('disconnect', {}, token)).statusCode, 200);
    expect((await bridge('read', {}, token)).statusCode, 401);
    expect(targetCalls, 0);
  });
}

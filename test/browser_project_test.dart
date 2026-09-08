import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:shopitem_curator/core/contracts/catalog_gateways.dart';
import 'package:shopitem_curator/core/contracts/curator_use_cases.dart';
import 'package:shopitem_curator/core/services/backend_proxy_gateway.dart';
import 'package:shopitem_curator/core/services/binary_resource_loader.dart';
import 'package:shopitem_curator/core/services/curation_pipeline_service.dart';
import 'package:test/test.dart';

import '../server/browser_project_store.dart';
import '../server/curator_proxy_server.dart';
import '../server/file_source_document_repository.dart';

void main() {
  late Directory temp;
  late FileSourceDocumentRepository documents;
  late BrowserProjectStore store;
  late CuratorProxyServer server;
  late BackendProxyGateway gateway;
  late http.Client client;
  late DateTime now;
  var extractionCount = 0;
  var targetCalls = 0;
  const extensionId = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  final png = img.encodePng(img.Image(width: 32, height: 32));

  BrowserProjectStore makeStore() => BrowserProjectStore(
      directory: Directory('${temp.path}/.curator_projects'),
      documents: documents,
      now: () => now,
      extract: (path, bytes) async {
        extractionCount++;
        return const [
          ExtractedItemEntry(
              rawName: 'big notebook',
              cleanName: 'big notebook',
              isPersonal: false,
              quantity: 1),
          ExtractedItemEntry(
              rawName: 'bicycle',
              cleanName: 'bicycle',
              isPersonal: false,
              quantity: 1),
        ];
      });
  setUp(() async {
    now = DateTime.utc(2026, 9, 7);
    extractionCount = 0;
    targetCalls = 0;
    temp = await Directory.systemTemp.createTemp('curator-browser-test-');
    documents = FileSourceDocumentRepository(assetsDirectory: temp);
    store = makeStore();
    server = CuratorProxyServer(
        config: CuratorProxyConfig(
            bindAddress: InternetAddress.loopbackIPv4,
            port: 0,
            bearerToken: 'app-test-token',
            allowedOrigin: 'https://app.example',
            rateLimit: 1000),
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
            rescrape: (items) async {
              targetCalls++;
              return CatalogRescrapeResult(
                  items: items, successfulItemCount: 0, failedItemCount: 0);
            }));
    await server.start();
    gateway = BackendProxyGateway(
        backendBaseUrl: server.baseUri.toString(), authToken: 'app-test-token');
    client = http.Client();
  });
  tearDown(() async {
    gateway.close();
    client.close();
    await server.close();
    await temp.delete(recursive: true);
  });
  Future<http.Response> bridge(String path, Map<String, Object?> body,
          {String? token,
          String origin = 'chrome-extension://$extensionId',
          String identity = extensionId}) =>
      client.post(server.baseUri.resolve('/v1/browser-bridge/$path'),
          headers: {
            'Content-Type': 'application/json',
            'Origin': origin,
            'X-Curator-Extension-Id': identity,
            if (token != null) 'Authorization': 'Bearer $token'
          },
          body: jsonEncode(body));
  Map<String, dynamic> json(http.Response response) =>
      jsonDecode(response.body) as Map<String, dynamic>;
  Map<String, Object?> selection(
          {int revision = 0,
          String operation = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'}) =>
      {
        'action': 'select',
        'item_id': 'item_0',
        'revision': revision,
        'operation_id': operation,
        'name': 'Big notebook',
        'price': 0,
        'target_url': 'https://www.target.com/p/notebook/-/A-12345678?ref=test',
        'image_base64': base64Encode(png),
      };

  test('pair → crop → project resume → PNG canvas uses no Target request',
      () async {
    final path = await gateway.importDocument('list.png', png);
    final project = await gateway.openBrowserProject(path);
    expect(project.entries.map((e) => e.query), ['big notebook', 'bicycle']);
    final code = await gateway.pairBrowserProject(project.id);
    final paired = await bridge('pair', {'code': code});
    expect(paired.statusCode, 200);
    final token = json(paired)['token'] as String;
    expect((await bridge('pair', {'code': code})).statusCode, 401);
    final saved = await bridge('select', selection(), token: token);
    expect(saved.statusCode, 200, reason: saved.body);
    expect(json(saved)['revision'], 1);
    // Retrying after an ambiguous network result is idempotent.
    expect(
        json(await bridge('select', selection(), token: token))['revision'], 1);
    final refreshed = await gateway.refreshBrowserProject(project.id);
    expect(refreshed.selectedCount, 1);
    final skeleton = await gateway.readBrowserSelection(refreshed);
    expect(skeleton.items.single.targetUrl,
        'https://www.target.com/p/notebook/-/A-12345678');
    expect(skeleton.items.single.formattedPrice, '가격 확인 필요');
    final pipeline = CurationPipelineService(
        ocrService: gateway,
        targetFetcherService: gateway,
        resourceLoader: CallbackBinaryResourceLoader(
            (source) async => Uri.parse(source).data!.contentAsBytes()));
    final canvas = await pipeline.rebuildManifest(skeleton);
    expect(canvas.canvasImage, startsWith('data:image/png;base64,'));
    expect(canvas.items, hasLength(1));
    store = makeStore();
    final resumed = await store.open(path);
    expect(resumed.id, project.id);
    expect(resumed.revision, 1);
    expect(extractionCount, 1);
    expect(targetCalls, 0);
  });

  test('auth, CORS, extension identity, expiry and project scope are enforced',
      () async {
    final path = await gateway.importDocument('list.png', png);
    final project = await gateway.openBrowserProject(path);
    final unauthorized = await client.post(
        server.baseUri.resolve('/v1/browser-projects/read'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'project_id': project.id}));
    expect(unauthorized.statusCode, 401);
    final code = await gateway.pairBrowserProject(project.id);
    expect(
        (await bridge('pair', {'code': code}, origin: 'https://www.target.com'))
            .statusCode,
        403);
    expect(
        (await bridge('pair', {'code': code},
                identity: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'))
            .statusCode,
        403);
    now = now.add(const Duration(minutes: 3));
    expect((await bridge('pair', {'code': code})).statusCode, 401);
    final next = await gateway.pairBrowserProject(project.id);
    final token = json(await bridge('pair', {'code': next}))['token'] as String;
    expect((await bridge('read', {}, token: 'app-test-token')).statusCode, 401);
    expect((await bridge('read', {}, token: token)).statusCode, 200);
    final otherPath = await gateway.importDocument('other.png', png);
    final other = await gateway.openBrowserProject(otherPath);
    final result = await bridge(
        'select', {...selection(), 'project_id': other.id},
        token: token);
    expect(result.statusCode, 200);
    expect((await gateway.refreshBrowserProject(other.id)).selectedCount, 0);
    now = now.add(const Duration(hours: 9));
    expect((await bridge('read', {}, token: token)).statusCode, 401);
  });

  test('reject stale writes, foreign URLs, missing or oversized raster',
      () async {
    final path = await gateway.importDocument('list.png', png);
    final project = await gateway.openBrowserProject(path);
    final code = await gateway.pairBrowserProject(project.id);
    final token = json(await bridge('pair', {'code': code}))['token'] as String;
    for (final url in [
      'https://evil.example/p/-/A-123',
      'https://www.target.com/s?searchTerm=x',
      'http://www.target.com/p/-/A-123',
      'https://www.target.com@evil.example/p/-/A-123'
    ]) {
      expect(
          (await bridge('select', {...selection(), 'target_url': url},
                  token: token))
              .statusCode,
          400);
    }
    expect(
        (await bridge(
                'select',
                {
                  ...selection(),
                  'image_base64': base64Encode([1, 2, 3])
                },
                token: token))
            .statusCode,
        400);
    expect(
        (await bridge(
                'select',
                {
                  ...selection(),
                  'image_base64': base64Encode(
                      img.encodePng(img.Image(width: 1201, height: 2)))
                },
                token: token))
            .statusCode,
        400);
    expect(
        (await bridge('select', selection(revision: 1), token: token))
            .statusCode,
        409);
    expect((await bridge('select', selection(), token: token)).statusCode, 200);
    expect(
        (await bridge('select',
                selection(operation: 'cccccccccccccccccccccccccccccccc'),
                token: token))
            .statusCode,
        409);
    expect((await gateway.refreshBrowserProject(project.id)).revision, 1);
  });

  test('deleting document archives captures and revokes browser access',
      () async {
    final path = await gateway.importDocument('list.png', png);
    final project = await gateway.openBrowserProject(path);
    final code = await gateway.pairBrowserProject(project.id);
    final token = json(await bridge('pair', {'code': code}))['token'] as String;
    expect((await bridge('select', selection(), token: token)).statusCode, 200);
    await gateway.deleteDocument(path);
    expect((await bridge('read', {}, token: token)).statusCode, 401);
    final files =
        await Directory('${temp.path}/.curator_projects').list().toList();
    expect(files.single.path, contains('deleted-${project.id}'));
    expect(
        await Directory(files.single.path)
            .list()
            .where((e) => e.path.endsWith('.png'))
            .length,
        1);
    final replacementPath = await gateway.importDocument('list.png', png);
    final replacement = await gateway.openBrowserProject(replacementPath);
    expect(replacement.id, isNot(project.id));
    expect(replacement.selectedCount, 0);
  });

  test('failed source deletion rolls back archive and project access',
      () async {
    final path = await gateway.importDocument('list.png', png);
    final project = await store.open(path);
    await expectLater(
        store.deleteDocument(
            path, () async => throw StateError('disk failure')),
        throwsStateError);
    expect((await store.read(project.id)).id, project.id);
  });

  test(
      'extension preflight does not loosen app CORS, and disconnect revokes token',
      () async {
    final path = await gateway.importDocument('list.png', png);
    final project = await gateway.openBrowserProject(path);
    final code = await gateway.pairBrowserProject(project.id);
    final preflight = await client.send(http.Request(
        'OPTIONS', server.baseUri.resolve('/v1/browser-bridge/pair'))
      ..headers.addAll({
        'Origin': 'chrome-extension://$extensionId',
        'Access-Control-Request-Method': 'POST'
      }));
    await preflight.stream.drain<void>();
    expect(preflight.statusCode, 204);
    expect(preflight.headers['access-control-allow-origin'],
        'chrome-extension://$extensionId');
    final appRequest =
        await client.post(server.baseUri.resolve('/v1/browser-projects/read'),
            headers: {
              'Origin': 'chrome-extension://$extensionId',
              'Content-Type': 'application/json',
              'Authorization': 'Bearer app-test-token'
            },
            body: jsonEncode({'project_id': project.id}));
    expect(appRequest.statusCode, 403);
    final token = json(await bridge('pair', {'code': code}))['token'] as String;
    expect((await bridge('disconnect', {}, token: token)).statusCode, 200);
    expect((await bridge('read', {}, token: token)).statusCode, 401);
  });
}

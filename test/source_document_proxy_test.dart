import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:shopitem_curator/core/contracts/curator_use_cases.dart';
import 'package:shopitem_curator/core/services/backend_proxy_gateway.dart';
import 'package:test/test.dart';

import '../server/curator_proxy_server.dart';
import '../server/file_source_document_repository.dart';

void main() {
  test('authenticated HTTP catalog round-trip, deletion and CORS preflight',
      () async {
    final temporary =
        await Directory.systemTemp.createTemp('curator-document-proxy-test-');
    final server = CuratorProxyServer(
      config: CuratorProxyConfig(
          bindAddress: InternetAddress.loopbackIPv4,
          port: 0,
          bearerToken: 'documents-test-token',
          allowedOrigin: 'https://app.example'),
      documentRepository:
          FileSourceDocumentRepository(assetsDirectory: temporary),
      dependencies: CuratorProxyDependencies(
        extractOcr: ({required sourceImagePath, required imageBytes}) async =>
            [],
        fetchProducts: (_) async => [],
        fetchCandidates: (_) async => [],
        inspectProduct: (_) async => null,
        rescrape: (items) async => CatalogRescrapeResult(
            items: items, successfulItemCount: 0, failedItemCount: 0),
      ),
    );
    await server.start();
    final gateway = BackendProxyGateway(
        backendBaseUrl: server.baseUri.toString(),
        authToken: 'documents-test-token');
    final unauthorized =
        BackendProxyGateway(backendBaseUrl: server.baseUri.toString());
    final client = http.Client();
    addTearDown(() async {
      gateway.close();
      unauthorized.close();
      client.close();
      await server.close();
      await temporary.delete(recursive: true);
    });
    final png = img.encodePng(img.Image(width: 5, height: 5));
    await expectLater(
        unauthorized.listDocuments(),
        throwsA(isA<BackendProxyException>()
            .having((e) => e.statusCode, 'status', 401)));
    await expectLater(
        unauthorized.importDocument('bad.png', png),
        throwsA(isA<BackendProxyException>()
            .having((e) => e.statusCode, 'status', 401)));
    expect(await gateway.listDocuments(), isEmpty);
    final path = await gateway.importDocument('새 문서.png', png);
    expect(await gateway.listDocuments(), [path]);
    expect(await gateway.readDocument(path), png);
    await expectLater(
        unauthorized.deleteDocument(path),
        throwsA(isA<BackendProxyException>()
            .having((e) => e.statusCode, 'status', 401)));
    final forbidden = await client
        .delete(server.baseUri.resolve('/v1/documents'), headers: {
      'Origin': 'https://evil.example',
      'Authorization': 'Bearer documents-test-token'
    });
    expect(forbidden.statusCode, 403);
    expect(await gateway.listDocuments(), [path]);
    final preflight = await client.send(
        http.Request('OPTIONS', server.baseUri.resolve('/v1/documents'))
          ..headers.addAll({
            'Origin': 'https://app.example',
            'Access-Control-Request-Method': 'DELETE'
          }));
    await preflight.stream.drain<void>();
    expect(preflight.statusCode, 204);
    expect(
        preflight.headers['access-control-allow-methods'], contains('DELETE'));
    await gateway.deleteDocument(path);
    expect(await gateway.listDocuments(), isEmpty);
    await expectLater(
        gateway.readDocument(path),
        throwsA(isA<BackendProxyException>()
            .having((e) => e.statusCode, 'status', 404)));
    await expectLater(
        gateway.importDocument('../escape.png', png),
        throwsA(isA<BackendProxyException>()
            .having((e) => e.statusCode, 'status', 400)));
  });
}

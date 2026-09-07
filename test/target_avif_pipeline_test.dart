import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:shopitem_curator/core/services/backend_proxy_gateway.dart';
import 'package:shopitem_curator/core/services/binary_resource_loader.dart';
import 'package:shopitem_curator/core/services/canvas_compositor_service.dart';
import 'package:shopitem_curator/core/services/contour_segmenter_service.dart';
import 'package:shopitem_curator/core/services/target_fetcher_service.dart';
import 'package:test/test.dart';

import '../server/avif_image_decoder.dart';
import '../server/curator_proxy_server.dart';
import 'fixtures/transparent_avif.dart';

void main() {
  for (final token in [null, 'avif-test-token']) {
    test('real AVIF proxy → PNG → pure Dart silhouette (auth=${token != null})',
        () async {
      final images = {
        'https://target.scene7.com/is/image/Target/GUEST_test?fmt=pjpeg':
            CuratorProxyImage(
                bytes: transparentLShapeAvif(), contentType: 'image/avif')
      };
      final composite = await _compositeThroughProxy(images, token: token);
      final decoded = img.decodePng(composite.placedItems.single.imageBytes!)!;
      expect(decoded.width, 64);
      expect(decoded.getPixel(0, 0).a, 0);
      expect(decoded.getPixel(32, 16).a, 0);
      expect(decoded.getPixel(16, 16).a, 255);
      final item = (await const ContourSegmenterService()
              .segmentPlacedItems(composite.placedItems))
          .single;
      expect(item.isPreciselySegmented, isTrue);
      expect(item.polygon.length, greaterThanOrEqualTo(6));
      expect(composite.canvasPngBytes, isNotNull);
    }, skip: Platform.environment['CURATOR_TEST_AVIF'] != '1');
  }

  test(
      'the three previously failing live Target AVIF images produce precise silhouettes',
      () async {
    final client = http.Client();
    addTearDown(client.close);
    final images = <String, CuratorProxyImage>{};
    for (final id in [
      '46ac06c2-fecc-4fe1-ae17-b866bfd76589',
      '47e58a11-8c68-4f8e-aa3a-9181842746f5',
      '2712b542-ce40-405a-b4c4-368b7d9d29cf',
    ]) {
      final url =
          'https://target.scene7.com/is/image/Target/GUEST_$id?wid=1200&hei=1200&qlt=85&fmt=pjpeg';
      final response = await client.get(Uri.parse(url), headers: {
        'Accept': 'image/avif,image/webp,image/png,image/jpeg',
      }).timeout(const Duration(seconds: 15));
      expect(response.statusCode, 200);
      expect(isAvifImage(response.bodyBytes), isTrue, reason: id);
      images[url] = CuratorProxyImage(
          bytes: response.bodyBytes,
          contentType: response.headers['content-type']!);
    }
    final composite =
        await _compositeThroughProxy(images, token: 'live-avif-test');
    expect(composite.placedItems.every((item) => item.hasDecodedImage), isTrue);
    final items = await const ContourSegmenterService()
        .segmentPlacedItems(composite.placedItems);
    expect(items.length, 3);
    expect(items.every((item) => item.isPreciselySegmented), isTrue);
    expect(composite.canvasPngBytes, isNotNull);
  },
      skip: Platform.environment['CURATOR_TEST_TARGET_AVIF'] != '1',
      timeout: const Timeout(Duration(minutes: 2)));
}

Future<DynamicCanvasLayoutResult> _compositeThroughProxy(
    Map<String, CuratorProxyImage> images,
    {String? token}) async {
  final server = CuratorProxyServer(
      config: CuratorProxyConfig(
          bindAddress: InternetAddress.loopbackIPv4,
          port: 0,
          bearerToken: token),
      imageFetcher: _Images(images),
      dependencies: CuratorProxyDependencies(
        extractOcr: ({required sourceImagePath, required imageBytes}) async =>
            [],
        fetchProducts: (_) async => [
          for (final (i, url) in images.keys.indexed)
            TargetProductData(
                id: 'avif-$i',
                name: 'AVIF $i',
                category: 'Test',
                isPersonal: false,
                quantity: 1,
                price: 1,
                priceCurrency: 'USD',
                description: '',
                targetUrl: 'https://www.target.com/p/-/A-12345678',
                imageUrl: url)
        ],
        fetchCandidates: (_) async => [],
        inspectProduct: (_) async => null,
        rescrape: (_) async => throw UnimplementedError(),
      ));
  await server.start();
  addTearDown(server.close);
  final gateway = BackendProxyGateway(
      backendBaseUrl: server.baseUri.toString(), authToken: token);
  addTearDown(gateway.close);
  final products = await gateway.fetchTargetProducts([
    for (var i = 0; i < images.length; i++)
      const ExtractedItemEntry(
          rawName: 'AVIF', cleanName: 'AVIF', isPersonal: false, quantity: 1),
  ]);
  final client = http.Client();
  addTearDown(client.close);
  return CanvasCompositorService(
      resourceLoader: CallbackBinaryResourceLoader((source) async {
    final uri = Uri.parse(source);
    if (uri.isScheme('data')) {
      expect(uri.data!.mimeType, 'image/png');
      return Uint8List.fromList(uri.data!.contentAsBytes());
    }
    expect(uri.queryParameters['raster'], 'png-v1');
    final response = await client.get(uri);
    expect(response.statusCode, 200);
    expect(response.headers['content-type'], startsWith('image/png'));
    return response.bodyBytes;
  })).compositeItemsToCanvas(products: products, sourceImagePath: 'test.png');
}

final class _Images implements CuratorProxyImageFetcher {
  _Images(this.images);
  final Map<String, CuratorProxyImage> images;
  @override
  Future<CuratorProxyImage> fetch(Uri uri,
          {required int maxBytes, required Duration timeout}) async =>
      images[uri.toString()]!;
  @override
  void close() {}
}

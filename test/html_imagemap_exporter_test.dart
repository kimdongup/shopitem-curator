import 'dart:io';

import 'package:shopitem_curator/core/models/curator_item.dart';
import 'package:shopitem_curator/core/services/html_imagemap_exporter.dart';
import 'package:test/test.dart';

void main() {
  group('HtmlImageMapExporter', () {
    test('encodes a local image on Dart IO platforms', () {
      final tempDirectory = Directory.systemTemp.createTempSync(
        'shopitem_curator_exporter_',
      );
      addTearDown(() => tempDirectory.deleteSync(recursive: true));

      final imageFile = File('${tempDirectory.path}/pixel.png')
        ..writeAsBytesSync(const [0, 1, 2, 3]);

      expect(
        HtmlImageMapExporter.fileToBase64DataUri(imageFile.path),
        'data:image/png;base64,AAECAw==',
      );
    });

    test('generates markup for exactly the supplied items', () {
      final includedItem = CuratorItem(
        id: 'included',
        name: 'Included & safe',
        category: 'common',
        isPersonal: false,
        quantity: 1,
        price: 2.5,
        priceCurrency: 'USD',
        description: 'Included item',
        targetUrl: 'https://www.target.com/p/included/-/A-100001',
        imageUrl: 'assets/items/included.png',
        bounds: const ItemLayoutBounds(x: 10, y: 20, width: 30, height: 40),
        polygon: [],
        centroid: const CuratorPoint(25, 40),
      );

      final html = HtmlImageMapExporter.generateHtml(
        canvasWidth: 100,
        canvasHeight: 100,
        items: [
          PositionedItemExportData(
            item: includedItem,
            x: 10,
            y: 20,
            width: 30,
            height: 40,
          ),
        ],
      );

      expect(html, contains('data-item-id="included"'));
      expect(html, contains('Included &amp; safe'));
      expect(html, isNot(contains('excluded')));
      expect(html, contains('<button type="button" class="item-trigger"'));
      expect(html, contains('aria-controls="curator-balloon-0"'));
      expect(html, contains('aria-expanded="false"'));
      expect(html, isNot(contains('class="item-link"')));
    });

    test('connects a responsive transparent hit layer to the image map', () {
      final item = _testItem(
        targetUrl: 'https://www.target.com/p/item/-/A-100010',
      );

      final html = HtmlImageMapExporter.generateHtml(
        canvasWidth: 100,
        canvasHeight: 80,
        items: [
          PositionedItemExportData(
            item: item,
            x: 10,
            y: 20,
            width: 30,
            height: 40,
          ),
        ],
      );

      expect(html, contains('class="image-map-hit-layer"'));
      expect(html, contains('usemap="#target-curator-map"'));
      expect(
        html,
        contains('<map id="target-curator-map" name="target-curator-map">'),
      );
      expect(html, contains('data-original-coords="10,20,40,60"'));
      expect(html, contains('width: min(100%, 100px)'));
      expect(html, contains('aspect-ratio: 100.000 / 80.000'));
      expect(
        html,
        contains(
          'left: 10.000000%; top: 25.000000%; '
          'width: 30.000000%; height: 50.000000%;',
        ),
      );
      expect(html, contains("new ResizeObserver(resizeImageMap)"));
      expect(html, contains('data-original-coords'));
    });

    test('toggles product balloons and keeps navigation inside the balloon',
        () {
      const targetUrl = 'https://www.target.com/p/item/-/A-100011';
      final item = _testItem(targetUrl: targetUrl);

      final html = HtmlImageMapExporter.generateHtml(
        canvasWidth: 100,
        canvasHeight: 100,
        items: [
          PositionedItemExportData(
            item: item,
            x: 10,
            y: 20,
            width: 30,
            height: 40,
          ),
        ],
      );

      expect(targetUrl.allMatches(html), hasLength(1));
      expect(
        html,
        contains(
          '<a href="$targetUrl" target="_blank" '
          'rel="noopener noreferrer" class="balloon-btn">',
        ),
      );
      expect(html, contains('href="#curator-balloon-0" role="button"'));
      expect(html, contains('aria-haspopup="dialog"'));
      expect(html, contains('.curator-item:hover .speech-balloon'));
      expect(html, contains('.curator-item:focus-within .speech-balloon'));
      expect(html, contains('.curator-item.is-open .speech-balloon'));
      expect(html, contains("document.addEventListener('click'"));
      expect(
        html,
        contains("if (!element.closest('.curator-item')) closeAll();"),
      );
      expect(html, contains("if (event.key !== 'Escape') return;"));
      expect(html, contains("setAttribute('aria-expanded', String(expanded))"));
      expect(
        html,
        contains("item.addEventListener('focusin', () => setOpen(item, true))"),
      );
    });

    test('escapes every dynamic HTML attribute value', () {
      final item = CuratorItem(
        id: 'item" onmouseover="alert(1)',
        name: 'Name" onclick="alert(2)',
        category: 'common',
        isPersonal: false,
        quantity: 1,
        price: 2.5,
        priceCurrency: 'USD',
        description: 'Description <script>alert(3)</script>',
        targetUrl:
            'https://www.target.com/p/item/-/A-100002?x=1&name=%22%20onfocus%3D%22alert(4)',
        imageUrl: 'assets/items/item" onerror="alert(5).png',
        bounds: const ItemLayoutBounds(x: 10, y: 20, width: 30, height: 40),
        polygon: [],
        centroid: const CuratorPoint(25, 40),
      );

      final html = HtmlImageMapExporter.generateHtml(
        canvasWidth: 100,
        canvasHeight: 100,
        items: [
          PositionedItemExportData(
            item: item,
            x: 10,
            y: 20,
            width: 30,
            height: 40,
          ),
        ],
      );

      expect(html, contains('data-id="item&quot; onmouseover=&quot;alert(1)"'));
      expect(html, contains('Name&quot; onclick=&quot;alert(2)'));
      expect(
          html, contains('Description &lt;script&gt;alert(3)&lt;/script&gt;'));
      expect(
        html,
        contains('x=1&amp;name=%22%20onfocus%3D%22alert(4)'),
      );
      expect(html, contains('item&quot; onerror=&quot;alert(5).png'));
      expect(html, isNot(contains('" onmouseover="alert(1)')));
      expect(html, isNot(contains('" onclick="alert(2)')));
      expect(html, isNot(contains('" onfocus="alert(4)')));
      expect(html, isNot(contains('" onerror="alert(5)')));
      expect(html, isNot(contains('<script>alert(3)</script>')));
    });

    test('blocks active link and image URI schemes', () {
      final item = CuratorItem(
        id: 'unsafe',
        name: 'Unsafe item',
        category: 'common',
        isPersonal: false,
        quantity: 1,
        price: 2.5,
        priceCurrency: 'USD',
        description: 'Unsafe item',
        targetUrl: '  JaVaScRiPt:alert(1)  ',
        imageUrl: 'javascript:alert(2)',
        bounds: const ItemLayoutBounds(x: 10, y: 20, width: 30, height: 40),
        polygon: [],
        centroid: const CuratorPoint(25, 40),
      );

      final html = HtmlImageMapExporter.generateHtml(
        canvasWidth: 100,
        canvasHeight: 100,
        items: [
          PositionedItemExportData(
            item: item,
            x: 10,
            y: 20,
            width: 30,
            height: 40,
            base64DataUri:
                'data:image/svg+xml;base64,PHN2ZyBvbmxvYWQ9YWxlcnQoMSk+',
          ),
        ],
      );

      expect('href="#"'.allMatches(html), isEmpty);
      expect(html, contains('href="#curator-balloon-0"'));
      expect(
        html,
        contains(
          '<span class="balloon-btn is-disabled" aria-disabled="true">',
        ),
      );
      expect(html, contains('data:image/gif;base64,'));
      expect(html.toLowerCase(), isNot(contains('javascript:')));
      expect(html.toLowerCase(), isNot(contains('image/svg+xml')));
      expect('rel="noopener noreferrer"'.allMatches(html), isEmpty);
    });

    test('keeps safe HTTPS links and Base64 raster images', () {
      final item = CuratorItem(
        id: 'safe',
        name: 'Safe item',
        category: 'common',
        isPersonal: false,
        quantity: 1,
        price: 2.5,
        priceCurrency: 'USD',
        description: 'Safe item',
        targetUrl: 'https://www.target.com/p/item/-/A-100003?a=1&b=2',
        imageUrl: 'assets/items/item.png',
        bounds: const ItemLayoutBounds(x: 10, y: 20, width: 30, height: 40),
        polygon: [],
        centroid: const CuratorPoint(25, 40),
      );

      final html = HtmlImageMapExporter.generateHtml(
        canvasWidth: 100,
        canvasHeight: 100,
        items: [
          PositionedItemExportData(
            item: item,
            x: 10,
            y: 20,
            width: 30,
            height: 40,
            base64DataUri: 'data:image/png;base64,AAECAw==',
          ),
        ],
      );

      expect(
        html,
        contains(
          'href="https://www.target.com/p/item/-/A-100003?a=1&amp;b=2"',
        ),
      );
      expect(html, contains('src="data:image/png;base64,AAECAw=="'));
    });

    test('exports and clips the transformed segmentation polygon', () {
      final item = CuratorItem(
        id: 'polygon',
        name: 'Polygon item',
        category: 'common',
        isPersonal: false,
        quantity: 1,
        price: 2.5,
        priceCurrency: 'USD',
        description: 'Polygon item',
        targetUrl: 'https://www.target.com/p/polygon/-/A-100004',
        imageUrl: 'assets/items/item.png',
        bounds: const ItemLayoutBounds(x: 10, y: 20, width: 30, height: 40),
        polygon: [
          const CuratorPoint(10, 20),
          const CuratorPoint(40, 20),
          const CuratorPoint(25, 60),
        ],
        centroid: const CuratorPoint(25, 33.33),
      );

      final html = HtmlImageMapExporter.generateHtml(
        canvasWidth: 300,
        canvasHeight: 300,
        items: [
          PositionedItemExportData(
            item: item,
            x: 100,
            y: 200,
            width: 30,
            height: 40,
            scale: 2,
          ),
        ],
      );

      expect(
        html,
        contains('shape="poly" coords="100,200,160,200,130,280"'),
      );
      expect(
        html,
        contains(
          'clip-path: polygon(0.000% 0.000%, 100.000% 0.000%, 50.000% 100.000%)',
        ),
      );
    });

    test('exports disconnected contours with an even-odd SVG clip', () {
      final item = CuratorItem(
        id: 'compound',
        name: 'Compound item',
        category: 'common',
        isPersonal: false,
        quantity: 1,
        price: 1,
        priceCurrency: 'USD',
        description: 'Two pieces',
        targetUrl: 'https://www.target.com/p/-/A-100005',
        imageUrl: 'assets/items/item.png',
        bounds: const ItemLayoutBounds(x: 0, y: 0, width: 100, height: 100),
        polygon: const [
          CuratorPoint(0, 0),
          CuratorPoint(40, 0),
          CuratorPoint(40, 40),
          CuratorPoint(0, 40),
        ],
        contours: const [
          [
            CuratorPoint(0, 0),
            CuratorPoint(40, 0),
            CuratorPoint(40, 40),
            CuratorPoint(0, 40),
          ],
          [
            CuratorPoint(60, 60),
            CuratorPoint(100, 60),
            CuratorPoint(100, 100),
            CuratorPoint(60, 100),
          ],
        ],
        centroid: const CuratorPoint(50, 50),
      );

      final html = HtmlImageMapExporter.generateHtml(
        canvasWidth: 100,
        canvasHeight: 100,
        items: [
          PositionedItemExportData(
            item: item,
            x: 0,
            y: 0,
            width: 100,
            height: 100,
          ),
        ],
      );

      expect('shape="poly"'.allMatches(html), hasLength(2));
      expect(html, contains('clip-path: url(#curator-compound-clip-0)'));
      expect(html, contains('clipPathUnits="objectBoundingBox"'));
      expect(html, contains('fill-rule="evenodd"'));
      expect(html, contains('M 0.000000 0.000000'));
      expect(html, contains('M 0.600000 0.600000'));
    });
  });
}

CuratorItem _testItem({required String targetUrl}) {
  return CuratorItem(
    id: 'test-item',
    name: 'Test item',
    category: 'common',
    isPersonal: false,
    quantity: 1,
    price: 2.5,
    priceCurrency: 'USD',
    description: 'Test item description',
    targetUrl: targetUrl,
    imageUrl: 'assets/items/item.png',
    bounds: const ItemLayoutBounds(x: 10, y: 20, width: 30, height: 40),
    polygon: const [],
    centroid: const CuratorPoint(25, 40),
  );
}

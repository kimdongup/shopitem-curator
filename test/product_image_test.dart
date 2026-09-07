import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shopitem_curator/ui/widgets/product_image.dart';

void main() {
  Widget buildHost(Widget child) {
    return MaterialApp(home: Scaffold(body: child));
  }

  testWidgets('uses an AssetImage for bundled product paths', (tester) async {
    await tester.pumpWidget(
      buildHost(
        const ProductImage(
          source: 'assets/items/item_hand_sanitizer.png',
        ),
      ),
    );

    final image = tester.widget<Image>(find.byType(Image));
    expect(image.image, isA<AssetImage>());
    expect(image.loadingBuilder, isNull);
  });

  testWidgets('uses a MemoryImage for a generated raster data URI',
      (tester) async {
    await tester.pumpWidget(
      buildHost(
        const ProductImage(
          source: _onePixelPngDataUri,
          semanticLabel: 'generated canvas',
        ),
      ),
    );

    final image = tester.widget<Image>(find.byType(Image));
    expect(image.image, isA<MemoryImage>());
    expect(image.semanticLabel, 'generated canvas');
  });

  testWidgets(
      'uses NetworkImage and preserves progress reporting for HTTP URLs',
      (tester) async {
    const completedImage = SizedBox(key: ValueKey('completed-image'));

    await tester.pumpWidget(
      buildHost(
        const ProductImage(source: 'https://example.com/product.png'),
      ),
    );

    final image = tester.widget<Image>(find.byType(Image));
    expect(image.image, isA<NetworkImage>());
    expect(image.loadingBuilder, isNotNull);

    final loading = image.loadingBuilder!(
      tester.element(find.byType(Image)),
      completedImage,
      const ImageChunkEvent(
        cumulativeBytesLoaded: 25,
        expectedTotalBytes: 100,
      ),
    );
    await tester.pumpWidget(buildHost(loading));

    final indicator = tester.widget<CircularProgressIndicator>(
      find.byType(CircularProgressIndicator),
    );
    expect(indicator.value, 0.25);
  });

  testWidgets('returns the completed network image when loading finishes',
      (tester) async {
    const completedImage = SizedBox(key: ValueKey('completed-image'));

    await tester.pumpWidget(
      buildHost(
        const ProductImage(source: 'http://example.com/product.png'),
      ),
    );

    final image = tester.widget<Image>(find.byType(Image));
    final completed = image.loadingBuilder!(
      tester.element(find.byType(Image)),
      completedImage,
      null,
    );

    expect(completed, same(completedImage));
  });

  testWidgets('uses the configured placeholder for an empty source',
      (tester) async {
    await tester.pumpWidget(
      buildHost(
        ProductImage(
          source: '',
          placeholderBuilder: (_) =>
              const SizedBox(key: ValueKey('product-placeholder')),
        ),
      ),
    );

    expect(find.byKey(const ValueKey('product-placeholder')), findsOneWidget);
    expect(find.byType(Image), findsNothing);
  });

  testWidgets('uses the placeholder for a malformed image data URI',
      (tester) async {
    await tester.pumpWidget(
      buildHost(
        ProductImage(
          source: 'data:image/png;base64,not-valid-base64!',
          placeholderBuilder: (_) =>
              const SizedBox(key: ValueKey('data-uri-placeholder')),
        ),
      ),
    );

    expect(find.byKey(const ValueKey('data-uri-placeholder')), findsOneWidget);
    expect(find.byType(Image), findsNothing);
  });

  testWidgets('uses the configured placeholder when image loading fails',
      (tester) async {
    await tester.pumpWidget(
      buildHost(
        ProductImage(
          source: 'assets/items/missing-product.png',
          placeholderBuilder: (_) =>
              const SizedBox(key: ValueKey('load-error-placeholder')),
        ),
      ),
    );
    await tester.pump();

    expect(
      find.byKey(const ValueKey('load-error-placeholder')),
      findsOneWidget,
    );
  });
}

const _onePixelPngDataUri =
    'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwC'
    'AAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:shopitem_curator/ui/adapters/flutter_binary_resource_loader.dart';

void main() {
  group('FlutterBinaryResourceLoader data URI support', () {
    test('decodes an inline image without issuing a network request', () async {
      final loader = FlutterBinaryResourceLoader(
        httpClient: MockClient((_) async {
          fail('Inline images must not issue an HTTP request.');
        }),
      );

      final bytes = await loader.load('data:image/png;base64,iVBORw0KGgo=');

      expect(bytes, <int>[137, 80, 78, 71, 13, 10, 26, 10]);
    });

    test('rejects non-image inline data', () async {
      final loader = FlutterBinaryResourceLoader(
        httpClient: MockClient((_) async {
          fail('Rejected inline data must not issue an HTTP request.');
        }),
      );

      await expectLater(
        loader.load('data:text/plain;base64,aGVsbG8='),
        throwsA(isA<StateError>()),
      );
    });
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:shopitem_curator/main.dart';

void main() {
  group('resolveBackendBaseUri', () {
    test('hosted preview uses its origin even during a local container smoke',
        () {
      expect(
        resolveBackendBaseUri(
          configuredUrl: '',
          web: true,
          hostedPreview: true,
          applicationBaseUri: Uri.parse('http://127.0.0.1:18201/'),
        ),
        Uri.parse('http://127.0.0.1:18201/'),
      );
    });
    test('uses a non-loopback web origin when no URL is configured', () {
      final result = resolveBackendBaseUri(
        configuredUrl: '',
        web: true,
        applicationBaseUri: Uri.parse(
          'https://curator.example/app/index.html?debug=true#section',
        ),
      );

      expect(result, Uri.parse('https://curator.example/'));
    });

    for (final developmentOrigin in <String>[
      'http://localhost:52143/',
      'http://127.0.0.1:52143/',
      'http://[::1]:52143/',
    ]) {
      test('uses the local proxy for Web development at $developmentOrigin',
          () {
        final result = resolveBackendBaseUri(
          configuredUrl: '',
          web: true,
          applicationBaseUri: Uri.parse(developmentOrigin),
        );

        expect(result, Uri.parse('http://127.0.0.1:8787/'));
      });
    }

    test('uses the loopback proxy for native development by default', () {
      final result = resolveBackendBaseUri(
        configuredUrl: '',
        web: false,
        applicationBaseUri: Uri.parse('file:///Applications/curator/'),
      );

      expect(result, Uri.parse('http://127.0.0.1:8787/'));
    });

    test('normalizes a configured backend path prefix', () {
      final result = resolveBackendBaseUri(
        configuredUrl: 'https://api.example/curator',
        web: true,
      );

      expect(result, Uri.parse('https://api.example/curator/'));
    });

    test('a configured backend takes precedence on local Web', () {
      final result = resolveBackendBaseUri(
        configuredUrl: 'https://api.example/curator',
        web: true,
        applicationBaseUri: Uri.parse('http://localhost:52143/'),
      );

      expect(result, Uri.parse('https://api.example/curator/'));
    });

    for (final invalid in <String>[
      '/relative',
      'ftp://api.example',
      'http://api.example',
      'https://user:secret@api.example',
      'https://api.example?token=secret',
      'https://api.example/#fragment',
    ]) {
      test('rejects invalid public backend URL: $invalid', () {
        expect(
          () => resolveBackendBaseUri(configuredUrl: invalid, web: true),
          throwsArgumentError,
        );
      });
    }
  });
}

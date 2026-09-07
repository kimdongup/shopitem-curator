import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import '../../core/services/binary_resource_loader.dart';

/// Flutter adapter for the Pure Dart binary-resource port.
///
/// Bundled paths are loaded through [rootBundle], while HTTP(S) product images
/// use the application-owned client. No Flutter API leaks into `lib/core`.
final class FlutterBinaryResourceLoader implements BinaryResourceLoader {
  const FlutterBinaryResourceLoader({
    required http.Client httpClient,
    this.networkTimeout = const Duration(seconds: 12),
  }) : _httpClient = httpClient;

  final http.Client _httpClient;
  final Duration networkTimeout;

  @override
  Future<Uint8List> load(String source) async {
    final uri = Uri.tryParse(source);
    if (uri != null && uri.scheme == 'data') {
      final data = uri.data;
      if (data == null || !data.mimeType.toLowerCase().startsWith('image/')) {
        throw StateError('Unsupported inline image resource.');
      }
      return Uint8List.fromList(data.contentAsBytes());
    }

    if (uri != null && (uri.scheme == 'http' || uri.scheme == 'https')) {
      final response = await _httpClient.get(uri).timeout(networkTimeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw StateError(
          'Image request failed (${response.statusCode}): $source',
        );
      }
      return response.bodyBytes;
    }

    final data = await rootBundle.load(source);
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  }
}

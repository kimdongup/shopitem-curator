// Pure Dart Service (Zero Flutter Dependencies)

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'binary_resource_loader.dart';
import 'html_imagemap_exporter.dart';

typedef HtmlExportProgressCallback = void Function(int completed, int total);

/// Builds a self-contained interactive HTML document from positioned items.
///
/// Platform byte loading stays behind [BinaryResourceLoader]. Duplicate image
/// sources are fetched once and a small worker pool avoids serial network
/// delays without opening an unbounded number of requests.
final class HtmlExportService {
  const HtmlExportService({
    this.resourceLoader,
    this.maxParallelLoads = 4,
  }) : assert(maxParallelLoads > 0);

  final BinaryResourceLoader? resourceLoader;
  final int maxParallelLoads;

  Future<String> generate({
    required double canvasWidth,
    required double canvasHeight,
    required List<PositionedItemExportData> items,
    String pageTitle = 'Target School Supplies Interactive Map',
    HtmlExportProgressCallback? onProgress,
  }) async {
    final loader = resourceLoader;
    final sources = <String>{
      for (final data in items)
        if (data.base64DataUri == null &&
            data.item.imageUrl.trim().isNotEmpty &&
            !data.item.imageUrl.startsWith('data:image/'))
          data.item.imageUrl,
    }.toList(growable: false);
    final dataUris = <String, String?>{};
    onProgress?.call(0, sources.length);

    if (loader != null && sources.isNotEmpty) {
      var nextIndex = 0;
      var completed = 0;

      Future<void> worker() async {
        while (nextIndex < sources.length) {
          final source = sources[nextIndex++];
          try {
            final bytes = await loader.load(source);
            dataUris[source] = _toImageDataUri(bytes, source);
          } catch (_) {
            // The exporter will safely fall back to the original source or a
            // transparent pixel. One failed product must not abort all output.
            dataUris[source] = null;
          } finally {
            completed++;
            onProgress?.call(completed, sources.length);
          }
        }
      }

      final workerCount = math.min(maxParallelLoads, sources.length);
      await Future.wait(List.generate(workerCount, (_) => worker()));
    } else if (sources.isNotEmpty) {
      onProgress?.call(sources.length, sources.length);
    }

    final enrichedItems = items
        .map(
          (data) => PositionedItemExportData(
            item: data.item,
            x: data.x,
            y: data.y,
            width: data.width,
            height: data.height,
            scale: data.scale,
            base64DataUri: data.base64DataUri ??
                (data.item.imageUrl.startsWith('data:image/')
                    ? data.item.imageUrl
                    : dataUris[data.item.imageUrl]),
          ),
        )
        .toList(growable: false);

    return HtmlImageMapExporter.generateHtml(
      canvasWidth: canvasWidth,
      canvasHeight: canvasHeight,
      items: enrichedItems,
      pageTitle: pageTitle,
    );
  }

  static final Map<String, String> _base64Cache = {};

  static String? _toImageDataUri(Uint8List bytes, String source) {
    if (bytes.isEmpty) return null;
    final cached = _base64Cache[source];
    if (cached != null) return cached;

    final mimeType = _detectMimeType(bytes, source);
    if (mimeType == null) return null;
    final uri = 'data:$mimeType;base64,${base64Encode(bytes)}';
    _base64Cache[source] = uri;
    return uri;
  }

  static String? _detectMimeType(Uint8List bytes, String source) {
    if (bytes.length >= 8 &&
        bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47) {
      return 'image/png';
    }
    if (bytes.length >= 3 &&
        bytes[0] == 0xFF &&
        bytes[1] == 0xD8 &&
        bytes[2] == 0xFF) {
      return 'image/jpeg';
    }
    if (bytes.length >= 6 &&
        bytes[0] == 0x47 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46) {
      return 'image/gif';
    }
    if (bytes.length >= 12 &&
        bytes[0] == 0x52 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x46 &&
        bytes[8] == 0x57 &&
        bytes[9] == 0x45 &&
        bytes[10] == 0x42 &&
        bytes[11] == 0x50) {
      return 'image/webp';
    }

    final path =
        Uri.tryParse(source)?.path.toLowerCase() ?? source.toLowerCase();
    if (path.endsWith('.png')) return 'image/png';
    if (path.endsWith('.jpg') || path.endsWith('.jpeg')) {
      return 'image/jpeg';
    }
    if (path.endsWith('.gif')) return 'image/gif';
    if (path.endsWith('.webp')) return 'image/webp';
    if (path.endsWith('.avif')) return 'image/avif';
    return null;
  }
}

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import '../server/tesseract_text_recognizer.dart';

import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:shopitem_curator/core/repositories/item_repository.dart';
import 'package:shopitem_curator/core/services/binary_resource_loader.dart';
import 'package:shopitem_curator/core/services/curation_pipeline_service.dart';
import 'package:shopitem_curator/core/services/ocr_extractor_service.dart';
import 'package:shopitem_curator/core/services/raster_foreground_mask.dart';
import 'package:shopitem_curator/core/services/target_fetcher_service.dart';

/// Regenerates checked-in development manifests and flattened canvas PNGs.
///
/// Run from the repository root:
///   dart run tool/generate_curator_assets.dart
Future<void> main(List<String> arguments) async {
  final preferLiveCatalog = arguments.contains('--live');
  final refreshImages = arguments.contains('--refresh-images');
  final rebuildOnly = arguments.contains('--rebuild-only');
  final requestedSources = arguments
      .where(
        (argument) =>
            argument != '--live' &&
            argument != '--refresh-images' &&
            argument != '--rebuild-only',
      )
      .toList(growable: false);
  final sources = requestedSources.isEmpty
      ? const [
          'assets/images/new.jpg',
          'assets/images/media_1787068853075.jpg',
        ]
      : requestedSources;

  const repository = DefaultItemRepository();
  final httpClient = http.Client();
  final targetFetcher = TargetFetcherService(
    httpClient: httpClient,
    preferLiveCatalog: preferLiveCatalog,
  );
  final fileLoader = CallbackBinaryResourceLoader(
    (source) => File(source).readAsBytes(),
  );
  final recognizer = TesseractTextRecognizer.fromEnvironment();
  final pipeline = CurationPipelineService(
    ocrService: OcrExtractorService(recognizer: recognizer),
    targetFetcherService: targetFetcher,
    resourceLoader: fileLoader,
  );

  try {
    if (rebuildOnly) {
      await _rebuildExistingManifests(
        sources: sources,
        repository: repository,
        pipeline: pipeline,
      );
      return;
    }
    if (refreshImages) {
      await _refreshLocalCatalogImages(
        sources: sources,
        repository: repository,
        httpClient: httpClient,
      );
      await _rebuildExistingManifests(
        sources: sources,
        repository: repository,
        pipeline: pipeline,
      );
      return;
    }

    for (final source in sources) {
      final stem = source.split('/').last.split('.').first;
      final canvasPath = 'assets/items/canvas_$stem.png';
      final manifestPath = 'assets/items/manifest_$stem.json';

      final manifest = await pipeline.runPipeline(
        sourceImagePath: source,
        onProgress: (description, progress) {
          stdout.writeln(
            '[$stem ${(progress * 100).round()}%] $description',
          );
        },
      );
      final canvasBytes = _decodePngDataUri(manifest.canvasImage);
      if (canvasBytes == null) {
        throw StateError('Pipeline did not produce a PNG canvas for $source');
      }

      await File(canvasPath).writeAsBytes(canvasBytes, flush: true);
      final persistedManifest = manifest.copyWith(canvasImage: canvasPath);
      await File(manifestPath).writeAsString(
        repository.encodeManifest(persistedManifest, pretty: true),
        flush: true,
      );
      stdout.writeln('Wrote $manifestPath and $canvasPath');
    }
  } finally {
    targetFetcher.close();
    recognizer.close();
    httpClient.close();
  }
}

Future<void> _rebuildExistingManifests({
  required List<String> sources,
  required DefaultItemRepository repository,
  required CurationPipelineService pipeline,
}) async {
  for (final source in sources) {
    final stem = source.split('/').last.split('.').first;
    final canvasPath = 'assets/items/canvas_$stem.png';
    final manifestPath = 'assets/items/manifest_$stem.json';
    final existing = await repository.loadManifest(
      await File(manifestPath).readAsString(),
    );
    final rebuilt = await pipeline.rebuildManifest(existing);
    final canvasBytes = _decodePngDataUri(rebuilt.canvasImage);
    if (canvasBytes == null) {
      throw StateError('Manifest rebuild did not produce a PNG for $source');
    }
    await File(canvasPath).writeAsBytes(canvasBytes, flush: true);
    await File(manifestPath).writeAsString(
      repository.encodeManifest(
        rebuilt.copyWith(canvasImage: canvasPath),
        pretty: true,
      ),
      flush: true,
    );
    stdout.writeln('Rebuilt $manifestPath and $canvasPath');
  }
}

Future<void> _refreshLocalCatalogImages({
  required List<String> sources,
  required DefaultItemRepository repository,
  required http.Client httpClient,
}) async {
  final productsByLocalPath = <String, ({String name, String targetUrl})>{};
  for (final source in sources) {
    final stem = source.split('/').last.split('.').first;
    final manifestFile = File('assets/items/manifest_$stem.json');
    if (!manifestFile.existsSync()) {
      throw StateError(
        'Generate ${manifestFile.path} before using --refresh-images.',
      );
    }
    final manifest = await repository.loadManifest(
      await manifestFile.readAsString(),
    );
    for (final item in manifest.items) {
      final path = item.imageUrl;
      if (path.startsWith('assets/items/item_') && path.endsWith('.png')) {
        productsByLocalPath[path] = (
          name: item.name,
          targetUrl: item.targetUrl,
        );
      }
    }
  }

  final prepared = <_PreparedCatalogImage>[];
  final failures = <String>[];
  for (final entry in productsByLocalPath.entries) {
    final localPngPath = entry.key;
    final product = entry.value;
    stdout.writeln('Refreshing ${product.name} from ${product.targetUrl}');
    try {
      prepared.add(
        await _downloadCatalogImage(
          localPngPath: localPngPath,
          targetUrl: product.targetUrl,
          httpClient: httpClient,
        ),
      );
    } catch (error) {
      failures.add('$localPngPath: $error');
      stderr.writeln('Failed $localPngPath: $error');
    }
  }
  if (failures.isNotEmpty) {
    throw StateError(
      'No assets were replaced because ${failures.length} downloads failed:\n'
      '${failures.join('\n')}',
    );
  }

  // Only replace the checked-in catalog after every requested product has
  // downloaded and decoded successfully, avoiding a half-refreshed asset set.
  for (final image in prepared) {
    await File(image.pngPath).writeAsBytes(image.pngBytes, flush: true);
    await File(image.jpgPath).writeAsBytes(image.jpgBytes, flush: true);
  }
  stdout.writeln('Refreshed ${prepared.length} official Target product images');
}

Future<_PreparedCatalogImage> _downloadCatalogImage({
  required String localPngPath,
  required String targetUrl,
  required http.Client httpClient,
}) async {
  final productUri = Uri.parse(targetUrl);
  final pageResponse = await httpClient.get(
    productUri,
    headers: const {
      'User-Agent': 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) '
          'AppleWebKit/537.36 Chrome/128 Safari/537.36',
      'Accept': 'text/html,application/xhtml+xml',
    },
  ).timeout(const Duration(seconds: 20));
  if (pageResponse.statusCode != 200) {
    throw HttpException(
      'Target PDP returned ${pageResponse.statusCode}',
      uri: productUri,
    );
  }

  final mainImage =
      TargetFetcherService.extractTargetMainImageElement(pageResponse.body);
  if (mainImage == null) {
    throw StateError('Target PDP did not expose a main image: $targetUrl');
  }
  final imageUri = Uri.parse(mainImage).replace(queryParameters: const {
    'wid': '1200',
    'hei': '1200',
    'qlt': '90',
    // Scene7 preserves its product clipping path in png-alpha. This avoids
    // guessing away legitimate white products such as filler paper.
    'fmt': 'png-alpha',
  });
  final imageResponse = await httpClient.get(imageUri, headers: const {
    'Accept': 'image/png,image/*'
  }).timeout(const Duration(seconds: 20));
  if (imageResponse.statusCode != 200) {
    throw HttpException(
      'Target image returned ${imageResponse.statusCode}',
      uri: imageUri,
    );
  }

  final decodedSource = img.decodeImage(imageResponse.bodyBytes);
  if (decodedSource == null) {
    throw StateError('Unsupported Target image: $imageUri');
  }
  final decoded = img.bakeOrientation(decodedSource);
  final cutout = RasterForegroundMask.fromImage(decoded).applyTo(decoded);
  return _PreparedCatalogImage(
    pngPath: localPngPath,
    pngBytes: Uint8List.fromList(img.encodePng(cutout)),
    jpgPath: localPngPath.replaceFirst(RegExp(r'\.png$'), '.jpg'),
    jpgBytes: Uint8List.fromList(img.encodeJpg(decoded, quality: 90)),
  );
}

final class _PreparedCatalogImage {
  const _PreparedCatalogImage({
    required this.pngPath,
    required this.pngBytes,
    required this.jpgPath,
    required this.jpgBytes,
  });

  final String pngPath;
  final Uint8List pngBytes;
  final String jpgPath;
  final Uint8List jpgBytes;
}

Uint8List? _decodePngDataUri(String value) {
  const prefix = 'data:image/png;base64,';
  if (!value.startsWith(prefix)) return null;
  return Uint8List.fromList(base64Decode(value.substring(prefix.length)));
}

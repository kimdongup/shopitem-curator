import 'dart:io';

import 'package:shopitem_curator/core/repositories/item_repository.dart';
import 'package:shopitem_curator/core/services/html_imagemap_exporter.dart';

/// Exports a checked-in manifest as a self-contained interactive HTML file.
///
/// Run from the repository root:
///   dart run tool/export_curator_html.dart [manifest.json] [output.html]
Future<void> main(List<String> arguments) async {
  if (arguments.length > 2) {
    stderr.writeln(
      'Usage: dart run tool/export_curator_html.dart '
      '[manifest.json] [output.html]',
    );
    exitCode = 64;
    return;
  }

  final manifestPath = arguments.isEmpty
      ? 'assets/items/manifest_media_1787068853075.json'
      : arguments[0];
  final outputPath =
      arguments.length < 2 ? 'shopitem_curator_map.html' : arguments[1];
  final manifestFile = File(manifestPath);
  if (!await manifestFile.exists()) {
    stderr.writeln('Manifest not found: $manifestPath');
    exitCode = 66;
    return;
  }

  const repository = DefaultItemRepository();
  final manifest = await repository.loadManifest(
    await manifestFile.readAsString(),
  );
  final exportItems = manifest.items
      .where((item) => item.isApproved)
      .map(
        (item) => PositionedItemExportData(
          item: item,
          x: item.bounds.x,
          y: item.bounds.y,
          width: item.bounds.width,
          height: item.bounds.height,
        ),
      )
      .toList(growable: false);
  final html = HtmlImageMapExporter.generateHtml(
    canvasWidth: manifest.canvasWidth,
    canvasHeight: manifest.canvasHeight,
    items: exportItems,
    pageTitle: 'ShopItem Curator - Target 학용품',
  );

  final outputFile = File(outputPath);
  await outputFile.parent.create(recursive: true);
  await outputFile.writeAsString(html, flush: true);
  stdout.writeln(
    'Exported ${exportItems.length} items from $manifestPath '
    'to $outputPath (${html.length} characters)',
  );
}

// Pure Dart Repository (Zero Flutter Dependencies)

import 'dart:convert';
import '../models/curator_item.dart';

abstract class ItemRepository {
  Future<CuratorManifest> loadManifest(String jsonString);

  String encodeManifest(CuratorManifest manifest, {bool pretty = false});
}

class DefaultItemRepository implements ItemRepository {
  const DefaultItemRepository();

  @override
  Future<CuratorManifest> loadManifest(String jsonString) async {
    try {
      final decoded = jsonDecode(jsonString);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('Manifest root must be a JSON object.');
      }
      final manifest = CuratorManifest.fromJson(decoded);
      _validateManifest(manifest);
      return manifest;
    } on FormatException {
      rethrow;
    } catch (error) {
      throw FormatException('Invalid curator manifest: $error');
    }
  }

  @override
  String encodeManifest(CuratorManifest manifest, {bool pretty = false}) {
    final json = manifest.toJson();
    return pretty
        ? const JsonEncoder.withIndent('  ').convert(json)
        : jsonEncode(json);
  }

  static void _validateManifest(CuratorManifest manifest) {
    if (!manifest.canvasWidth.isFinite ||
        !manifest.canvasHeight.isFinite ||
        manifest.canvasWidth <= 0 ||
        manifest.canvasHeight <= 0) {
      throw const FormatException(
        'Canvas width and height must be finite positive numbers.',
      );
    }

    final itemIds = <String>{};
    for (final item in manifest.items) {
      final id = item.id.trim();
      if (id.isEmpty) {
        throw const FormatException('Every item must have a non-empty id.');
      }
      if (!itemIds.add(id)) {
        throw FormatException('Duplicate item id: $id');
      }
      if (item.quantity < 1) {
        throw FormatException('Item $id must have quantity >= 1.');
      }
      if (!item.price.isFinite || item.price < 0) {
        throw FormatException('Item $id has an invalid price.');
      }

      final bounds = item.bounds;
      if (!bounds.x.isFinite ||
          !bounds.y.isFinite ||
          !bounds.width.isFinite ||
          !bounds.height.isFinite ||
          bounds.width <= 0 ||
          bounds.height <= 0) {
        throw FormatException('Item $id has invalid layout bounds.');
      }
      if (!item.centroid.x.isFinite || !item.centroid.y.isFinite) {
        throw FormatException('Item $id has an invalid centroid.');
      }
      for (final contour in item.contours) {
        for (final point in contour) {
          if (!point.x.isFinite || !point.y.isFinite) {
            throw FormatException('Item $id contains a non-finite contour.');
          }
        }
      }
    }
  }
}

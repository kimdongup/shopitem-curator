import 'dart:convert';
import '../../../models/target_purchase_url.dart';

final class ObservedProductMetadata {
  const ObservedProductMetadata(
      {required this.name,
      required this.targetUrl,
      required this.imageUrl,
      required this.price});
  final String name, targetUrl, imageUrl;
  final double price;

  static List<ObservedProductMetadata> fromHtml(String html) {
    final match = RegExp(
            r'<script id="curator-observed-products" type="application/json">([^<]*)</script>')
        .firstMatch(html);
    if (match == null || match.group(1)!.length > 128 * 1024) return const [];
    try {
      final json = jsonDecode(match.group(1)!);
      if (json is! List || json.length > 50) return const [];
      final result = <ObservedProductMetadata>[];
      for (final item in json) {
        if (item is! Map ||
            item['name'] is! String ||
            item['target_url'] is! String ||
            item['image_url'] is! String ||
            item['price'] is! num) {
          continue;
        }
        final name = item['name'] as String;
        final url = TargetPurchaseUrl.tryParse(item['target_url'] as String);
        final image = Uri.tryParse(item['image_url'] as String);
        final price = (item['price'] as num).toDouble();
        if (url == null ||
            name.trim().isEmpty ||
            name.length > 500 ||
            image == null ||
            image.scheme != 'https' ||
            image.host != 'target.scene7.com' ||
            image.userInfo.isNotEmpty ||
            (image.hasPort && image.port != 443) ||
            !image.path.startsWith('/is/image/Target/') ||
            !price.isFinite ||
            price < 0 ||
            price > 100000) {
          continue;
        }
        result.add(ObservedProductMetadata(
            name: name,
            targetUrl: url.value,
            imageUrl: image.toString(),
            price: price));
      }
      return List.unmodifiable(result);
    } on FormatException {
      return const [];
    }
  }
}

import 'dart:typed_data';

import 'package:flutter/material.dart';

/// Renders a product image from HTTP(S), a bundled asset, or a raster data URI.
///
/// Keeping source selection here prevents product surfaces from drifting into
/// asset-only implementations when live scraping replaces an image URL.
class ProductImage extends StatelessWidget {
  const ProductImage({
    super.key,
    required this.source,
    this.fit = BoxFit.contain,
    this.filterQuality = FilterQuality.medium,
    this.semanticLabel,
    this.placeholderBuilder,
    this.loadingBuilder,
  });

  final String source;
  final BoxFit fit;
  final FilterQuality filterQuality;
  final String? semanticLabel;
  final WidgetBuilder? placeholderBuilder;
  final ImageLoadingBuilder? loadingBuilder;

  bool get _isNetworkSource {
    final uri = Uri.tryParse(source);
    return uri != null && (uri.scheme == 'http' || uri.scheme == 'https');
  }

  bool get _isImageDataUri => source.toLowerCase().startsWith('data:image/');

  Uint8List? _decodeDataUri() {
    if (!_isImageDataUri) return null;
    try {
      final data = UriData.fromUri(Uri.parse(source));
      if (!data.mimeType.toLowerCase().startsWith('image/')) return null;
      return Uint8List.fromList(data.contentAsBytes());
    } on FormatException {
      return null;
    }
  }

  Widget _buildPlaceholder(BuildContext context) {
    return placeholderBuilder?.call(context) ??
        const Center(
          child: Icon(
            Icons.shopping_bag_outlined,
            size: 36,
            color: Colors.black26,
          ),
        );
  }

  Widget _buildLoadingIndicator(
    BuildContext context,
    Widget child,
    ImageChunkEvent? progress,
  ) {
    if (progress == null) return child;

    return Center(
      child: SizedBox(
        width: 20,
        height: 20,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          color: Colors.black26,
          value: progress.expectedTotalBytes == null
              ? null
              : progress.cumulativeBytesLoaded / progress.expectedTotalBytes!,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (source.isEmpty) return _buildPlaceholder(context);

    Widget handleError(
      BuildContext context,
      Object error,
      StackTrace? stackTrace,
    ) {
      return _buildPlaceholder(context);
    }

    if (_isNetworkSource) {
      return Image.network(
        source,
        fit: fit,
        filterQuality: filterQuality,
        semanticLabel: semanticLabel,
        errorBuilder: handleError,
        loadingBuilder: loadingBuilder ?? _buildLoadingIndicator,
      );
    }

    if (_isImageDataUri) {
      final bytes = _decodeDataUri();
      if (bytes == null || bytes.isEmpty) return _buildPlaceholder(context);
      return Image.memory(
        bytes,
        fit: fit,
        filterQuality: filterQuality,
        semanticLabel: semanticLabel,
        errorBuilder: handleError,
      );
    }

    return Image.asset(
      source,
      fit: fit,
      filterQuality: filterQuality,
      semanticLabel: semanticLabel,
      errorBuilder: handleError,
    );
  }
}

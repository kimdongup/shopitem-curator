/// Validates Target product-detail URLs before they are exposed as purchase
/// links. Search pages, image CDN URLs, foreign hosts, and active URI schemes
/// are deliberately rejected.
final class TargetPurchaseUrl {
  const TargetPurchaseUrl._(this.uri);

  final Uri uri;

  /// Canonical, percent-encoded URL safe to pass to launchers and exporters.
  String get value => uri.toString();

  static final RegExp _productPathPattern = RegExp(
    r'^/p/(?:[^/]+/)?-/A-\d+/?$',
    caseSensitive: false,
  );

  static TargetPurchaseUrl? tryParse(String value) {
    final candidate = value.trim();
    if (candidate.isEmpty || _containsControlCharacter(candidate)) {
      return null;
    }

    final uri = Uri.tryParse(candidate);
    if (uri == null ||
        uri.scheme.toLowerCase() != 'https' ||
        uri.userInfo.isNotEmpty ||
        (uri.hasPort && uri.port != 443)) {
      return null;
    }

    final host = uri.host.toLowerCase();
    if (host != 'target.com' && host != 'www.target.com') {
      return null;
    }

    if (!_productPathPattern.hasMatch(uri.path)) {
      return null;
    }

    return TargetPurchaseUrl._(uri);
  }

  static bool isValid(String value) => tryParse(value) != null;

  static bool _containsControlCharacter(String value) =>
      value.codeUnits.any((unit) => unit < 0x20 || unit == 0x7f);

  @override
  String toString() => uri.toString();
}

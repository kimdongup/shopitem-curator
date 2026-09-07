// Pure Dart Port (Zero Flutter Dependencies)

import 'dart:typed_data';

/// Loads binary content for an asset path, file path, or remote URL.
///
/// The core layer only depends on this port. Flutter applications can provide
/// an adapter backed by `rootBundle`, while command-line applications can use
/// a file-system or HTTP implementation without introducing Flutter imports.
abstract interface class BinaryResourceLoader {
  Future<Uint8List> load(String source);
}

typedef BinaryResourceLoadCallback = Future<Uint8List> Function(String source);

/// Small adapter that makes dependency injection and pure Dart tests concise.
final class CallbackBinaryResourceLoader implements BinaryResourceLoader {
  const CallbackBinaryResourceLoader(this._load);

  final BinaryResourceLoadCallback _load;

  @override
  Future<Uint8List> load(String source) => _load(source);
}

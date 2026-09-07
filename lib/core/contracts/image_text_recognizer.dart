// Platform-neutral OCR port. Implementations execute only on the backend.
abstract interface class ImageTextRecognizer {
  Future<List<RecognizedWord>> recognize(List<int> imageBytes);
}

final class RecognizedWord {
  const RecognizedWord(
      {required this.text,
      required this.left,
      required this.top,
      required this.width,
      required this.height,
      required this.lineId,
      this.confidence = 100});
  final String text;
  final int left, top, width, height;
  final String lineId;
  final double confidence;
  double get centerY => top + height / 2;
}

enum OcrFailureKind { engineUnavailable, invalidImage, noItems, busy, failed }

/// Safe categories only: no process stderr, file paths or image data.
final class OcrException implements Exception {
  const OcrException(this.kind);
  final OcrFailureKind kind;
  @override
  String toString() => 'OcrException[${kind.name}]';
}

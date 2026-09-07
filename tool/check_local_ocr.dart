import 'dart:io';
import 'package:shopitem_curator/core/services/ocr_extractor_service.dart';
import '../server/tesseract_text_recognizer.dart';

/// Real local OCR smoke test; no HTTP, API key, or catalog writes.
Future<void> main(List<String> arguments) async {
  final recognizer = TesseractTextRecognizer.fromEnvironment();
  final service = OcrExtractorService(recognizer: recognizer);
  try {
    if (!await recognizer.isAvailable()) {
      stderr.writeln('Install Tesseract and the configured language data.');
      exitCode = 78;
      return;
    }
    final paths = arguments.where((arg) => arg != '--words').toList();
    final sources = paths.isEmpty
        ? ['assets/images/new.jpg', 'assets/images/media_1787068853075.jpg']
        : paths;
    for (final source in sources) {
      if (arguments.contains('--words')) {
        final words =
            await recognizer.recognize(await File(source).readAsBytes());
        for (final word in words) {
          stdout.writeln(
              '${word.lineId} ${word.left},${word.top} ${word.width}x${word.height}: ${word.text}');
        }
        continue;
      }
      final entries = await service.extractItemsFromImage(source,
          imageBytes: await File(source).readAsBytes());
      stdout.writeln('$source: ${entries.length} items');
      for (final entry in entries) {
        stdout.writeln(
            '  ${entry.quantity} x ${entry.cleanName}${entry.isPersonal ? " *" : ""}');
      }
    }
  } finally {
    recognizer.close();
  }
}

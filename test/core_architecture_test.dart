import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('production OCR has no Google API or implicit demo fallback', () {
    final paths = [
      'server/curator_proxy_server.dart',
      'server/tesseract_text_recognizer.dart',
      'lib/core/services/ocr_extractor_service.dart',
    ];
    for (final path in paths) {
      final source = File(path).readAsStringSync();
      for (final forbidden in [
        'generativelanguage.googleapis.com',
        'GEMINI_API_KEY',
        'geminiApiKey',
        'DemoItemExtractionGateway',
        '_hardcodedItems'
      ]) {
        expect(source, isNot(contains(forbidden)), reason: '$path: $forbidden');
      }
    }
    final parser =
        File('lib/core/services/ocr_extractor_service.dart').readAsStringSync();
    expect(parser, isNot(contains('dart:io')));
    expect(parser, isNot(contains('package:http')));
    expect(parser, contains('ImageTextRecognizer'));
  });

  test('Pure Dart core never imports Flutter, dart:ui, or the UI layer', () {
    final violations = <String>[];
    final coreDirectory = Directory('lib/core');

    for (final entity in coreDirectory.listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) {
        continue;
      }

      final source = entity.readAsStringSync();
      for (final forbiddenImport in <String>[
        "package:flutter/",
        "package:flutter_",
        "dart:ui",
        "/ui/",
      ]) {
        if (source.contains(forbiddenImport)) {
          violations.add('${entity.path}: $forbiddenImport');
        }
      }
    }

    expect(
      violations,
      isEmpty,
      reason:
          'Core must stay reusable without Flutter:\n${violations.join('\n')}',
    );
  });

  test('CuratorBloc depends on ports instead of concrete infrastructure', () {
    final source = File('lib/core/bloc/curator_bloc.dart').readAsStringSync();

    for (final forbiddenText in <String>[
      "../services/",
      "package:http/",
      'target.com',
      'scene7.com',
    ]) {
      expect(
        source,
        isNot(contains(forbiddenText)),
        reason: 'BLoC must not contain infrastructure detail: $forbiddenText',
      );
    }
  });

  test('Flutter composition root contains no upstream credential or client',
      () {
    final presentationSources = <File>[
      File('lib/main.dart'),
      ...Directory('lib/ui')
          .listSync(recursive: true)
          .whereType<File>()
          .where((file) => file.path.endsWith('.dart')),
    ];

    for (final forbiddenText in <String>[
      'GEMINI_API_KEY',
      'CURATOR_TARGET_REDSKY_KEY',
      'geminiApiKey',
      'generativelanguage.googleapis.com',
      'OcrExtractorService',
      'TargetFetcherService',
      'TargetCatalogRescraper',
    ]) {
      final violations = presentationSources
          .where((file) => file.readAsStringSync().contains(forbiddenText))
          .map((file) => file.path)
          .toList(growable: false);
      expect(violations, isEmpty,
          reason: 'Flutter must call only the backend proxy; found '
              '$forbiddenText in ${violations.join(', ')}');
    }

    final source = presentationSources.first.readAsStringSync();
    expect(source, contains('BackendProxyGateway'));
    expect(source, contains('CURATOR_BACKEND_URL'));
    expect(source, isNot(contains('HybridCatalogGateway')));
    expect(
      File('lib/core/services/hybrid_catalog_gateway.dart').existsSync(),
      isFalse,
      reason: 'Production proxy failures must never fall back to client-side '
          'Gemini or Target implementations.',
    );
  });
}

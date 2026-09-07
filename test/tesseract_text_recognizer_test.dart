import 'dart:async';
import 'dart:io';
import 'package:image/image.dart' as img;
import 'package:test/test.dart';
import 'package:shopitem_curator/core/services/ocr_extractor_service.dart';
import 'package:shopitem_curator/core/services/backend_proxy_gateway.dart';
import '../server/curator_proxy_server.dart';
import '../server/tesseract_text_recognizer.dart';

void main() {
  test('TSV retains positions and line identifiers, ignores non-word rows', () {
    final words = TesseractTextRecognizer.parseTsv(
        'level\tpage_num\tblock_num\tpar_num\tline_num\tword_num\tleft\ttop\twidth\theight\tconf\ttext\n'
        '5\t1\t1\t1\t1\t1\t10\t20\t40\t15\t95\tRuler\n'
        '5\t1\t2\t1\t1\t1\t10\t80\t40\t15\t95\t \n');
    expect(words.single.text, 'Ruler');
    expect(words.single.left, 10);
    expect(words.single.centerY, 27.5);
    expect(words.single.lineId, '1:1:1:1');
    expect(
        () => TesseractTextRecognizer.parseTsv(
            '5\t1\t1\t1\t1\t1\t-1\t20\t40\t15\t95\tbad'),
        throwsA(isA<OcrException>()));
  });

  test('missing executable is not ready and never extracts demo data',
      () async {
    final engine = TesseractTextRecognizer(
        executable: '/nonexistent/curator-test-tesseract');
    addTearDown(engine.close);
    expect(await engine.isAvailable(), isFalse);
    await expectLater(
        engine.recognize([1]),
        throwsA(isA<OcrException>()
            .having((e) => e.kind, 'kind', OcrFailureKind.engineUnavailable)));
  });

  test('missing language is not ready', () async {
    final engine = TesseractTextRecognizer(
        executable: await _fakeEngine('exit 0'), language: 'kor');
    addTearDown(engine.close);
    expect(await engine.isAvailable(), isFalse);
  }, skip: Platform.isWindows);

  test('invalid bytes are rejected before process OCR', () async {
    final engine =
        TesseractTextRecognizer(executable: await _fakeEngine('exit 0'));
    addTearDown(engine.close);
    await expectLater(
        engine.recognize([1, 2, 3]),
        throwsA(isA<OcrException>()
            .having((e) => e.kind, 'kind', OcrFailureKind.invalidImage)));
  }, skip: Platform.isWindows);

  test('timeout kills process and concurrent requests are bounded', () async {
    final engine = TesseractTextRecognizer(
        executable: await _fakeEngine('exec /bin/sleep 30'),
        timeout: const Duration(milliseconds: 100),
        maxConcurrentJobs: 1);
    addTearDown(engine.close);
    final bytes = img.encodePng(img.Image(width: 20, height: 20));
    final first =
        expectLater(engine.recognize(bytes), throwsA(isA<TimeoutException>()));
    await expectLater(
        engine.recognize(bytes),
        throwsA(isA<OcrException>()
            .having((e) => e.kind, 'kind', OcrFailureKind.busy)));
    await first;
    engine.close();
    expect(await engine.isAvailable(), isFalse);
  }, skip: Platform.isWindows);

  test('real local OCR handles shipped assets and a new generated image',
      () async {
    final engine = TesseractTextRecognizer.fromEnvironment();
    addTearDown(engine.close);
    expect(await engine.isAvailable(), isTrue);
    final service = OcrExtractorService(recognizer: engine);
    final server = CuratorProxyServer(
        config: CuratorProxyConfig(
            bindAddress: InternetAddress.loopbackIPv4, port: 0),
        dependencies: CuratorProxyDependencies(
          checkOcrReady: engine.isAvailable,
          extractOcr: ({required sourceImagePath, required imageBytes}) =>
              service.extractItemsFromImage(sourceImagePath,
                  imageBytes: imageBytes),
          fetchProducts: (_) async => [],
          fetchCandidates: (_) async => [],
          inspectProduct: (_) async => null,
          rescrape: (_) async => throw UnimplementedError(),
        ));
    await server.start();
    addTearDown(server.close);
    final gateway =
        BackendProxyGateway(backendBaseUrl: server.baseUri.toString());
    addTearDown(gateway.close);
    await gateway.waitUntilReady();
    final small = await gateway.extractItemsFromImage('renamed.png',
        imageBytes: await File('assets/images/new.jpg').readAsBytes());
    expect(small.map((e) => e.cleanName),
        ['Hand sanitizer', 'White Board Markers', 'Backpack']);
    expect(small.last.isPersonal, isTrue);
    final table = await service.extractItemsFromImage('also-renamed.jpg',
        imageBytes:
            await File('assets/images/media_1787068853075.jpg').readAsBytes());
    // Source contains 26 rows, including two sanitizer rows (old demo had 25).
    expect(table.length, 26);
    expect(table.firstWhere((e) => e.cleanName == 'Glue Stick').quantity, 8);
    expect(table.firstWhere((e) => e.cleanName == 'Folders').quantity, 4);
    expect(
        table.firstWhere((e) => e.cleanName == 'Backpack').isPersonal, isTrue);
    expect(table.any((e) => e.cleanName == 'Eraser'), isTrue);
    expect(
        table.firstWhere((e) => e.cleanName == 'Watercolor Paints').isPersonal,
        isTrue);
    final generated = img.Image(width: 800, height: 350);
    img.fill(generated, color: img.ColorRgb8(255, 255, 255));
    for (final (i, text)
        in ['3 Rulers', 'Glue Stick x8', 'Backpack*'].indexed) {
      img.drawString(generated, text,
          font: img.arial48,
          x: 40,
          y: 30 + i * 100,
          color: img.ColorRgb8(0, 0, 0));
    }
    final fresh = await service.extractItemsFromImage('new.jpg',
        imageBytes: img.encodePng(generated));
    expect(fresh.map((e) => e.cleanName), ['Rulers', 'Glue Stick', 'Backpack']);
    expect(fresh.map((e) => e.quantity), [3, 8, 1]);
  },
      skip: Platform.environment['CURATOR_TEST_LOCAL_OCR'] != '1',
      timeout: const Timeout(Duration(minutes: 3)));
}

Future<String> _fakeEngine(String body) async {
  final dir = await Directory.systemTemp.createTemp('curator-ocr-test-');
  addTearDown(() => dir.delete(recursive: true));
  final file = File('${dir.path}/engine');
  await file.writeAsString(
      '#!/bin/sh\nif [ "\$1" = "--list-langs" ]; then\n  printf "List of available languages (1):\\neng\\n"\n  exit 0\nfi\n$body\n');
  final result = await Process.run('/bin/chmod', ['700', file.path]);
  expect(result.exitCode, 0);
  return file.path;
}

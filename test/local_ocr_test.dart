import 'package:test/test.dart';
import 'package:shopitem_curator/core/services/ocr_extractor_service.dart';

void main() {
  test('real extraction is injected, bytes forwarded and filename ignored',
      () async {
    final fake = _Recognizer(_words([
      'School Supplies List',
      '* Please label your student items with student name',
      '• Hand sanitizer',
      '¢ White Board Markers',
      '* Backpack*',
      '8 Glue Sticks',
      'Rulers x3',
      '1. 24 count Pencils'
    ]));
    final service = OcrExtractorService(recognizer: fake);
    final items = await service
        .extractItemsFromImage('unknown.jpg', imageBytes: [1, 2, 3]);
    expect(fake.received, [1, 2, 3]);
    expect(items.map((e) => e.cleanName), [
      'Hand sanitizer',
      'White Board Markers',
      'Backpack',
      'Glue Sticks',
      'Rulers',
      '24 count Pencils'
    ]);
    expect(items.map((e) => e.quantity), [1, 1, 1, 8, 3, 1]);
    expect(items.map((e) => e.isPersonal),
        [false, false, true, false, false, false]);
  });

  test('container OCR bullet variants do not pollute names or quantities',
      () async {
    final items = await OcrExtractorService(
        recognizer: _Recognizer(_words([
      '+ Hand sanitizer',
      '» White Board Markers',
      '» Backpack*',
      '+ 3 Rulers',
      'C++ notebook',
      '+PLUS notebook',
    ]))).extractItemsFromImage('list.png', imageBytes: [1]);
    expect(items.map((e) => e.cleanName), [
      'Hand sanitizer',
      'White Board Markers',
      'Backpack',
      'Rulers',
      'C++ notebook',
      '+PLUS notebook',
    ]);
    expect(items.map((e) => e.quantity), [1, 1, 1, 3, 1, 1]);
    expect(items[2].isPersonal, isTrue);
  });

  test('table coordinates separate item, description, quantity and duplicates',
      () async {
    final words = <RecognizedWord>[
      _word('Item', 0, 0, 'header'),
      _word('Description', 300, 0, 'header'),
      _word('Quantity', 600, 0, 'header'),
      _word('Pencils*', 0, 40, 'a'),
      _word('24 count', 300, 40, 'b'),
      _word('2', 600, 40, 'c'),
      _word('Flash cards*', 0, 80, 'd'),
      _word('Addition', 300, 80, 'e'),
      _word('1', 600, 80, 'f'),
      _word('Flash cards*', 0, 120, 'g'),
      _word('Subtraction', 300, 120, 'h'),
      _word('i', 600, 120, 'i'),
    ];
    final items = await OcrExtractorService(recognizer: _Recognizer(words))
        .extractItemsFromImage('new.jpg', imageBytes: [9]);
    expect(items.map((e) => e.cleanName),
        ['Pencils', 'Flash cards (Addition)', 'Flash cards (Subtraction)']);
    expect(items.map((e) => e.quantity), [2, 1, 1]);
    expect(items.first.rawName, contains('24 count'));
    expect(items.every((e) => e.isPersonal), isTrue);
  });

  test('two-column table supports quantities without a description', () async {
    final items = await OcrExtractorService(
        recognizer: _Recognizer([
      _word('Item', 0, 0, 'a'),
      _word('Qty', 600, 0, 'a'),
      _word('Ruler', 0, 40, 'b'),
      _word('3', 600, 40, 'b')
    ])).extractItemsFromImage('arbitrary.png', imageBytes: [1]);
    expect(items.single.cleanName, 'Ruler');
    expect(items.single.quantity, 3);
  });

  test('unreadable explicit table quantities are not silently invented',
      () async {
    final service = OcrExtractorService(
        recognizer: _Recognizer([
      _word('Item', 0, 0, 'a'),
      _word('Qty', 600, 0, 'a'),
      _word('Ruler', 0, 40, 'b')
    ]));
    await expectLater(
        service.extractItemsFromImage('x.png', imageBytes: [1]),
        throwsA(isA<OcrException>()
            .having((e) => e.kind, 'kind', OcrFailureKind.noItems)));
  });

  test('empty OCR and missing bytes never return fixture items', () async {
    final service = OcrExtractorService(recognizer: _Recognizer([]));
    await expectLater(
        service.extractItemsFromImage('assets/images/new.jpg', imageBytes: [1]),
        throwsA(isA<OcrException>()
            .having((e) => e.kind, 'kind', OcrFailureKind.noItems)));
    await expectLater(
        service.extractItemsFromImage('assets/images/new.jpg'),
        throwsA(isA<OcrException>()
            .having((e) => e.kind, 'kind', OcrFailureKind.invalidImage)));
  });

  test('engine failure propagates without demo fallback', () async {
    final service = OcrExtractorService(recognizer: _FailingRecognizer());
    await expectLater(
        service.extractItemsFromImage('new.jpg', imageBytes: [1]),
        throwsA(isA<OcrException>()
            .having((e) => e.kind, 'kind', OcrFailureKind.engineUnavailable)));
  });
}

RecognizedWord _word(String text, int left, int top, String lineId) =>
    RecognizedWord(
        text: text,
        left: left,
        top: top,
        width: text.length * 8,
        height: 20,
        lineId: lineId);
List<RecognizedWord> _words(List<String> lines) =>
    [for (var i = 0; i < lines.length; i++) _word(lines[i], 0, i * 40, '$i')];

class _Recognizer implements ImageTextRecognizer {
  _Recognizer(this.words);
  final List<RecognizedWord> words;
  List<int>? received;
  @override
  Future<List<RecognizedWord>> recognize(List<int> bytes) async {
    received = bytes;
    return words;
  }
}

class _FailingRecognizer implements ImageTextRecognizer {
  @override
  Future<List<RecognizedWord>> recognize(List<int> bytes) async =>
      throw const OcrException(OcrFailureKind.engineUnavailable);
}

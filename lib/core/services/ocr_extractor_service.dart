import '../contracts/catalog_gateways.dart';
import '../contracts/image_text_recognizer.dart';

export '../contracts/catalog_gateways.dart'
    show ExtractedItemEntry, ItemExtractionGateway;
export '../contracts/image_text_recognizer.dart';

/// Pure Dart list/table interpretation. OCR execution is an injected port;
/// neither Flutter nor a cloud SDK is needed, and filenames never select data.
class OcrExtractorService implements ItemExtractionGateway {
  const OcrExtractorService({required this.recognizer});
  final ImageTextRecognizer recognizer;

  @override
  Future<List<ExtractedItemEntry>> extractItemsFromImage(String imagePath,
      {List<int>? imageBytes}) async {
    if (imageBytes == null || imageBytes.isEmpty) {
      throw const OcrException(OcrFailureKind.invalidImage);
    }
    final words = await recognizer.recognize(imageBytes);
    final items = _parse(words);
    if (items.isEmpty) throw const OcrException(OcrFailureKind.noItems);
    return List.unmodifiable(items);
  }

  List<ExtractedItemEntry> _parse(List<RecognizedWord> words) {
    // Headers supply column boundaries, independent of image size/filename.
    final descriptions = words.where(
        (w) => _header(w.text) == 'description' || _header(w.text) == '설명');
    final quantities = words.where(
        (w) => const {'quantity', 'qty', '수량'}.contains(_header(w.text)));
    for (final quantity in quantities) {
      final description = descriptions.where((w) =>
          w.left < quantity.left &&
          (w.centerY - quantity.centerY).abs() < quantity.height * 2);
      if (description.isNotEmpty) {
        return _table(words, description.first, quantity);
      }
    }
    // Two-column Item/Quantity tables need no Description column.
    for (final quantity in quantities) {
      if (words.any((w) =>
          const {'item', 'items', '품목'}.contains(_header(w.text)) &&
          w.left < quantity.left &&
          (w.centerY - quantity.centerY).abs() < quantity.height * 2)) {
        return _table(words, null, quantity);
      }
    }
    return _lines(words)
        .map((row) => _listEntry(_text(row)))
        .whereType<ExtractedItemEntry>()
        .toList();
  }

  List<ExtractedItemEntry> _table(List<RecognizedWord> words,
      RecognizedWord? description, RecognizedWord quantity) {
    final nameEnd = (description?.left ?? quantity.left) - quantity.height / 2;
    final quantityStart = quantity.left - quantity.height / 2;
    final body = words
        .where((w) =>
            w.centerY > quantity.top + quantity.height &&
            w.height >= quantity.height * .35)
        .toList();
    final rows = _lines(body.where((w) => w.left < nameEnd).toList())
        .where((row) => _hasName(_clean(_text(row))))
        .toList();
    final entries = <ExtractedItemEntry>[];
    final specifications = <String>[];
    for (final row in rows) {
      final name = _stripBullet(_text(row));
      final bottom =
          row.map((w) => w.top + w.height).reduce((a, b) => a > b ? a : b);
      final top = row.map((w) => w.top).reduce((a, b) => a < b ? a : b);
      final center = (bottom + top) / 2;
      final countWords = body
          .where((w) =>
              w.left >= quantityStart &&
              (w.centerY - center).abs() <= (bottom - top) * 1.2)
          .toList()
        ..sort((a, b) =>
            (a.centerY - center).abs().compareTo((b.centerY - center).abs()));
      final count =
          countWords.isEmpty ? null : _quantity(countWords.first.text);
      // A detected quantity column must not silently become quantity=1 if
      // unreadable. Ask for a clearer image instead of inventing inventory.
      if (count == null) throw const OcrException(OcrFailureKind.noItems);
      final detail = description == null
          ? ''
          : _text(body
              .where((w) =>
                  w.left >= nameEnd &&
                  w.left < quantityStart &&
                  (w.centerY - center).abs() <= (bottom - top) * .7)
              .toList());
      final cleanName = _clean(name);
      entries.add(ExtractedItemEntry(
          rawName: detail.isEmpty ? name : '$name — $detail',
          cleanName: cleanName,
          isPersonal: name.contains('*'),
          quantity: count));
      specifications.add(_clean(detail));
    }
    // Distinguish e.g. Flash cards / Addition vs Flash cards / Subtraction.
    // Do not collapse separate source rows with the same item name.
    return [
      for (var i = 0; i < entries.length; i++)
        if (specifications[i].isNotEmpty &&
            entries
                    .where((e) =>
                        e.cleanName.toLowerCase() ==
                        entries[i].cleanName.toLowerCase())
                    .length >
                1)
          ExtractedItemEntry(
              rawName: entries[i].rawName,
              cleanName: '${entries[i].cleanName} (${specifications[i]})',
              isPersonal: entries[i].isPersonal,
              quantity: entries[i].quantity)
        else
          entries[i]
    ];
  }

  ExtractedItemEntry? _listEntry(String text) {
    var name = _stripBullet(text);
    if (_isHeading(name)) return null;
    var quantity = 1;
    final suffix =
        RegExp(r'\s+(?:[x×]\s*|qty\s*:?\s*)(\d{1,3})\s*$', caseSensitive: false)
            .firstMatch(name);
    final prefix = RegExp(r'^(\d{1,3})\s+(?:[x×]\s*)?(.+)$').firstMatch(name);
    if (suffix != null) {
      quantity = int.parse(suffix[1]!);
      name = name.substring(0, suffix.start).trim();
    } else if (prefix != null &&
        !RegExp(r'^(?:count|ct|pack|oz|ml|inch)\b', caseSensitive: false)
            .hasMatch(prefix[2]!)) {
      quantity = int.parse(prefix[1]!);
      name = prefix[2]!;
    }
    final clean = _clean(name);
    if (!_hasName(clean) || quantity < 1) return null;
    return ExtractedItemEntry(
        rawName: name,
        cleanName: clean,
        isPersonal: name.contains('*'),
        quantity: quantity);
  }

  static String _header(String s) =>
      s.toLowerCase().replaceAll(RegExp(r'[^a-z가-힣]'), '');
  static String _stripBullet(String s) => s
      .trim()
      .replaceFirst(RegExp(r'^(?:[•●·*¢\-–□✓✔]\s+|\d+[.)]\s+)'), '')
      .replaceAll(RegExp(r'^[|\[\]_\s]+|[|/✓✔¥.\s]+$'), '')
      .trim();
  static String _clean(String s) => _stripBullet(s)
      .replaceAll('*', '')
      .replaceAll(RegExp('[‘’“”]'), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  static bool _hasName(String s) => RegExp(r'[a-zA-Z가-힣]{2}').hasMatch(s);
  static bool _isHeading(String s) => RegExp(
          r'^(?:(?:school\s+)?suppl(?:y|ies)\s+list|shopping\s+list|please\b|.*\bshould be labeled\b|.*\bstudent.*\bname\b|item\s*$|description\s*$|quantity\s*$|준비물\s*목록|.*이름.*적어)',
          caseSensitive: false)
      .hasMatch(s);
  static int? _quantity(String s) {
    final value = s.trim().replaceAll(RegExp(r'^[|\[\]]+|[|\[\]]+$'), '');
    if (const {'i', 'I', 'l', '|'}.contains(value)) return 1;
    final number = int.tryParse(value);
    return number != null && number > 0 && number <= 999 ? number : null;
  }

  static List<List<RecognizedWord>> _lines(List<RecognizedWord> words) {
    final groups = <String, List<RecognizedWord>>{};
    for (final word in words) {
      (groups[word.lineId] ??= []).add(word);
    }
    final rows = groups.values.toList();
    for (final row in rows) {
      row.sort((a, b) => a.left.compareTo(b.left));
    }
    rows.sort((a, b) => a.first.centerY.compareTo(b.first.centerY));
    return rows;
  }

  static String _text(List<RecognizedWord> words) {
    final sorted = [...words]..sort((a, b) => a.left.compareTo(b.left));
    return sorted.map((w) => w.text).join(' ').trim();
  }
}

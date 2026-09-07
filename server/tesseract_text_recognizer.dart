import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:shopitem_curator/core/contracts/image_text_recognizer.dart';

/// Local OCR process adapter. No network, credentials, or shell commands.
final class TesseractTextRecognizer implements ImageTextRecognizer {
  TesseractTextRecognizer(
      {this.executable = 'tesseract',
      this.language = 'eng',
      this.timeout = const Duration(seconds: 30),
      this.maxConcurrentJobs = 2}) {
    if (executable.trim().isEmpty ||
        !RegExp(r'^[a-z_]+(?:\+[a-z_]+)*$').hasMatch(language) ||
        timeout <= Duration.zero ||
        maxConcurrentJobs < 1) {
      throw ArgumentError('Invalid local OCR configuration.');
    }
  }

  factory TesseractTextRecognizer.fromEnvironment({Duration? timeout}) =>
      TesseractTextRecognizer(
          executable:
              Platform.environment['CURATOR_TESSERACT_BIN'] ?? 'tesseract',
          language: Platform.environment['CURATOR_OCR_LANGUAGE'] ?? 'eng',
          timeout: timeout ?? const Duration(seconds: 30));

  final String executable, language;
  final Duration timeout;
  final int maxConcurrentJobs;
  final Set<Process> _processes = {};
  int _activeJobs = 0;
  bool _closed = false;
  Future<bool>? _checking;
  DateTime? _checkedAt;
  bool _available = false;

  /// Probe the executable AND required language packs. Short cache / single
  /// flight keeps public readiness polling cheap and supports later recovery.
  Future<bool> isAvailable() async {
    if (_closed) return false;
    if (_checking != null) return _checking!;
    if (_checkedAt != null &&
        DateTime.now().difference(_checkedAt!) < const Duration(seconds: 2)) {
      return _available;
    }
    final pending = _probe();
    _checking = pending;
    try {
      _available = await pending;
      _checkedAt = DateTime.now();
      return _available;
    } finally {
      _checking = null;
    }
  }

  Future<bool> _probe() async {
    try {
      final output = await _run(['--list-langs'], const Duration(seconds: 3));
      final languages =
          output.split(RegExp(r'\r?\n')).map((s) => s.trim()).toSet();
      return language.split('+').every(languages.contains);
    } on Object {
      return false;
    }
  }

  @override
  Future<List<RecognizedWord>> recognize(List<int> imageBytes) async {
    if (_closed) throw const OcrException(OcrFailureKind.engineUnavailable);
    if (_activeJobs >= maxConcurrentJobs) {
      throw const OcrException(OcrFailureKind.busy);
    }
    _activeJobs++;
    final elapsed = Stopwatch()..start();
    Duration remaining() {
      final budget = timeout - elapsed.elapsed;
      if (budget <= Duration.zero) {
        throw TimeoutException('Local OCR timed out.');
      }
      return budget;
    }

    Directory? temporary;
    try {
      if (!await isAvailable()) {
        throw const OcrException(OcrFailureKind.engineUnavailable);
      }
      // Decoding stays off the HTTP event loop; only JPEG/PNG, one frame,
      // bounded input bytes and decoded dimensions are accepted.
      final input = Uint8List.fromList(imageBytes);
      final normalized = await Isolate.run(() => _prepareImage(input));
      if (_closed) throw const OcrException(OcrFailureKind.engineUnavailable);
      temporary = await Directory.systemTemp.createTemp('curator-ocr-');
      final file = File('${temporary.path}/input.png');
      await file.writeAsBytes(normalized, flush: true);
      final output = await _run([
        await file.resolveSymbolicLinks(),
        'stdout',
        '-l',
        language,
        '--psm',
        '3',
        'tsv'
      ], remaining());
      return await _refineTableNames(
          parseTsv(output), normalized, temporary, remaining);
    } finally {
      try {
        if (temporary != null) await temporary.delete(recursive: true);
      } finally {
        _activeJobs--;
      }
    }
  }

  /// A second, tightly cropped pass for uncertain names only. Coordinates
  /// come from detected headers/quantities, never from asset-specific rules.
  Future<List<RecognizedWord>> _refineTableNames(List<RecognizedWord> words,
      Uint8List png, Directory directory, Duration Function() remaining) async {
    RecognizedWord? description, quantity, item;
    for (final word in words) {
      final header = word.text.toLowerCase().replaceAll(RegExp(r'[^a-z]'), '');
      if (header == 'description') description ??= word;
      if (header == 'quantity' || header == 'qty') quantity ??= word;
      if (header == 'item' || header == 'ttem') item ??= word;
    }
    if (description == null ||
        quantity == null ||
        item == null ||
        (description.centerY - quantity.centerY).abs() > quantity.height * 2) {
      return words;
    }
    final nameEnd = description.left - quantity.height / 2;
    final rows = <String, List<RecognizedWord>>{};
    for (final word in words) {
      if (word.left < nameEnd &&
          word.top > quantity.top + quantity.height &&
          word.height >= quantity.height * .35) {
        (rows[word.lineId] ??= []).add(word);
      }
    }
    var result = [...words];
    var attempts = 0;
    for (final row in rows.values) {
      if (!row.any((w) =>
          (w.confidence < 85 || w.text.contains('™')) &&
          RegExp(r'[a-zA-Z]{2}').hasMatch(w.text))) {
        continue;
      }
      if (++attempts > 16) break;
      final center =
          row.map((w) => w.centerY).reduce((a, b) => a + b) / row.length;
      final counts = words
          .where((w) =>
              w.left >= quantity!.left &&
              (w.centerY - center).abs() < quantity.height * 1.5)
          .toList()
        ..sort((a, b) =>
            (a.centerY - center).abs().compareTo((b.centerY - center).abs()));
      if (counts.isEmpty) continue;
      final count = counts.first;
      final x = math.max(0, item.left - quantity.height);
      final y = math.max(0, count.top - count.height);
      final width = (nameEnd - x).floor();
      final height = (count.height * 2.4).floor();
      if (width < 1 || height < 1) continue;
      remaining();
      final crop = await Isolate.run(() => _nameCrop(png, x, y, width, height));
      final file = File('${directory.path}/name.png');
      await file.writeAsBytes(crop);
      final output = await _run([
        await file.resolveSymbolicLinks(),
        'stdout',
        '-l',
        language,
        '--psm',
        '7',
        'tsv'
      ], remaining());
      final revised = parseTsv(output)
          .where((w) => RegExp(r'[a-zA-Z]{2}|\d|\*').hasMatch(w.text))
          .toList();
      if (revised.isEmpty) continue;
      double mean(List<RecognizedWord> list) {
        final names =
            list.where((w) => RegExp(r'[a-zA-Z]{2}').hasMatch(w.text)).toList();
        return names.isEmpty
            ? 0
            : names.map((w) => w.confidence).reduce((a, b) => a + b) /
                names.length;
      }

      String letters(List<RecognizedWord> list) => list
          .map((w) => w.text)
          .join()
          .toLowerCase()
          .replaceAll(RegExp(r'[^a-z]'), '');
      // Confidence alone can prefer hallucinated check-mark characters. Only
      // accept a small spelling correction to the same observed name.
      if (mean(revised) <= mean(row) ||
          mean(revised) < 60 ||
          _editDistance(letters(row), letters(revised)) > 2) {
        continue;
      }
      result.removeWhere(row.contains);
      result.addAll(revised.map((word) => RecognizedWord(
          text: word.text,
          left: x + (word.left / 3).round(),
          top: y + (word.top / 3).round(),
          width: math.max(1, (word.width / 3).round()),
          height: math.max(1, (word.height / 3).round()),
          lineId: row.first.lineId,
          confidence: word.confidence)));
    }
    return result;
  }

  Future<String> _run(List<String> arguments, Duration budget) async {
    if (_closed) throw const OcrException(OcrFailureKind.engineUnavailable);
    final Process process;
    try {
      process = await Process.start(executable, arguments,
          environment: const {'OMP_THREAD_LIMIT': '1'});
    } on ProcessException {
      throw const OcrException(OcrFailureKind.engineUnavailable);
    }
    _processes.add(process);
    if (_closed) process.kill(ProcessSignal.sigkill);
    final output = BytesBuilder(copy: false);
    var exceeded = false;
    final stdoutDone = process.stdout.forEach((chunk) {
      if (output.length + chunk.length > 2 * 1024 * 1024) {
        exceeded = true;
        process.kill(ProcessSignal.sigkill);
      } else if (!exceeded) {
        output.add(chunk);
      }
    });
    final stderrDone = process.stderr.drain<void>();
    final completed =
        Future.wait<Object?>([process.exitCode, stdoutDone, stderrDone]);
    try {
      final results = await completed.timeout(budget);
      if (results.first != 0 || exceeded) {
        throw const OcrException(OcrFailureKind.failed);
      }
      return utf8.decode(output.takeBytes(), allowMalformed: true);
    } on TimeoutException {
      process.kill(ProcessSignal.sigkill);
      await completed;
      rethrow;
    } finally {
      _processes.remove(process);
    }
  }

  void close() {
    _closed = true;
    for (final process in _processes) {
      process.kill(ProcessSignal.sigkill);
    }
  }

  static List<RecognizedWord> parseTsv(String output) {
    final words = <RecognizedWord>[];
    for (final line in const LineSplitter().convert(output)) {
      final cells = line.split('\t');
      if (cells.length < 12 || cells[0] != '5' || cells[11].trim().isEmpty) {
        continue;
      }
      final geometry = cells.sublist(6, 10).map(int.tryParse).toList();
      if (geometry.any((v) => v == null || v < 0) ||
          geometry[2] == 0 ||
          geometry[3] == 0) {
        throw const OcrException(OcrFailureKind.failed);
      }
      words.add(RecognizedWord(
          text: cells.sublist(11).join('\t').trim(),
          left: geometry[0]!,
          top: geometry[1]!,
          width: geometry[2]!,
          height: geometry[3]!,
          lineId: cells.sublist(1, 5).join(':'),
          confidence: double.tryParse(cells[10]) ?? 0));
    }
    return List.unmodifiable(words);
  }
}

int _editDistance(String a, String b) {
  var previous = List.generate(b.length + 1, (i) => i);
  for (var i = 1; i <= a.length; i++) {
    final row = List.filled(b.length + 1, 0)..[0] = i;
    for (var j = 1; j <= b.length; j++) {
      row[j] = math.min(math.min(row[j - 1] + 1, previous[j] + 1),
          previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1));
    }
    previous = row;
  }
  return previous.last;
}

Uint8List _nameCrop(Uint8List png, int x, int y, int width, int height) {
  final source = img.decodePng(png)!;
  final crop = img.copyCrop(source, x: x, y: y, width: width, height: height);
  return img.encodePng(img.copyResize(crop,
      width: crop.width * 3,
      height: crop.height * 3,
      interpolation: img.Interpolation.cubic));
}

Uint8List _prepareImage(Uint8List bytes) {
  try {
    if (bytes.isEmpty || bytes.length > 8 * 1024 * 1024) {
      throw const OcrException(OcrFailureKind.invalidImage);
    }
    final img.Decoder decoder;
    if (img.JpegDecoder().isValidFile(bytes)) {
      decoder = img.JpegDecoder();
    } else if (img.PngDecoder().isValidFile(bytes)) {
      decoder = img.PngDecoder();
    } else {
      throw const OcrException(OcrFailureKind.invalidImage);
    }
    final info = decoder.startDecode(bytes);
    if (info == null ||
        info.width <= 0 ||
        info.height <= 0 ||
        info.width * info.height > 16000000 ||
        info.numFrames != 1) {
      throw const OcrException(OcrFailureKind.invalidImage);
    }
    final decoded = decoder.decodeFrame(0);
    if (decoded == null) throw const OcrException(OcrFailureKind.invalidImage);
    var image = img.bakeOrientation(decoded);
    final longest = math.max(image.width, image.height);
    final scale = math.min(1.0, 2400 / longest);
    image = img.copyResize(image,
        width: math.max(1, (image.width * scale).round()),
        height: math.max(1, (image.height * scale).round()),
        interpolation: img.Interpolation.cubic);
    return img.encodePng(image);
  } on OcrException {
    rethrow;
  } on Object {
    throw const OcrException(OcrFailureKind.invalidImage);
  }
}

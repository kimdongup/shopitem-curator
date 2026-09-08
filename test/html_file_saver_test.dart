import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shopitem_curator/ui/adapters/html_file_saver.dart';

void main() {
  test('native save writes complete UTF-8 HTML to selected file', () async {
    final directory =
        await Directory.systemTemp.createTemp('curator-html-test-');
    addTearDown(() => directory.delete(recursive: true));
    final destination = '${directory.path}/chosen.html';
    final saver = PlatformHtmlFileSaver(choosePath: (filename) async {
      expect(filename, '목록-curator.html');
      return destination;
    });
    const html =
        '<!DOCTYPE html><html lang="ko"><meta charset="UTF-8"><body>내 상품 ↘</body></html>';
    expect(await saver.save(filename: '목록-curator.html', html: html), isTrue);
    expect(await File(destination).readAsString(), html);
  });
  test('cancel never writes and web bypasses native save dialog', () async {
    var writes = 0;
    final cancelled = PlatformHtmlFileSaver(
        choosePath: (_) async => null,
        writeFile: (_, __) async {
          writes++;
        });
    expect(await cancelled.save(filename: 'list.html', html: 'test'), isFalse);
    expect(writes, 0);
    final web = PlatformHtmlFileSaver(
        isWeb: true,
        choosePath: (_) async =>
            throw StateError('must not open native dialog'),
        writeFile: (file, path) async {
          writes++;
          expect(file.mimeType, 'text/html');
          expect(path, 'list.html');
          expect(await file.readAsString(), '전체 HTML 한글');
        });
    expect(await web.save(filename: 'list.html', html: '전체 HTML 한글'), isTrue);
    expect(writes, 1);
  });
  test('write failures propagate and filenames are path-safe', () async {
    final saver = PlatformHtmlFileSaver(
        choosePath: (_) async => 'test.html',
        writeFile: (_, __) async => throw StateError('denied'));
    await expectLater(
        saver.save(filename: 'test.html', html: 'test'), throwsStateError);
    expect(curatorHtmlFilename('assets/images/내 목록.png'), '내 목록-curator.html');
    expect(curatorHtmlFilename('assets/images/a:b?.jpg'), 'a_b_-curator.html');
    expect(curatorHtmlFilename(''), 'curator-curator.html');
  });
}

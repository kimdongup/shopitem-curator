@TestOn('browser')
library;

import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'package:flutter_test/flutter_test.dart';
import 'package:shopitem_curator/ui/adapters/html_file_saver.dart';

@JS('document.querySelector')
external JSObject? _querySelector(JSString selector);
@JS('fetch')
external JSPromise<JSObject> _fetch(JSString url);

void main() {
  test('Web emits an HTML download with complete UTF-8 blob and filename',
      () async {
    const html =
        '<!DOCTYPE html><html><meta charset="utf-8"><body>내 상품 ↘</body></html>';
    expect(
        await saveHtmlFile(filename: '내-목록-curator.html', html: html), isTrue);
    final anchor = _querySelector('#__x_file_dom_element a'.toJS)!;
    expect(anchor.getProperty<JSString>('download'.toJS).toDart,
        '내-목록-curator.html');
    final url = anchor.getProperty<JSString>('href'.toJS);
    expect(url.toDart, startsWith('blob:'));
    final response = await _fetch(url).toDart;
    final text =
        await response.callMethod<JSPromise<JSString>>('text'.toJS).toDart;
    expect(text.toDart, html);
  });
}

import 'dart:convert';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';

typedef HtmlFileSaver = Future<bool> Function(
    {required String filename, required String html});

/// Platform delivery only. HTML generation and geometry remain Pure Dart.
Future<bool> saveHtmlFile({required String filename, required String html}) =>
    const PlatformHtmlFileSaver().save(filename: filename, html: html);

class PlatformHtmlFileSaver {
  const PlatformHtmlFileSaver(
      {this.isWeb = kIsWeb,
      this.choosePath = _choosePath,
      this.writeFile = _writeFile});
  final bool isWeb;
  final Future<String?> Function(String filename) choosePath;
  final Future<void> Function(XFile file, String path) writeFile;

  Future<bool> save({required String filename, required String html}) async {
    // getSaveLocation is unsupported on Web; XFile uses a browser download.
    final path = isWeb ? filename : await choosePath(filename);
    if (path == null) return false;
    final bytes = Uint8List.fromList(utf8.encode(html));
    await writeFile(
        XFile.fromData(bytes,
            name: filename, mimeType: 'text/html', length: bytes.length),
        path);
    return true;
  }

  static Future<String?> _choosePath(String filename) async =>
      (await getSaveLocation(
              suggestedName: filename,
              acceptedTypeGroups: const [
            XTypeGroup(
                label: 'HTML',
                extensions: ['html'],
                mimeTypes: ['text/html'],
                uniformTypeIdentifiers: ['public.html'])
          ]))
          ?.path;
  static Future<void> _writeFile(XFile file, String path) => file.saveTo(path);
}

String curatorHtmlFilename(String sourceImage) {
  var name = sourceImage.split(RegExp(r'[/\\]')).last;
  final extension = name.lastIndexOf('.');
  if (extension > 0) name = name.substring(0, extension);
  name = name.replaceAll(RegExp(r'[\x00-\x1f\x7f<>:"/\\|?*]'), '_').trim();
  if (name.isEmpty || name == '.' || name == '..') name = 'curator';
  name = String.fromCharCodes(name.runes.take(80));
  return '$name-curator.html';
}

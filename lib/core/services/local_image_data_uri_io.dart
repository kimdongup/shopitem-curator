import 'dart:convert';
import 'dart:io';

/// Reads a local image as a data URI on Dart IO platforms.
String? readLocalImageAsDataUri(String path) {
  try {
    final file = File(path);
    if (!file.existsSync()) {
      return null;
    }

    final bytes = file.readAsBytesSync();
    final extension = path.split('.').last.toLowerCase();
    final mimeType = switch (extension) {
      'jpg' || 'jpeg' => 'image/jpeg',
      _ => 'image/png',
    };
    return 'data:$mimeType;base64,${base64Encode(bytes)}';
  } on FileSystemException {
    return null;
  }
}

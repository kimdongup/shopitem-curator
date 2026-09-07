import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:shopitem_curator/core/contracts/source_document_repository.dart';

final class DocumentStorageException implements Exception {
  const DocumentStorageException(this.statusCode, this.message);
  final int statusCode;
  final String message;
}

/// One backend process owns this catalog. Mutations are serialized and deletes
/// are staged in a recoverable trash directory with rollback on rename errors.
final class FileSourceDocumentRepository implements SourceDocumentRepository {
  FileSourceDocumentRepository({
    required Directory assetsDirectory,
    this.maxImageBytes = 8 * 1024 * 1024,
  }) : _root = assetsDirectory.absolute;

  final Directory _root;
  final int maxImageBytes;
  Future<void> _tail = Future.value();

  Future<T> _locked<T>(Future<T> Function() action) {
    final result = _tail.then((_) => action());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  static bool _safeName(String name) =>
      name.isNotEmpty &&
      name.length <= 180 &&
      utf8.encode(name).length <= 240 &&
      !name.startsWith('.') &&
      !RegExp(r'[/\\\x00-\x1f\x7f]').hasMatch(name);

  static bool _isImage(String name) =>
      RegExp(r'\.(jpe?g|png)$', caseSensitive: false).hasMatch(name);

  String _imageName(String path) {
    const prefix = 'assets/images/';
    final name = path.startsWith(prefix) ? path.substring(prefix.length) : '';
    if (!_safeName(name) || !_isImage(name)) {
      throw const DocumentStorageException(400, 'Invalid document path.');
    }
    return name;
  }

  Future<Directory> _directory(String name) async {
    for (final directory in [_root, Directory('${_root.path}/$name')]) {
      final type =
          await FileSystemEntity.type(directory.path, followLinks: false);
      if (type != FileSystemEntityType.directory &&
          type != FileSystemEntityType.notFound) {
        throw const DocumentStorageException(409, 'Unsafe asset directory.');
      }
      if (type == FileSystemEntityType.notFound) await directory.create();
    }
    return Directory('${_root.path}/$name');
  }

  Future<File> _sourceFile(String path) async {
    final name = _imageName(path);
    final images = await _directory('images');
    final file = File('${images.path}/$name');
    if (await FileSystemEntity.type(file.path, followLinks: false) !=
        FileSystemEntityType.file) {
      throw const DocumentStorageException(404, 'Document not found.');
    }
    return file;
  }

  @override
  Future<List<String>> listDocuments() => _locked(() async {
        final images = await _directory('images');
        final documents = <String>[];
        await for (final entry in images.list(followLinks: false)) {
          final name = entry.uri.pathSegments.last;
          if (entry is File && _safeName(name) && _isImage(name)) {
            documents.add('assets/images/$name');
          }
        }
        documents.sort();
        return documents;
      });

  @override
  Future<List<int>> readDocument(String sourceImagePath) => _locked(() async {
        final file = await _sourceFile(sourceImagePath);
        if (await file.length() > maxImageBytes) {
          throw const DocumentStorageException(413, 'Document is too large.');
        }
        return file.readAsBytes();
      });

  @override
  Future<String> importDocument(String filename, List<int> bytes) =>
      _locked(() async {
        if (!_safeName(filename) || !_isImage(filename)) {
          throw const DocumentStorageException(
              400, 'Use a JPEG or PNG filename.');
        }
        if (bytes.isEmpty || bytes.length > maxImageBytes) {
          throw const DocumentStorageException(
              413, 'Document is empty or too large.');
        }
        final data = Uint8List.fromList(bytes);
        final decoder = filename.toLowerCase().endsWith('.png')
            ? img.PngDecoder()
            : img.JpegDecoder();
        try {
          final info = decoder.startDecode(data);
          if (info == null ||
              info.width <= 0 ||
              info.height <= 0 ||
              info.width * info.height > 16000000 ||
              decoder.decodeFrame(0) == null) {
            throw const FormatException('Invalid image');
          }
        } catch (_) {
          throw const DocumentStorageException(
              400, 'Invalid JPEG/PNG or too many pixels.');
        }
        final images = await _directory('images');
        final stem = filename.substring(0, filename.lastIndexOf('.'));
        final extension = filename.substring(filename.lastIndexOf('.'));
        var name = filename;
        var suffix = 1;
        while (await FileSystemEntity.type('${images.path}/$name',
                followLinks: false) !=
            FileSystemEntityType.notFound) {
          final ending = '_${suffix++}$extension';
          final runes = stem.runes.toList();
          while (!_safeName('${String.fromCharCodes(runes)}$ending')) {
            runes.removeLast();
          }
          name = '${String.fromCharCodes(runes)}$ending';
        }
        final temporary = File('${images.path}/.upload-${_nonce()}');
        try {
          await temporary.writeAsBytes(data, flush: true);
          await temporary.rename('${images.path}/$name');
        } finally {
          if (await temporary.exists()) await temporary.delete();
        }
        return 'assets/images/$name';
      });

  @override
  Future<void> deleteDocument(String sourceImagePath) => _locked(() async {
        final source = await _sourceFile(sourceImagePath);
        final items = await _directory('items');
        final owned = <String>{};
        final shared = <String>{};
        final manifests = <File>[];
        // Fail closed if ownership cannot be established. Never guess which
        // product images belong to a document from a filename prefix.
        await for (final entry in items.list(followLinks: false)) {
          if (!entry.path.endsWith('.json')) continue;
          if (entry is! File) {
            throw const DocumentStorageException(409, 'Unsafe asset metadata.');
          }
          late final Map<String, dynamic> json;
          try {
            if (await entry.length() > 16 * 1024 * 1024) {
              throw const FormatException();
            }
            json =
                jsonDecode(await entry.readAsString()) as Map<String, dynamic>;
            if (json['source_image'] is! String || json['items'] is! List) {
              throw const FormatException();
            }
          } catch (_) {
            throw const DocumentStorageException(
                409, 'Asset ownership metadata is invalid.');
          }
          final references = <String>{};
          void collect(Object? value) {
            if (value is String && value.startsWith('assets/items/')) {
              final name = value.substring('assets/items/'.length);
              if (!_safeName(name) || name.endsWith('.json')) {
                throw const DocumentStorageException(
                    409, 'Unsafe asset reference.');
              }
              references.add(name);
            } else if (value is List) {
              for (final child in value) {
                collect(child);
              }
            } else if (value is Map) {
              for (final child in value.values) {
                collect(child);
              }
            }
          }

          collect(json);
          if (json['source_image'] == sourceImagePath) {
            manifests.add(entry);
            owned.addAll(references);
          } else {
            shared.addAll(references);
          }
        }
        final targets = <File>[source, ...manifests];
        for (final name in owned.difference(shared)) {
          final file = File('${items.path}/$name');
          final type =
              await FileSystemEntity.type(file.path, followLinks: false);
          if (type == FileSystemEntityType.notFound) continue;
          if (type != FileSystemEntityType.file) {
            throw const DocumentStorageException(
                409, 'Unsafe generated asset.');
          }
          targets.add(file);
        }
        final trashRoot = await _directory('.document_trash');
        final trash = await Directory('${trashRoot.path}/${_nonce()}').create();
        await Directory('${trash.path}/images').create();
        await Directory('${trash.path}/items').create();
        final moved = <(String, String)>[];
        try {
          for (final file in targets) {
            final category = file.path == source.path ? 'images' : 'items';
            final destination =
                '${trash.path}/$category/${file.uri.pathSegments.last}';
            await file.rename(destination);
            moved.add((file.path, destination));
          }
        } catch (_) {
          for (final (original, destination) in moved.reversed) {
            await File(destination).rename(original);
          }
          rethrow;
        }
      });

  static String _nonce() =>
      '${DateTime.now().microsecondsSinceEpoch}-${Random.secure().nextInt(1 << 32)}';
}

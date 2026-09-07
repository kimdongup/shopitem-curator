import 'dart:convert';
import 'dart:io';

import 'package:image/image.dart' as img;
import 'package:test/test.dart';

import '../server/file_source_document_repository.dart';

void main() {
  late Directory temporary;
  late FileSourceDocumentRepository repository;
  final png = img.encodePng(img.Image(width: 4, height: 4));

  setUp(() async {
    temporary =
        await Directory.systemTemp.createTemp('curator-documents-test-');
    repository = FileSourceDocumentRepository(assetsDirectory: temporary);
  });
  tearDown(() async => temporary.delete(recursive: true));

  test('imports real images, preserves original, lists them after restart',
      () async {
    final path = await repository.importDocument('새 문서.png', png);
    expect(path, 'assets/images/새 문서.png');
    expect(await repository.readDocument(path), png);
    final restarted = FileSourceDocumentRepository(assetsDirectory: temporary);
    expect(await restarted.listDocuments(), [path]);
    final copies = await Future.wait([
      repository.importDocument('새 문서.png', png),
      repository.importDocument('새 문서.png', png),
    ]);
    expect(copies.toSet(), hasLength(2));
    expect(await repository.listDocuments(), hasLength(3));
    expect(await repository.readDocument(path), png);
  });

  test('rejects traversal, unsupported content, empty and oversized uploads',
      () async {
    for (final name in [
      '../bad.png',
      '/bad.png',
      r'..\bad.png',
      '.hidden.png',
      'bad.pdf'
    ]) {
      await expectLater(repository.importDocument(name, png),
          throwsA(isA<DocumentStorageException>()));
    }
    await expectLater(repository.importDocument('bad.png', [1, 2, 3]),
        throwsA(isA<DocumentStorageException>()));
    await expectLater(repository.importDocument('empty.png', []),
        throwsA(isA<DocumentStorageException>()));
    final limited = FileSourceDocumentRepository(
        assetsDirectory: temporary, maxImageBytes: 2);
    await expectLater(limited.importDocument('large.png', png),
        throwsA(isA<DocumentStorageException>()));
    expect(await repository.listDocuments(), isEmpty);
    for (final path in [
      'assets/images/../../secret.png',
      'assets/items/file.png',
      '/tmp/a.png'
    ]) {
      await expectLater(repository.deleteDocument(path),
          throwsA(isA<DocumentStorageException>()));
      await expectLater(repository.readDocument(path),
          throwsA(isA<DocumentStorageException>()));
    }
  });

  test(
      'deletes source and exclusive manifest/assets but preserves shared assets',
      () async {
    final a = await repository.importDocument('a.png', png);
    final b = await repository.importDocument('b.png', png);
    final items = await Directory('${temporary.path}/items').create();
    for (final name in [
      'canvas_a.png',
      'canvas_b.png',
      'shared.png',
      'only_a.png',
      'unrelated.png'
    ]) {
      await File('${items.path}/$name').writeAsBytes(png);
    }
    await File('${items.path}/manifest_a.json').writeAsString(jsonEncode({
      'source_image': a,
      'canvas_image': 'assets/items/canvas_a.png',
      'items': [
        {'image_url': 'assets/items/shared.png'},
        {'image_url': 'assets/items/only_a.png'}
      ],
    }));
    await File('${items.path}/manifest_b.json').writeAsString(jsonEncode({
      'source_image': b,
      'canvas_image': 'assets/items/canvas_b.png',
      'items': [
        {'image_url': 'assets/items/shared.png'}
      ],
    }));
    await repository.deleteDocument(a);
    expect(await repository.listDocuments(), [b]);
    for (final name in ['canvas_a.png', 'only_a.png', 'manifest_a.json']) {
      expect(await File('${items.path}/$name').exists(), isFalse, reason: name);
    }
    for (final name in [
      'canvas_b.png',
      'shared.png',
      'manifest_b.json',
      'unrelated.png'
    ]) {
      expect(await File('${items.path}/$name').exists(), isTrue, reason: name);
    }
    final trashFiles = await Directory('${temporary.path}/.document_trash')
        .list(recursive: true)
        .where((entry) => entry is File)
        .toList();
    expect(trashFiles, hasLength(4));
    expect(trashFiles.any((entry) => entry.path.endsWith('/images/a.png')),
        isTrue);
    await repository.deleteDocument(b);
    expect(await repository.listDocuments(), isEmpty);
    expect(await File('${items.path}/shared.png').exists(), isFalse);
    final restarted = FileSourceDocumentRepository(assetsDirectory: temporary);
    expect(await restarted.listDocuments(), isEmpty);
  });

  test('invalid manifest ownership fails before moving any source', () async {
    final path = await repository.importDocument('a.png', png);
    final items = await Directory('${temporary.path}/items').create();
    await File('${items.path}/manifest_b.json').writeAsString('{invalid');
    await expectLater(repository.deleteDocument(path),
        throwsA(isA<DocumentStorageException>()));
    expect(await repository.readDocument(path), png);
    expect(
        await Directory('${temporary.path}/.document_trash').exists(), isFalse);
  });

  test('symlinks cannot escape the document or generated-asset boundary',
      () async {
    final path = await repository.importDocument('a.png', png);
    final outside =
        await File('${temporary.path}/outside.png').writeAsBytes(png);
    await Link('${temporary.path}/images/link.png').create(outside.path);
    expect(await repository.listDocuments(), [path]);
    await expectLater(repository.deleteDocument('assets/images/link.png'),
        throwsA(isA<DocumentStorageException>()));
    await expectLater(repository.readDocument('assets/images/link.png'),
        throwsA(isA<DocumentStorageException>()));
    final items = await Directory('${temporary.path}/items').create();
    await Link('${items.path}/escape.png').create(outside.path);
    await File('${items.path}/manifest.json').writeAsString(jsonEncode({
      'source_image': path,
      'canvas_image': 'assets/items/escape.png',
      'items': [],
    }));
    await expectLater(repository.deleteDocument(path),
        throwsA(isA<DocumentStorageException>()));
    expect(await repository.readDocument(path), png);
    expect(await outside.readAsBytes(), png);
  });
}

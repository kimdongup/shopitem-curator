import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:shopitem_curator/core/contracts/catalog_gateways.dart';
import 'package:shopitem_curator/core/contracts/source_document_repository.dart';
import 'package:shopitem_curator/core/models/browser_project.dart';
import 'package:shopitem_curator/core/models/target_purchase_url.dart';
import 'file_source_document_repository.dart';

/// Local project persistence plus short-lived, project-scoped extension grants.
/// No Target network client or browser cookies belong in this boundary.
final class BrowserProjectStore {
  BrowserProjectStore(
      {required this.directory,
      required this.documents,
      required this.extract,
      DateTime Function()? now})
      : _now = now ?? DateTime.now;
  final Directory directory;
  final SourceDocumentRepository documents;
  final Future<List<ExtractedItemEntry>> Function(String, List<int>) extract;
  final DateTime Function() _now;
  final _random = Random.secure();
  final Map<String, _Grant> _codes = {};
  final Map<String, _Grant> _sessions = {};
  Future<void> _tail = Future.value();
  static final _idPattern = RegExp(r'^[a-f0-9]{32}$');
  static final _itemPattern = RegExp(r'^item_[0-9]{1,2}$');

  Future<T> _locked<T>(Future<T> Function() action) {
    final result = _tail.then((_) => action());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  String _token() => List.generate(
      16, (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  Never _fail(int status, String message) =>
      throw DocumentStorageException(status, message);

  Future<void> _safeDirectory(Directory dir) async {
    final type = await FileSystemEntity.type(dir.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      await dir.create();
    } else if (type != FileSystemEntityType.directory) {
      _fail(409, 'Unsafe project storage.');
    }
  }

  Future<Directory> _root() async {
    // Parent is the configured assets directory; reject linked storage roots.
    await _safeDirectory(directory.parent);
    await _safeDirectory(directory);
    return directory;
  }

  Future<Directory> _projectDirectory(String id) async {
    if (!_idPattern.hasMatch(id)) _fail(400, 'Invalid project ID.');
    final root = await _root();
    final dir = Directory('${root.path}/$id');
    if (await FileSystemEntity.type(dir.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      _fail(404, 'Project not found.');
    }
    return dir;
  }

  Future<Uint8List> _readFile(File file, int limit) async {
    if (await FileSystemEntity.type(file.path, followLinks: false) !=
        FileSystemEntityType.file) {
      _fail(404, 'Project asset not found.');
    }
    if (await file.length() > limit) _fail(413, 'Project asset is too large.');
    return file.readAsBytes();
  }

  Future<BrowserProject> _read(String id, {bool checkSource = true}) async {
    final dir = await _projectDirectory(id);
    final json = jsonDecode(utf8
        .decode(await _readFile(File('${dir.path}/project.json'), 256 * 1024)));
    final project =
        BrowserProject.fromJson(Map<String, dynamic>.from(json as Map));
    if (project.id != id ||
        (checkSource &&
            !(await documents.listDocuments())
                .contains(project.sourceImagePath))) {
      _fail(404, 'Source document was removed.');
    }
    return project;
  }

  Future<void> _save(Directory dir, BrowserProject project) async {
    final pending = File('${dir.path}/${_token()}.tmp');
    await pending.writeAsString(jsonEncode(project.toJson()), flush: true);
    await pending.rename('${dir.path}/project.json');
  }

  Future<BrowserProject> open(String path) => _locked(() async {
        if (!(await documents.listDocuments()).contains(path)) {
          _fail(404, 'Source document not found.');
        }
        final root = await _root();
        var count = 0;
        await for (final entity in root.list(followLinks: false)) {
          final id = entity.uri.pathSegments.where((s) => s.isNotEmpty).last;
          if (entity is! Directory || !_idPattern.hasMatch(id)) continue;
          count++;
          final project = await _read(id);
          if (project.sourceImagePath == path) return project;
        }
        if (count >= 100) {
          _fail(409, 'Project limit reached. Delete an old document first.');
        }
        final entries = await extract(path, await documents.readDocument(path));
        if (entries.isEmpty || entries.length > 50) {
          _fail(422, 'The checklist must contain 1–50 items.');
        }
        final id = _token();
        final dir = Directory('${root.path}/$id');
        await dir.create();
        final project = BrowserProject(
            id: id,
            sourceImagePath: path,
            revision: 0,
            entries: [
              for (var i = 0; i < entries.length; i++)
                BrowserProjectEntry(
                    id: 'item_$i',
                    query: entries[i].cleanName,
                    quantity: entries[i].quantity,
                    isPersonal: entries[i].isPersonal)
            ]);
        await _save(dir, project);
        return project;
      });

  Future<BrowserProject> read(String id) => _locked(() => _read(id));
  void _expire() {
    _codes.removeWhere((_, grant) => !grant.expires.isAfter(_now()));
    _sessions.removeWhere((_, grant) => !grant.expires.isAfter(_now()));
  }

  Future<String> createCode(String id) => _locked(() async {
        await _read(id);
        _expire();
        _codes.removeWhere((_, g) => g.projectId == id);
        if (_codes.length >= 100) _fail(429, 'Too many pairing requests.');
        final code = _token();
        _codes[code] = _Grant(id, '', _now().add(const Duration(minutes: 2)));
        return code;
      });
  Future<Map<String, Object?>> pair(String code, String extensionId) =>
      _locked(() async {
        _expire();
        final grant = _codes.remove(code);
        if (grant == null) _fail(401, 'Pairing code expired or invalid.');
        final project = await _read(grant.projectId);
        _sessions.removeWhere((_, g) => g.projectId == grant.projectId);
        final token = _token() + _token();
        _sessions[token] = _Grant(
            grant.projectId, extensionId, _now().add(const Duration(hours: 8)));
        return {'token': token, 'project': project.toJson()};
      });
  String authorize(String token, String extensionId) {
    _expire();
    final grant = _sessions[token];
    if (grant == null || grant.extensionId != extensionId) {
      _fail(401, 'Reconnect the extension from Curator.');
    }
    return grant.projectId;
  }

  void disconnect(String token, String extensionId) {
    authorize(token, extensionId);
    _sessions.remove(token);
  }

  Future<Uint8List> image(String id, String itemId, String version) =>
      _locked(() async {
        final project = await _read(id, checkSource: false);
        final entry = project.entries.where((e) => e.id == itemId).firstOrNull;
        if (entry == null ||
            entry.status != 'selected' ||
            entry.imageVersion != version ||
            !_idPattern.hasMatch(version)) {
          _fail(409, 'Refresh the project before loading its image.');
        }
        final dir = await _projectDirectory(id);
        return _readFile(File('${dir.path}/$version.png'), 2 * 1024 * 1024);
      });

  Future<BrowserProject> update(String id, Map<String, dynamic> body) =>
      _locked(() async {
        final project = await _read(id);
        final itemId = body['item_id'];
        final operation = body['operation_id'];
        if (itemId is! String ||
            !_itemPattern.hasMatch(itemId) ||
            operation is! String ||
            !_idPattern.hasMatch(operation)) {
          _fail(400, 'Invalid selection identifier.');
        }
        final item = project.entries.where((e) => e.id == itemId).firstOrNull;
        if (item == null) _fail(404, 'Checklist item not found.');
        // Retrying an acknowledged write must not save twice or advance twice.
        if (item.operationId == operation) return project;
        if (body['revision'] != project.revision) {
          _fail(409, 'The project changed. Refresh and select again.');
        }
        final skip = body['action'] == 'skip';
        if (!skip && body['action'] != 'select') {
          _fail(400, 'Invalid selection action.');
        }
        var name = item.query;
        var url = '';
        var price = 0.0;
        var version = '';
        Uint8List? png;
        if (!skip) {
          final rawUrl = body['target_url'];
          final parsed = rawUrl is String && rawUrl.length <= 2048
              ? TargetPurchaseUrl.tryParse(rawUrl)
              : null;
          if (parsed == null) {
            _fail(400, 'Open a Target product detail page first.');
          }
          // No tracking query or fragment is needed to purchase the selected item.
          url =
              Uri(scheme: 'https', host: parsed.uri.host, path: parsed.uri.path)
                  .toString();
          final rawName = body['name'];
          if (rawName is! String ||
              rawName.trim().isEmpty ||
              rawName.length > 300 ||
              rawName.codeUnits.any((c) => c < 32)) {
            _fail(400, 'Invalid product name.');
          }
          name = rawName.trim();
          final rawPrice = body['price'];
          if (rawPrice is! num ||
              !rawPrice.isFinite ||
              rawPrice < 0 ||
              rawPrice > 100000) {
            _fail(400, 'Invalid price.');
          }
          price = rawPrice.toDouble();
          final encoded = body['image_base64'];
          if (encoded is! String || encoded.length > 2800000) {
            _fail(413, 'Crop a smaller image.');
          }
          try {
            final bytes = base64Decode(encoded);
            if (bytes.length > 2 * 1024 * 1024) {
              _fail(413, 'Crop a smaller image.');
            }
            final decoder = img.PngDecoder();
            final info = decoder.startDecode(bytes);
            if (info == null ||
                info.width <= 0 ||
                info.height <= 0 ||
                info.width > 1200 ||
                info.height > 1200 ||
                info.numFrames != 1) {
              _fail(
                  400, 'A single PNG crop of at most 1200 × 1200 is required.');
            }
            final decoded = decoder.decodeFrame(0);
            if (decoded == null) _fail(400, 'The crop could not be decoded.');
            png = Uint8List.fromList(img.encodePng(decoded));
            if (png.length > 2 * 1024 * 1024) {
              _fail(413, 'Crop a smaller image.');
            }
          } on FormatException {
            _fail(400, 'Invalid PNG crop.');
          }
          version = _token();
        }
        final nextItem = BrowserProjectEntry(
            id: item.id,
            query: item.query,
            quantity: item.quantity,
            isPersonal: item.isPersonal,
            status: skip ? 'skipped' : 'selected',
            name: name,
            targetUrl: url,
            price: price,
            imageVersion: version,
            operationId: operation);
        final next = BrowserProject(
            id: id,
            sourceImagePath: project.sourceImagePath,
            revision: project.revision + 1,
            entries: project.entries
                .map((e) => e.id == item.id ? nextItem : e)
                .toList());
        final dir = await _projectDirectory(id);
        if (png != null) {
          await File('${dir.path}/$version.png').writeAsBytes(png, flush: true);
        }
        await _save(dir, next);
        // Only a replaced capture owned by this project is removed, after commit.
        if (_idPattern.hasMatch(item.imageVersion)) {
          final old = File('${dir.path}/${item.imageVersion}.png');
          if (await FileSystemEntity.type(old.path, followLinks: false) ==
              FileSystemEntityType.file) {
            await old.delete();
          }
        }
        return next;
      });

  /// Archive project/captures with source deletion; rollback on storage failure.
  Future<void> deleteDocument(String path, Future<void> Function() delete) =>
      _locked(() async {
        final root = await _root();
        final moved = <String, String>{};
        try {
          await for (final entity in root.list(followLinks: false)) {
            final id = entity.uri.pathSegments.where((s) => s.isNotEmpty).last;
            if (entity is! Directory || !_idPattern.hasMatch(id)) continue;
            final project = await _read(id, checkSource: false);
            if (project.sourceImagePath != path) continue;
            final archive = '${root.path}/deleted-$id-${_token()}';
            await entity.rename(archive);
            moved[entity.path] = archive;
          }
          await delete();
        } catch (_) {
          for (final entry in moved.entries) {
            await Directory(entry.value).rename(entry.key);
          }
          rethrow;
        }
        final ids = moved.keys.map((p) => p.split('/').last).toSet();
        _codes.removeWhere((_, g) => ids.contains(g.projectId));
        _sessions.removeWhere((_, g) => ids.contains(g.projectId));
      });
}

final class _Grant {
  const _Grant(this.projectId, this.extensionId, this.expires);
  final String projectId;
  final String extensionId;
  final DateTime expires;
}

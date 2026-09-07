import 'dart:async';

import 'package:shopitem_curator/core/bloc/curator_bloc.dart';
import 'package:shopitem_curator/core/bloc/curator_event.dart';
import 'package:shopitem_curator/core/bloc/curator_state.dart';
import 'package:shopitem_curator/core/contracts/curator_use_cases.dart';
import 'package:shopitem_curator/core/contracts/source_document_repository.dart';
import 'package:shopitem_curator/core/models/curator_item.dart';
import 'package:shopitem_curator/core/repositories/item_repository.dart';
import 'package:test/test.dart';

void main() {
  late _Documents documents;
  late _Pipeline pipeline;
  late CuratorBloc bloc;
  setUp(() {
    documents = _Documents();
    pipeline = _Pipeline();
    bloc = CuratorBloc(
        itemRepository: const DefaultItemRepository(),
        pipelineService: pipeline,
        manifestRebuilder: pipeline,
        productReviewGateway: pipeline,
        catalogRescraper: pipeline,
        documentRepository: documents);
  });
  tearDown(() => bloc.close());

  Future<CuratorLoadedState> send(CuratorEvent event,
      [bool Function(CuratorLoadedState)? matches]) {
    final future = bloc.stateStream
        .where((state) =>
            state is CuratorLoadedState &&
            !state.documentOperationInProgress &&
            (matches == null || matches(state)))
        .cast<CuratorLoadedState>()
        .first
        .timeout(const Duration(seconds: 3));
    bloc.add(event);
    return future;
  }

  test('catalog replaces hardcoded defaults and selection uses server bytes',
      () async {
    documents.files['assets/images/custom.png'] = [1, 2, 3];
    final state = await send(const LoadSourceDocumentsEvent(selectFirst: true),
        (state) => state.selectedSourceImage.isNotEmpty);
    expect(state.availableSourceImages, ['assets/images/custom.png']);
    expect(state.selectedSourceImage, 'assets/images/custom.png');
    expect(state.sourceImageBytes, [1, 2, 3]);
    expect(pipeline.bytes.single, [1, 2, 3]);
  });

  test('imported source survives OCR failure and retry targets that source',
      () async {
    await send(const LoadSourceDocumentsEvent());
    pipeline.fail = true;
    final failed = await send(
        ImportSourceDocumentEvent('upload.png', [3, 2, 1]),
        (state) => state.documentErrorMessage != null);
    expect(failed.availableSourceImages, ['assets/images/upload.png']);
    expect(failed.selectedSourceImage, 'assets/images/upload.png');
    expect(failed.sourceImageBytes, [3, 2, 1]);
    pipeline.fail = false;
    final retried = await send(const RetrySourceDocumentEvent());
    expect(retried.documentErrorMessage, isNull);
    expect(pipeline.paths,
        ['assets/images/upload.png', 'assets/images/upload.png']);
    expect(retried.availableSourceImages, ['assets/images/upload.png']);
  });

  test(
      'deleting unselected preserves selection; deleting last clears preview and retry',
      () async {
    const a = 'assets/images/a.png';
    const b = 'assets/images/b.png';
    documents.files.addAll({
      a: [1],
      b: [2]
    });
    await send(const LoadSourceDocumentsEvent(selectFirst: true),
        (state) => state.selectedSourceImage == a);
    final otherDeleted = await send(const DeleteSourceDocumentEvent(b));
    expect(otherDeleted.selectedSourceImage, a);
    expect(otherDeleted.sourceImageBytes, [1]);
    final lastDeleted = await send(const DeleteSourceDocumentEvent(a));
    expect(lastDeleted.availableSourceImages, isEmpty);
    expect(lastDeleted.selectedSourceImage, isEmpty);
    expect(lastDeleted.sourceImageBytes, isNull);
    expect(lastDeleted.manifest.items, isEmpty);
    bloc.add(const RetrySourceDocumentEvent());
    bloc.add(const NextStepEvent());
    await Future<void>.delayed(Duration.zero);
    expect(pipeline.paths, [a]);
    expect((bloc.state as CuratorLoadedState).currentStep,
        CuratorStep.documentInput);
    final added = await send(ImportSourceDocumentEvent('again.png', [4]),
        (state) => state.selectedSourceImage == 'assets/images/again.png');
    expect(added.availableSourceImages, ['assets/images/again.png']);
  });

  test(
      'delete failure retains source/preview and duplicate mutations are ignored',
      () async {
    const path = 'assets/images/a.png';
    documents.files[path] = [7];
    await send(const LoadSourceDocumentsEvent(selectFirst: true),
        (state) => state.selectedSourceImage == path);
    documents.deleteGate = Completer<void>();
    final failed = send(const DeleteSourceDocumentEvent(path),
        (state) => state.documentErrorMessage != null);
    await Future<void>.delayed(Duration.zero);
    bloc.add(const DeleteSourceDocumentEvent(path));
    bloc.add(ImportSourceDocumentEvent('ignored.png', [2]));
    await Future<void>.delayed(Duration.zero);
    expect(documents.deleteCalls, 1);
    documents.deleteGate!.completeError(StateError('private filesystem path'));
    final state = await failed;
    expect(state.availableSourceImages, [path]);
    expect(state.sourceImageBytes, [7]);
    expect(state.documentErrorMessage, isNot(contains('private filesystem')));
    expect(documents.files.keys, [path]);
  });

  test('catalog refresh invalidates stale in-flight pipeline completion',
      () async {
    const path = 'assets/images/a.png';
    documents.files[path] = [7];
    await send(const LoadSourceDocumentsEvent());
    pipeline.pending = Completer<CuratorManifest>();
    bloc.add(const SelectSourceImageEvent(path));
    await Future<void>.delayed(Duration.zero);
    documents.files.clear();
    await send(const LoadSourceDocumentsEvent());
    pipeline.pending!.complete(_manifest(path));
    await Future<void>.delayed(Duration.zero);
    final state = bloc.state as CuratorLoadedState;
    expect(state.availableSourceImages, isEmpty);
    expect(state.selectedSourceImage, isEmpty);
  });
}

CuratorManifest _manifest(String path) => CuratorManifest(
    sourceImage: path, canvasWidth: 100, canvasHeight: 100, items: const []);

class _Documents implements SourceDocumentRepository {
  final files = <String, List<int>>{};
  Completer<void>? deleteGate;
  int deleteCalls = 0;
  @override
  Future<List<String>> listDocuments() async => files.keys.toList();
  @override
  Future<List<int>> readDocument(String path) async => files[path]!;
  @override
  Future<String> importDocument(String filename, List<int> bytes) async {
    final path = 'assets/images/$filename';
    files[path] = bytes;
    return path;
  }

  @override
  Future<void> deleteDocument(String path) async {
    deleteCalls++;
    await deleteGate?.future;
    files.remove(path);
  }
}

class _Pipeline
    implements
        CurationPipeline,
        ManifestRebuilder,
        ProductReviewGateway,
        CatalogRescraper {
  final paths = <String>[];
  final bytes = <List<int>?>[];
  bool fail = false;
  Completer<CuratorManifest>? pending;
  @override
  Future<CuratorManifest> runPipeline(
      {required String sourceImagePath,
      List<int>? imageBytes,
      PipelineProgressCallback? onProgress}) async {
    paths.add(sourceImagePath);
    bytes.add(imageBytes);
    if (fail) throw StateError('OCR failed');
    return pending?.future ?? _manifest(sourceImagePath);
  }

  @override
  Future<CuratorManifest> rebuildManifest(CuratorManifest manifest) async =>
      manifest;
  @override
  Future<List<TargetProductCandidate>> fetchLiveCandidates(
          CuratorItem item) async =>
      [];
  @override
  Future<TargetProductCandidate?> fetchProductByTargetUrl(String url) async =>
      null;
  @override
  Future<CatalogRescrapeResult> rescrapeAll(
          {required List<CuratorItem> items,
          CatalogRescrapeProgressCallback? onProgress}) async =>
      CatalogRescrapeResult(
          items: items, successfulItemCount: 0, failedItemCount: items.length);
}

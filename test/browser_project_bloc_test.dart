import 'dart:async';

import 'package:shopitem_curator/core/bloc/curator_bloc.dart';
import 'package:shopitem_curator/core/bloc/curator_event.dart';
import 'package:shopitem_curator/core/bloc/curator_state.dart';
import 'package:shopitem_curator/core/contracts/browser_project_gateway.dart';
import 'package:shopitem_curator/core/contracts/curator_use_cases.dart';
import 'package:shopitem_curator/core/models/browser_project.dart';
import 'package:shopitem_curator/core/models/curator_item.dart';
import 'package:shopitem_curator/core/repositories/item_repository.dart';
import 'package:test/test.dart';

void main() {
  late _Ports ports;
  late CuratorBloc bloc;
  setUp(() {
    ports = _Ports();
    bloc = CuratorBloc(
        itemRepository: const DefaultItemRepository(),
        pipelineService: ports,
        manifestRebuilder: ports,
        productReviewGateway: ports,
        catalogRescraper: ports,
        browserProjectGateway: ports,
        startInBrowserMode: true,
        browserPollInterval: Duration.zero);
  });
  tearDown(() => bloc.close());
  Future<CuratorLoadedState> send(CuratorEvent event,
      [bool Function(CuratorLoadedState)? matches]) {
    final future = bloc.stateStream
        .where(
            (s) => s is CuratorLoadedState && (matches == null || matches(s)))
        .cast<CuratorLoadedState>()
        .first
        .timeout(const Duration(seconds: 3));
    bloc.add(event);
    return future;
  }

  test(
      'browser workflow stops at checklist, blocks automatic catalog calls, then composes selections',
      () async {
    final loaded =
        await send(const SelectSourceImageEvent('assets/images/new.jpg'));
    expect(loaded.hasChecklist, isTrue);
    expect(loaded.allItems, isEmpty);
    expect(ports.automaticCalls, 0);
    final second = await send(const NextStepEvent());
    expect(second.currentStep, CuratorStep.scrappingConfirmation);
    bloc.add(const NextStepEvent());
    bloc.add(const RescrapeAllEvent());
    bloc.add(const FetchLiveCandidatesEvent('item_0'));
    bloc.add(
        const InspectTargetUrlEvent(itemId: 'item_0', targetUrl: 'unused'));
    await Future<void>.delayed(Duration.zero);
    expect(ports.automaticCalls, 0);
    expect((bloc.state as CuratorLoadedState).currentStep,
        CuratorStep.scrappingConfirmation);
    final paired = await send(
        const PairBrowserEvent(), (s) => s.browserPairingCode != null);
    expect(paired.browserPairingCode, 'test-code');
    ports.revision = 1;
    ports.selected = true;
    final refreshed = await send(
        const RefreshBrowserEvent(), (s) => s.browserProject?.revision == 1);
    expect(refreshed.browserProject!.selectedCount, 1);
    final applied = await send(const ApplyBrowserSelectionEvent(),
        (s) => !s.isRescraping && s.allItems.isNotEmpty);
    expect(applied.allItems.single.name, 'Notebook');
    expect(ports.rebuildCalls, 1);
    final canvas = await send(const NextStepEvent(), (s) => !s.isRescraping);
    expect(canvas.currentStep, CuratorStep.hoveringImage);
    ports.revision = 2;
    final changed = await send(
        const RefreshBrowserEvent(), (s) => s.browserProject?.revision == 2);
    expect(changed.allItems, isEmpty);
    expect(changed.currentStep, CuratorStep.scrappingConfirmation);
    expect(ports.automaticCalls, 0);
  });

  test('automatic mode remains explicitly selectable', () async {
    await send(const SelectSourceImageEvent('assets/images/new.jpg'));
    await send(const SetBrowserModeEvent(false));
    expect(bloc.browserMode, isFalse);
    expect(ports.automaticCalls, 1);
    await send(const SetBrowserModeEvent(true));
    expect(bloc.browserMode, isTrue);
    expect(ports.automaticCalls, 1);
  });

  test('late project open cannot overwrite another selected document',
      () async {
    ports.pendingOpen = Completer<BrowserProject>();
    bloc.add(const SelectSourceImageEvent('assets/images/new.jpg'));
    await Future<void>.delayed(Duration.zero);
    final pending = ports.pendingOpen!;
    ports.pendingOpen = null;
    await send(
        const SelectSourceImageEvent('assets/images/media_1787068853075.jpg'));
    pending.complete(ports.project('assets/images/new.jpg'));
    await Future<void>.delayed(Duration.zero);
    expect((bloc.state as CuratorLoadedState).selectedSourceImage,
        'assets/images/media_1787068853075.jpg');
  });

  test('selected products rebuild on document reselect without OCR/search',
      () async {
    ports.selected = true;
    ports.revision = 1;
    await send(const SelectSourceImageEvent('assets/images/new.jpg'),
        (s) => s.allItems.isNotEmpty);
    expect(ports.rebuildCalls, 1);
    expect(ports.automaticCalls, 0);
  });

  test(
      'canvas button fetches newly saved selection and composes without separate apply',
      () async {
    await send(const SelectSourceImageEvent('assets/images/new.jpg'));
    await send(const NextStepEvent());
    ports.selected = true;
    ports.revision = 1;
    final result = await send(const NextStepEvent(), (s) => !s.isRescraping);
    expect(result.currentStep, CuratorStep.hoveringImage);
    expect(result.allItems, hasLength(1));
    expect(ports.rebuildCalls, 1);
    expect(result.browserProject!.revision, 1);
    expect(ports.automaticCalls, 0);
  });

  test('stepper also applies selections and no selections produces feedback',
      () async {
    await send(const SelectSourceImageEvent('assets/images/new.jpg'));
    final empty = await send(const ChangeStepEvent(CuratorStep.hoveringImage),
        (s) => !s.isRescraping);
    expect(empty.browserMessage, contains('아직 담은 상품이 없습니다'));
    expect(empty.currentStep, CuratorStep.documentInput);
    ports.selected = true;
    ports.revision = 1;
    final ready = await send(const ChangeStepEvent(CuratorStep.hoveringImage),
        (s) => !s.isRescraping);
    expect(ready.currentStep, CuratorStep.hoveringImage);
  });

  test('old in-flight poll cannot clear a newly composed canvas', () async {
    await send(const SelectSourceImageEvent('assets/images/new.jpg'));
    await send(const NextStepEvent());
    final stale = ports.project();
    ports.pendingRefresh = Completer<BrowserProject>();
    final pending = ports.pendingRefresh!;
    bloc.add(const RefreshBrowserEvent());
    await Future<void>.delayed(Duration.zero);
    ports.pendingRefresh = null;
    ports.selected = true;
    ports.revision = 1;
    await send(const NextStepEvent(), (s) => !s.isRescraping);
    pending.complete(stale);
    await Future<void>.delayed(Duration.zero);
    final result = bloc.state as CuratorLoadedState;
    expect(result.currentStep, CuratorStep.hoveringImage);
    expect(result.browserProject!.revision, 1);
    expect(result.allItems, hasLength(1));
  });

  test(
      'failed composition is recoverable and duplicate clicks do not compose twice',
      () async {
    await send(const SelectSourceImageEvent('assets/images/new.jpg'));
    await send(const NextStepEvent());
    ports.selected = true;
    ports.revision = 1;
    ports.failRebuild = true;
    final failed = await send(const NextStepEvent(), (s) => !s.isRescraping);
    expect(failed.currentStep, CuratorStep.scrappingConfirmation);
    expect(failed.browserMessage, contains('캔버스를 만들지 못했습니다'));
    ports.failRebuild = false;
    final ready = send(const NextStepEvent(), (s) => !s.isRescraping);
    bloc.add(const NextStepEvent());
    expect((await ready).currentStep, CuratorStep.hoveringImage);
    expect(ports.rebuildCalls, 2); // One failed and one successful attempt.
  });
}

class _Ports
    implements
        BrowserProjectGateway,
        CurationPipeline,
        ManifestRebuilder,
        ProductReviewGateway,
        CatalogRescraper {
  int automaticCalls = 0, rebuildCalls = 0, revision = 0;
  bool selected = false;
  Completer<BrowserProject>? pendingOpen;
  Completer<BrowserProject>? pendingRefresh;
  bool failRebuild = false;
  BrowserProject project([String path = 'assets/images/new.jpg']) =>
      BrowserProject(
          id: path,
          sourceImagePath: path,
          revision: revision,
          entries: [
            BrowserProjectEntry(
                id: 'item_0',
                query: 'notebook',
                status: selected ? 'selected' : 'pending')
          ]);
  @override
  Future<BrowserProject> openBrowserProject(String sourceImagePath) async =>
      pendingOpen?.future ?? project(sourceImagePath);
  @override
  Future<BrowserProject> refreshBrowserProject(String projectId) async =>
      pendingRefresh?.future ?? project(projectId);
  @override
  Future<String> pairBrowserProject(String projectId) async => 'test-code';
  @override
  Future<CuratorManifest> readBrowserSelection(BrowserProject project) async =>
      CuratorManifest(
          sourceImage: project.sourceImagePath,
          canvasWidth: 400,
          canvasHeight: 400,
          items: [
            CuratorItem(
                id: 'item_0',
                name: 'Notebook',
                category: '',
                isPersonal: false,
                quantity: 1,
                price: 0,
                priceCurrency: 'USD',
                description: '',
                targetUrl: '',
                imageUrl: '',
                bounds:
                    const ItemLayoutBounds(x: 0, y: 0, width: 100, height: 100),
                polygon: const [],
                centroid: const CuratorPoint(50, 50))
          ]);
  @override
  Future<CuratorManifest> runPipeline(
      {required String sourceImagePath,
      List<int>? imageBytes,
      PipelineProgressCallback? onProgress}) async {
    automaticCalls++;
    return CuratorManifest(
        sourceImage: sourceImagePath,
        canvasWidth: 400,
        canvasHeight: 400,
        items: []);
  }

  @override
  Future<CuratorManifest> rebuildManifest(CuratorManifest manifest) async {
    rebuildCalls++;
    if (failRebuild) throw StateError('test failure');
    return manifest;
  }

  @override
  Future<List<TargetProductCandidate>> fetchLiveCandidates(
      CuratorItem item) async {
    automaticCalls++;
    return [];
  }

  @override
  Future<TargetProductCandidate?> fetchProductByTargetUrl(String url) async {
    automaticCalls++;
    return null;
  }

  @override
  Future<CatalogRescrapeResult> rescrapeAll(
      {required List<CuratorItem> items,
      CatalogRescrapeProgressCallback? onProgress}) async {
    automaticCalls++;
    return CatalogRescrapeResult(
        items: items, successfulItemCount: 0, failedItemCount: 0);
  }
}

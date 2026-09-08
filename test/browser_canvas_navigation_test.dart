import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shopitem_curator/core/bloc/curator_bloc.dart';
import 'package:shopitem_curator/core/bloc/curator_event.dart';
import 'package:shopitem_curator/core/bloc/curator_state.dart';
import 'package:shopitem_curator/core/contracts/browser_project_gateway.dart';
import 'package:shopitem_curator/core/contracts/curator_use_cases.dart';
import 'package:shopitem_curator/core/models/browser_project.dart';
import 'package:shopitem_curator/core/models/curator_item.dart';
import 'package:shopitem_curator/core/repositories/item_repository.dart';
import 'package:shopitem_curator/main.dart';

void main() {
  testWidgets(
      'browser selections open canvas in one click; download prevents duplicates and retries failures',
      (tester) async {
    tester.view.physicalSize = const Size(1024, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final ports = _Ports();
    final bloc = CuratorBloc(
        itemRepository: const DefaultItemRepository(),
        pipelineService: ports,
        manifestRebuilder: ports,
        productReviewGateway: ports,
        catalogRescraper: ports,
        browserProjectGateway: ports,
        startInBrowserMode: true,
        browserPollInterval: Duration.zero);
    final pending = Completer<bool>();
    var downloads = 0;
    bloc.add(const SelectSourceImageEvent('assets/images/new.jpg'));
    await tester.pumpWidget(ShopItemCuratorApp(
        curatorBloc: bloc,
        htmlFileSaver: ({required filename, required html}) async {
          downloads++;
          expect(filename, 'new-curator.html');
          expect(html, contains('data-item-id="chosen"'));
          if (downloads == 1) return pending.future;
          if (downloads == 2) throw StateError('simulated save failure');
          return true;
        }));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('목록 확인 및 상품 선택 ➔'));
    await tester.tap(find.text('목록 확인 및 상품 선택 ➔'));
    await tester.pumpAndSettle();
    ports.selected = true;
    // No Refresh or Apply is pressed. The visible list is still stale here.
    await tester.ensureVisible(find.byKey(const Key('open_canvas_button')));
    await tester.tap(find.byKey(const Key('open_canvas_button')));
    await tester.pumpAndSettle();
    expect((bloc.state as CuratorLoadedState).currentStep,
        CuratorStep.hoveringImage);
    expect(find.byKey(const ValueKey('curator_canvas_item_chosen')),
        findsOneWidget);
    final download = find.byKey(const Key('html_export_button'));
    await tester.ensureVisible(download);
    await tester.tap(download);
    await tester.pump();
    expect(downloads, 1);
    expect(tester.widget<ElevatedButton>(download).onPressed, isNull);
    pending.complete(false);
    await tester.pumpAndSettle();
    expect(find.text('HTML 저장을 취소했습니다.'), findsOneWidget);
    await tester.tap(download);
    await tester.pumpAndSettle();
    expect(find.textContaining('HTML 파일을 저장하지 못했습니다'), findsOneWidget);
    expect(tester.widget<ElevatedButton>(download).onPressed, isNotNull);
    await tester.tap(download);
    await tester.pumpAndSettle();
    expect(downloads, 3);
    expect(find.byType(Dialog), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

class _Ports extends Fake
    implements
        BrowserProjectGateway,
        CurationPipeline,
        ManifestRebuilder,
        ProductReviewGateway,
        CatalogRescraper {
  bool selected = false;
  BrowserProject project() => BrowserProject(
          id: 'p',
          sourceImagePath: 'assets/images/new.jpg',
          revision: selected ? 1 : 0,
          entries: [
            BrowserProjectEntry(
                id: 'chosen',
                query: 'Notebook',
                status: selected ? 'selected' : 'pending')
          ]);
  @override
  Future<BrowserProject> openBrowserProject(String path) async => project();
  @override
  Future<BrowserProject> refreshBrowserProject(String id) async => project();
  @override
  Future<CuratorManifest> readBrowserSelection(BrowserProject project) async =>
      CuratorManifest(
          sourceImage: project.sourceImagePath,
          canvasWidth: 400,
          canvasHeight: 400,
          items: [
            CuratorItem(
                id: 'chosen',
                name: 'Notebook',
                category: 'Other',
                isPersonal: false,
                quantity: 1,
                price: 0,
                priceCurrency: 'USD',
                description: '',
                targetUrl: '',
                imageUrl: '',
                bounds: const ItemLayoutBounds(
                    x: 30, y: 30, width: 100, height: 80),
                polygon: const [
                  CuratorPoint(30, 30),
                  CuratorPoint(130, 30),
                  CuratorPoint(130, 110),
                  CuratorPoint(30, 110)
                ],
                centroid: const CuratorPoint(80, 70))
          ]);
  @override
  Future<CuratorManifest> rebuildManifest(CuratorManifest manifest) async =>
      manifest;
}

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shopitem_curator/core/bloc/curator_bloc.dart';
import 'package:shopitem_curator/core/bloc/curator_state.dart';
import 'package:shopitem_curator/core/composition/default_curator_bloc.dart';
import 'package:shopitem_curator/core/models/curator_item.dart';
import 'package:shopitem_curator/core/models/target_purchase_url.dart';
import 'package:shopitem_curator/ui/widgets/review_modal.dart';

void main() {
  late CuratorBloc bloc;

  setUp(() {
    bloc = createDefaultCuratorBloc();
  });

  tearDown(() {
    bloc.dispose();
  });

  testWidgets('enables only validated Target PDP purchase buttons',
      (tester) async {
    final item = _item(
      targetUrl: 'https://www.target.com/p/current-item/-/A-12345',
    );
    final validCandidate = _candidate(
      id: 'valid',
      targetUrl: 'https://target.com/p/valid-item/-/A-67890?preselect=1',
    );
    final searchCandidate = _candidate(
      id: 'search',
      targetUrl: 'https://www.target.com/s?searchTerm=backpack',
    );
    final launches = <TargetPurchaseUrl>[];

    await _pumpModal(
      tester,
      bloc: bloc,
      item: item,
      state: _state(
        item,
        candidates: [validCandidate, searchCandidate],
        reviewStatus: ReviewStatus.success,
      ),
      onLaunch: (url) async => launches.add(url),
    );

    final currentButton = tester.widget<ElevatedButton>(
      find.byKey(const Key('review_current_purchase_button')),
    );
    final validButton = tester.widget<TextButton>(
      find.byKey(const ValueKey('candidate_purchase_valid')),
    );
    final searchButton = tester.widget<TextButton>(
      find.byKey(const ValueKey('candidate_purchase_search')),
    );

    expect(currentButton.onPressed, isNotNull);
    expect(validButton.onPressed, isNotNull);
    expect(searchButton.onPressed, isNull);

    currentButton.onPressed!();
    validButton.onPressed!();
    await tester.pump();

    expect(launches, hasLength(2));
    expect(launches.every((url) => url.uri.path.contains('/p/')), isTrue);
  });

  testWidgets('disables the current purchase button for a Target search URL',
      (tester) async {
    final item = _item(
      targetUrl: 'https://www.target.com/s?searchTerm=school+supplies',
    );

    await _pumpModal(
      tester,
      bloc: bloc,
      item: item,
      state: _state(item, reviewStatus: ReviewStatus.empty),
      onLaunch: (_) async {},
    );

    final button = tester.widget<ElevatedButton>(
      find.byKey(const Key('review_current_purchase_button')),
    );
    expect(button.onPressed, isNull);
    expect(find.text('직링크 없음'), findsOneWidget);
  });

  testWidgets('renders BLoC-owned loading and failure states', (tester) async {
    final item = _item(
      targetUrl: 'https://www.target.com/p/current-item/-/A-12345',
    );

    await _pumpModal(
      tester,
      bloc: bloc,
      item: item,
      state: _state(
        item,
        reviewStatus: ReviewStatus.loading,
        urlInspectionStatus: UrlInspectionStatus.loading,
      ),
      onLaunch: (_) async {},
    );

    expect(find.byKey(const Key('review_candidates_loading')), findsOneWidget);
    expect(find.byKey(const Key('url_inspection_loading')), findsOneWidget);
    final inspectButton = tester.widget<ElevatedButton>(
      find.byKey(const Key('inspect_target_url_button')),
    );
    expect(inspectButton.onPressed, isNull);

    await _pumpModal(
      tester,
      bloc: bloc,
      item: item,
      state: _state(
        item,
        reviewStatus: ReviewStatus.failure,
        reviewErrorMessage: '후보 검색 실패',
        urlInspectionStatus: UrlInspectionStatus.failure,
        urlInspectionErrorMessage: 'URL 검사 실패',
      ),
      onLaunch: (_) async {},
    );

    expect(find.byKey(const Key('review_candidates_failure')), findsOneWidget);
    expect(find.text('후보 검색 실패'), findsOneWidget);
    expect(find.byKey(const Key('url_inspection_failure')), findsOneWidget);
    expect(find.text('URL 검사 실패'), findsOneWidget);
  });

  testWidgets('provides a modal barrier and an Escape close shortcut',
      (tester) async {
    final item = _item(
      targetUrl: 'https://www.target.com/p/current-item/-/A-12345',
    );

    await _pumpModal(
      tester,
      bloc: bloc,
      item: item,
      state: _state(item),
      onLaunch: (_) async {},
      size: const Size(320, 600),
    );

    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is ModalBarrier && widget.semanticsLabel == '상품 재검토 창 닫기',
      ),
      findsOneWidget,
    );
    final shortcuts = tester.widget<CallbackShortcuts>(
      find.byType(CallbackShortcuts),
    );
    expect(
      shortcuts.bindings.keys.whereType<SingleActivator>().any(
            (activator) => activator.trigger == LogicalKeyboardKey.escape,
          ),
      isTrue,
    );
    expect(tester.takeException(), isNull);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}

Future<void> _pumpModal(
  WidgetTester tester, {
  required CuratorBloc bloc,
  required CuratorItem item,
  required CuratorLoadedState state,
  required TargetPurchaseUrlLauncher onLaunch,
  Size size = const Size(1000, 900),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: ReviewModal(
          bloc: bloc,
          state: state,
          item: item,
          onLaunchPurchaseUrl: onLaunch,
        ),
      ),
    ),
  );
}

CuratorLoadedState _state(
  CuratorItem item, {
  List<TargetProductCandidate> candidates = const [],
  ReviewStatus reviewStatus = ReviewStatus.idle,
  String? reviewErrorMessage,
  UrlInspectionStatus urlInspectionStatus = UrlInspectionStatus.idle,
  String? urlInspectionErrorMessage,
}) {
  return CuratorLoadedState(
    manifest: CuratorManifest(
      canvasWidth: 1200,
      canvasHeight: 820,
      items: [item],
    ),
    reviewingItemId: item.id,
    detectedCandidates: candidates,
    reviewStatus: reviewStatus,
    reviewErrorMessage: reviewErrorMessage,
    urlInspectionStatus: urlInspectionStatus,
    urlInspectionErrorMessage: urlInspectionErrorMessage,
  );
}

CuratorItem _item({required String targetUrl}) {
  return CuratorItem(
    id: 'item_1',
    name: 'Backpack',
    category: 'Personal',
    isPersonal: true,
    quantity: 1,
    price: 10,
    priceCurrency: 'USD',
    description: 'Test item',
    targetUrl: targetUrl,
    imageUrl: '',
    bounds: const ItemLayoutBounds(x: 0, y: 0, width: 100, height: 100),
    polygon: const [],
    centroid: const CuratorPoint(50, 50),
  );
}

TargetProductCandidate _candidate({
  required String id,
  required String targetUrl,
}) {
  return TargetProductCandidate(
    id: id,
    name: 'Candidate $id',
    price: 11,
    imageUrl: '',
    targetUrl: targetUrl,
    description: 'Candidate description',
  );
}

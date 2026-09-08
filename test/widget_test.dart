import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shopitem_curator/core/bloc/curator_event.dart';
import 'package:shopitem_curator/core/bloc/curator_state.dart';
import 'package:shopitem_curator/core/composition/default_curator_bloc.dart';
import 'package:shopitem_curator/core/contracts/user_visible_failure.dart';
import 'package:shopitem_curator/main.dart';

void main() {
  testWidgets('shows recoverable backend waiting status', (tester) async {
    final bloc = createDefaultCuratorBloc();
    bloc.add(const InitializationWaitingEvent(
      SimpleUserVisibleFailure('서버 준비 확인 중'),
    ));

    await tester.pumpWidget(ShopItemCuratorApp(curatorBloc: bloc));
    await tester.pump();

    expect(find.textContaining('백엔드 시작을 기다리는 중'), findsOneWidget);
    expect(find.textContaining('서버 준비 확인 중'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('startup retry rechecks readiness instead of posting an image',
      (tester) async {
    final bloc = createDefaultCuratorBloc();
    var retryCalls = 0;
    bloc.add(const InitializationFailedEvent(
      SimpleUserVisibleFailure('호환되지 않는 백엔드입니다.'),
    ));

    await tester.pumpWidget(ShopItemCuratorApp(
      curatorBloc: bloc,
      onRetryInitialization: () => retryCalls++,
    ));
    await tester.pump();

    expect(bloc.state, isA<CuratorInitializationErrorState>());
    await tester.tap(
      find.byKey(const ValueKey('initialization_retry_button')),
    );
    await tester.pump();

    expect(retryCalls, 1);
    expect(bloc.state, isA<CuratorInitializationErrorState>());
    expect(find.text('백엔드 다시 확인'), findsOneWidget);
  });

  testWidgets(
      'ShopItemCuratorApp navigates through 3 steps and supports OK and Review workflow',
      (tester) async {
    tester.view.physicalSize = const Size(1280, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final bloc = createDefaultCuratorBloc();
    bloc.add(const SelectSourceImageEvent('assets/images/new.jpg'));

    String? downloadedHtml;
    String? downloadedFilename;
    await tester.pumpWidget(ShopItemCuratorApp(
        curatorBloc: bloc,
        htmlFileSaver: ({required filename, required html}) async {
          downloadedFilename = filename;
          downloadedHtml = html;
          return true;
        }));
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();

    // Step 1: Document Input
    expect(find.text('1. 문서 입력 (Document Input)'), findsOneWidget);
    expect(find.text('목록 확인 및 상품 선택 ➔'), findsOneWidget);

    // Tap Next -> Step 2
    await tester.tap(find.text('목록 확인 및 상품 선택 ➔'));
    await tester.pumpAndSettle();

    expect(find.text('2. 상품 선택 및 확인'), findsOneWidget);
    // Verify text replacement: '◀ 문서 다시 선택'
    expect(find.text('◀ 문서 다시 선택'), findsOneWidget);
    // Verify OK buttons exist
    expect(find.text('OK (승인됨)'), findsWidgets);
    // Verify 재검토 buttons exist
    expect(find.text('재검토 ↺'), findsWidgets);

    // Excluded products must not leak into the interactive canvas/export layer.
    await tester.tap(find.byType(Checkbox).first);
    await tester.pumpAndSettle();

    // Ensure visible and Tap Next -> Step 3
    await tester.ensureVisible(find.text('캔버스 시각화 및 인터랙션 ➔'));
    await tester.tap(find.text('캔버스 시각화 및 인터랙션 ➔'));
    await tester.pumpAndSettle();

    expect(find.text('3. 캔버스 시각화 (Hovering Image)'), findsOneWidget);
    expect(find.text('◀ 상품 선택으로 돌아가기'), findsOneWidget);
    expect(find.text('HTML 다운로드'), findsOneWidget);
    expect(
        find.byKey(const ValueKey('curator_canvas_item_item_1')), findsNothing);
    expect(find.byKey(const ValueKey('curator_canvas_item_item_2')),
        findsOneWidget);

    // One click delivers a file, not a code/clipboard dialog.
    await tester.ensureVisible(find.text('HTML 다운로드'));
    await tester.tap(find.text('HTML 다운로드'));
    await tester.pumpAndSettle();
    expect(downloadedFilename, 'new-curator.html');
    expect(downloadedHtml, contains('<!DOCTYPE html>'));
    expect(downloadedHtml, isNot(contains('data-item-id="item_1"')));
    expect(downloadedHtml, contains('data-item-id="item_2"'));
    expect(find.byType(Dialog), findsNothing);

    // Tap Previous -> Step 2
    await tester.ensureVisible(find.text('◀ 상품 선택으로 돌아가기'));
    await tester.tap(find.text('◀ 상품 선택으로 돌아가기'));
    await tester.pumpAndSettle();

    expect(find.text('2. 상품 선택 및 확인'), findsOneWidget);
  });

  testWidgets('stays responsive at 320px and gates unavailable proxy actions',
      (tester) async {
    tester.view.physicalSize = const Size(320, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final bloc = createDefaultCuratorBloc();
    bloc.add(const SelectSourceImageEvent('assets/images/new.jpg'));

    await tester.pumpWidget(
      ShopItemCuratorApp(
        curatorBloc: bloc,
        catalogProxyEnabled: false,
        htmlFileSaver: ({required filename, required html}) async => false,
      ),
    );
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    await tester.ensureVisible(find.text('목록 확인 및 상품 선택 ➔'));
    await tester.tap(find.text('목록 확인 및 상품 선택 ➔'));
    await tester.pumpAndSettle();

    expect(find.textContaining('백엔드 상품 조회 기능'), findsOneWidget);
    final rescrapeButton = tester.widget<OutlinedButton>(
      find.widgetWithText(OutlinedButton, '재스크래핑'),
    );
    expect(rescrapeButton.onPressed, isNull);
    expect(tester.takeException(), isNull);

    await tester.ensureVisible(find.text('캔버스 시각화 및 인터랙션 ➔'));
    await tester.tap(find.text('캔버스 시각화 및 인터랙션 ➔'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    await tester.ensureVisible(find.byKey(const Key('html_export_button')));
    await tester.tap(find.byKey(const Key('html_export_button')));
    await tester.pumpAndSettle();
    expect(find.text('HTML 저장을 취소했습니다.'), findsOneWidget);
    expect(find.byType(Dialog), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

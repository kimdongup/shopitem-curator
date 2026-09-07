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

    await tester.pumpWidget(ShopItemCuratorApp(curatorBloc: bloc));
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();

    // Step 1: Document Input
    expect(find.text('1. 문서 입력 (Document Input)'), findsOneWidget);
    expect(find.text('목록화 및 스크래핑 확인 ➔'), findsOneWidget);

    // Tap Next -> Step 2
    await tester.tap(find.text('목록화 및 스크래핑 확인 ➔'));
    await tester.pumpAndSettle();

    expect(find.text('2. 스크래핑 확인 (Scrapping Confirmation)'), findsOneWidget);
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
    expect(find.text('◀ 스크래핑 확인으로 돌아가기'), findsOneWidget);
    expect(find.text('HTML 이미지맵 출력 (Export) 🌐'), findsOneWidget);
    expect(
        find.byKey(const ValueKey('curator_canvas_item_item_1')), findsNothing);
    expect(find.byKey(const ValueKey('curator_canvas_item_item_2')),
        findsOneWidget);

    // Tap HTML Export button and verify dialog
    await tester.ensureVisible(find.text('HTML 이미지맵 출력 (Export) 🌐'));
    await tester.tap(find.text('HTML 이미지맵 출력 (Export) 🌐'));
    await tester.pumpAndSettle();
    expect(find.text('인터랙티브 HTML 이미지맵 코드 출력'), findsOneWidget);
    expect(find.text('HTML 전체 복사'), findsOneWidget);

    // Close modal
    await tester.tap(find.text('닫기'));
    await tester.pumpAndSettle();

    // Tap Previous -> Step 2
    await tester.ensureVisible(find.text('◀ 스크래핑 확인으로 돌아가기'));
    await tester.tap(find.text('◀ 스크래핑 확인으로 돌아가기'));
    await tester.pumpAndSettle();

    expect(find.text('2. 스크래핑 확인 (Scrapping Confirmation)'), findsOneWidget);
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
      ),
    );
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    await tester.ensureVisible(find.text('목록화 및 스크래핑 확인 ➔'));
    await tester.tap(find.text('목록화 및 스크래핑 확인 ➔'));
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
    expect(find.text('인터랙티브 HTML 이미지맵 코드 출력'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

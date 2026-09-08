import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shopitem_curator/core/bloc/curator_state.dart';
import 'package:shopitem_curator/core/models/browser_project.dart';
import 'package:shopitem_curator/core/models/curator_item.dart';
import 'package:shopitem_curator/ui/widgets/browser_project_panel.dart';

void main() {
  testWidgets(
      'browser pairing panel fits narrow screens and disables empty apply',
      (tester) async {
    tester.view.physicalSize = const Size(320, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    var pairCalls = 0;
    final state = CuratorLoadedState(
        manifest:
            CuratorManifest(canvasWidth: 400, canvasHeight: 400, items: []),
        browserPairingCode: '01234567890123456789012345678901',
        browserProject: BrowserProject(
            id: 'p',
            sourceImagePath: 'list.png',
            revision: 0,
            entries: const [
              BrowserProjectEntry(id: 'item_0', query: 'big notebook')
            ]));
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SingleChildScrollView(
                child: BrowserProjectPanel(
                    state: state,
                    onPair: () => pairCalls++,
                    onRefresh: () {},
                    onApply: () {})))));
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('확장 프로그램 연결 코드'));
    expect(pairCalls, 1);
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull);
    expect(find.textContaining('big notebook'), findsOneWidget);
  });
}

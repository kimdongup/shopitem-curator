import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shopitem_curator/ui/adapters/source_document_picker.dart';
import 'package:shopitem_curator/ui/widgets/source_document_menu.dart';

void main() {
  testWidgets(
      'dropdown imports a picked document and handles picker cancellation',
      (tester) async {
    final imported = <PickedSourceDocument>[];
    PickedSourceDocument? selection =
        const PickedSourceDocument('new.png', [1, 2, 3]);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SourceDocumentMenu(
      documents: const [],
      selected: '',
      onSelect: (_) {},
      onDelete: (_) {},
      onRefresh: () {},
      onImport: imported.add,
      pickDocument: () async => selection,
    ))));
    await tester.tap(find.byKey(const Key('source_document_dropdown')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('새 문서 추가…').last);
    await tester.pumpAndSettle();
    expect(imported.single.filename, 'new.png');
    selection = null;
    await tester.tap(find.byKey(const Key('source_document_dropdown')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('새 문서 추가…').last);
    await tester.pumpAndSettle();
    expect(imported, hasLength(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'each document has delete, cancellation is safe and never selects it',
      (tester) async {
    const a = 'assets/images/a.png';
    const b = 'assets/images/b.png';
    final deleted = <String>[];
    final selected = <String>[];
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SourceDocumentMenu(
      documents: const [a, b],
      selected: a,
      onSelect: selected.add,
      onImport: (_) {},
      onDelete: deleted.add,
      onRefresh: () {},
    ))));
    Future<void> openDelete() async {
      await tester.tap(find.byKey(const Key('source_document_dropdown')));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.delete_outline), findsNWidgets(2));
      await tester.tap(find.byKey(const ValueKey('delete_document_$b')));
      await tester.pumpAndSettle();
      expect(find.text('문서와 에셋 삭제'), findsOneWidget);
    }

    await openDelete();
    await tester.tap(find.text('취소'));
    await tester.pumpAndSettle();
    expect(deleted, isEmpty);
    expect(selected, isEmpty);
    await openDelete();
    await tester.tap(find.byKey(const Key('confirm_document_delete')));
    await tester.pumpAndSettle();
    expect(deleted, [b]);
    expect(selected, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'menu remains usable at 320px with long filenames and empty catalog',
      (tester) async {
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    const path = 'assets/images/아주 긴 이름의 새로운 준비물 목록 문서 사진.png';
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SourceDocumentMenu(
      documents: const [path],
      selected: path,
      onSelect: (_) {},
      onImport: (_) {},
      onDelete: (_) {},
      onRefresh: () {},
    ))));
    await tester.tap(find.byKey(const Key('source_document_dropdown')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}

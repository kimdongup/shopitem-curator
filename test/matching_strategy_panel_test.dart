import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shopitem_curator/core/bloc/curator_bloc.dart';
import 'package:shopitem_curator/core/bloc/curator_state.dart';
import 'package:shopitem_curator/core/contracts/curator_use_cases.dart';
import 'package:shopitem_curator/core/models/curator_item.dart';
import 'package:shopitem_curator/core/models/matching_options.dart';
import 'package:shopitem_curator/core/repositories/item_repository.dart';
import 'package:shopitem_curator/ui/widgets/matching_strategy_panel.dart';

void main() {
  testWidgets(
      'strategy panel fits 320px and disables unavailable strategies and empty run',
      (tester) async {
    tester.view.physicalSize = const Size(320, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final ports = _Ports();
    final bloc = CuratorBloc(
        itemRepository: const DefaultItemRepository(),
        pipelineService: ports,
        manifestRebuilder: ports,
        productReviewGateway: ports,
        catalogRescraper: ports);
    addTearDown(bloc.close);
    final state = CuratorLoadedState(
        manifest:
            CuratorManifest(canvasWidth: 400, canvasHeight: 400, items: []),
        selectedSourceImage: '',
        matchingCapabilities: const [
          MatchingCapability(
              strategy: MatchingStrategy.randomDelay, available: true)
        ]);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SingleChildScrollView(
                child: MatchingStrategyPanel(bloc: bloc, state: state)))));
    expect(tester.takeException(), isNull);
    final tiles = tester
        .widgetList<CheckboxListTile>(find.byType(CheckboxListTile))
        .toList();
    expect(tiles.length, 6);
    expect(tiles[1].onChanged, isNull);
    expect(tiles[2].onChanged, isNotNull);
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull);
  });
}

class _Ports extends Fake
    implements
        CurationPipeline,
        ManifestRebuilder,
        ProductReviewGateway,
        CatalogRescraper {}

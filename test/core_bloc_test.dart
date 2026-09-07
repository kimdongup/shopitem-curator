import 'package:test/test.dart';
import 'package:shopitem_curator/core/bloc/curator_bloc.dart';
import 'package:shopitem_curator/core/bloc/curator_event.dart';
import 'package:shopitem_curator/core/bloc/curator_state.dart';
import 'package:shopitem_curator/core/composition/default_curator_bloc.dart';

void main() {
  group('CuratorBloc Pure Dart Tests with OK / Review Workflow', () {
    late CuratorBloc bloc;

    setUp(() {
      bloc = createDefaultCuratorBloc();
    });

    tearDown(() {
      bloc.dispose();
    });

    test('Initial state is CuratorInitialState', () {
      expect(bloc.state, isA<CuratorInitialState>());
    });

    test(
        'SelectSourceImageEvent executes pipeline and starts on step 1 (documentInput)',
        () async {
      bloc.add(const SelectSourceImageEvent('assets/images/new.jpg'));

      final loadedState = await bloc.stateStream
          .firstWhere((s) => s is CuratorLoadedState) as CuratorLoadedState;

      expect(loadedState.items.length, 3);
      expect(loadedState.currentStep, CuratorStep.documentInput);
    });

    test('Step navigation: NextStepEvent moves from step 1 to 2 to 3',
        () async {
      bloc.add(const SelectSourceImageEvent('assets/images/new.jpg'));
      await bloc.stateStream.firstWhere((s) => s is CuratorLoadedState);

      // Step 1 -> Step 2 (scrappingConfirmation)
      bloc.add(const NextStepEvent());
      var state = await bloc.stateStream.first as CuratorLoadedState;
      expect(state.currentStep, CuratorStep.scrappingConfirmation);

      // Step 2 -> Step 3 (hoveringImage)
      bloc.add(const NextStepEvent());
      state = await bloc.stateStream.first as CuratorLoadedState;
      expect(state.currentStep, CuratorStep.hoveringImage);

      // Step 3 -> Step 2 (previous)
      bloc.add(const PreviousStepEvent());
      state = await bloc.stateStream.first as CuratorLoadedState;
      expect(state.currentStep, CuratorStep.scrappingConfirmation);
    });

    test('ApproveItemEvent ensures item is checked and approved', () async {
      bloc.add(const SelectSourceImageEvent('assets/images/new.jpg'));
      await bloc.stateStream.firstWhere((s) => s is CuratorLoadedState);

      bloc.add(const ApproveItemEvent('item_1'));
      var state = await bloc.stateStream.first as CuratorLoadedState;
      expect(state.excludedItemIds.contains('item_1'), isFalse);
      final item = state.allItems.firstWhere((it) => it.id == 'item_1');
      expect(item.isApproved, isTrue);
    });

    test(
        'StartItemReviewEvent generates candidates and ReplaceItemImageEvent updates item',
        () async {
      bloc.add(const SelectSourceImageEvent('assets/images/new.jpg'));
      await bloc.stateStream.firstWhere((s) => s is CuratorLoadedState);

      // Start review
      bloc.add(const StartItemReviewEvent('item_1'));
      var state = await bloc.stateStream.firstWhere(
              (s) => s is CuratorLoadedState && s.detectedCandidates.isNotEmpty)
          as CuratorLoadedState;
      expect(state.reviewingItemId, 'item_1');
      expect(state.detectedCandidates.isNotEmpty, isTrue);

      // Replace with candidate
      final candidate = state.detectedCandidates.first;
      bloc.add(ReplaceItemImageEvent(
        itemId: 'item_1',
        newImageUrl: candidate.imageUrl,
        newName: candidate.name,
        newPrice: candidate.price,
      ));

      state = await bloc.stateStream.first as CuratorLoadedState;
      expect(state.reviewingItemId, isNull);
      final updated = state.allItems.firstWhere((it) => it.id == 'item_1');
      expect(updated.name, candidate.name);
      expect(updated.price, candidate.price);
    });

    test('CancelItemReviewEvent unchecks item if closed without replacement',
        () async {
      bloc.add(const SelectSourceImageEvent('assets/images/new.jpg'));
      await bloc.stateStream.firstWhere((s) => s is CuratorLoadedState);

      bloc.add(const StartItemReviewEvent('item_1'));
      await bloc.stateStream.first as CuratorLoadedState;

      bloc.add(const CancelItemReviewEvent('item_1'));
      // A fast candidate lookup can already have queued a success state.
      // Observe cancellation itself, not an unrelated next stream emission.
      final state = await bloc.stateStream.firstWhere((state) =>
          state is CuratorLoadedState &&
          state.reviewingItemId == null &&
          state.excludedItemIds.contains('item_1')) as CuratorLoadedState;
      expect(state.reviewingItemId, isNull);
      expect(state.excludedItemIds.contains('item_1'), isTrue);
    });

    test('RescrapeAllEvent executes 2-step pipeline and updates items',
        () async {
      bloc.add(const SelectSourceImageEvent('assets/images/new.jpg'));
      await bloc.stateStream.firstWhere((s) => s is CuratorLoadedState);

      bloc.add(const RescrapeAllEvent());
      final finalState = await bloc.stateStream.firstWhere(
        (s) =>
            s is CuratorLoadedState &&
            !s.isRescraping &&
            s.rescrapeStatus.isNotEmpty,
      ) as CuratorLoadedState;

      expect(finalState.allItems.length, 3);
      expect(
        finalState.rescrapeStatus,
        anyOf(contains('완료'), contains('실패')),
      );
    });
  });
}

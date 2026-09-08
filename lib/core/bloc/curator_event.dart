// Pure Dart BLoC Events (Zero Flutter Dependencies)
import '../models/matching_options.dart';
import 'dart:typed_data';
import '../contracts/user_visible_failure.dart';
import 'curator_state.dart';

final class SetMatchingStrategyEvent extends CuratorEvent {
  const SetMatchingStrategyEvent(this.strategy, this.enabled);
  final MatchingStrategy strategy;
  final bool enabled;
}

final class RefreshMatchingCapabilitiesEvent extends CuratorEvent {
  const RefreshMatchingCapabilitiesEvent();
}

final class RunMatchingEvent extends CuratorEvent {
  const RunMatchingEvent();
}

sealed class CuratorEvent {
  const CuratorEvent();
}

final class SetBrowserModeEvent extends CuratorEvent {
  const SetBrowserModeEvent(this.enabled);
  final bool enabled;
}

final class PairBrowserEvent extends CuratorEvent {
  const PairBrowserEvent();
}

final class RefreshBrowserEvent extends CuratorEvent {
  const RefreshBrowserEvent();
}

final class ApplyBrowserSelectionEvent extends CuratorEvent {
  const ApplyBrowserSelectionEvent();
}

final class LoadSourceDocumentsEvent extends CuratorEvent {
  const LoadSourceDocumentsEvent({this.selectFirst = false});
  final bool selectFirst;
}

final class ImportSourceDocumentEvent extends CuratorEvent {
  ImportSourceDocumentEvent(this.filename, List<int> bytes)
      : bytes = Uint8List.fromList(bytes).asUnmodifiableView();
  final String filename;
  final List<int> bytes;
}

final class DeleteSourceDocumentEvent extends CuratorEvent {
  const DeleteSourceDocumentEvent(this.sourceImagePath);
  final String sourceImagePath;
}

final class RetrySourceDocumentEvent extends CuratorEvent {
  const RetrySourceDocumentEvent();
}

/// Dispatched when the user selects an input image file from assets/images.
final class SelectSourceImageEvent extends CuratorEvent {
  const SelectSourceImageEvent(this.sourceImagePath, {this.imageBytes});
  final String sourceImagePath;
  final List<int>? imageBytes;
}

/// Reports a startup failure that has already been sanitized for presentation.
final class InitializationFailedEvent extends CuratorEvent {
  const InitializationFailedEvent(this.failure);

  final UserVisibleFailure failure;
}

/// Reports a recoverable startup condition while the client keeps polling the
/// safe backend readiness endpoint.
final class InitializationWaitingEvent extends CuratorEvent {
  const InitializationWaitingEvent(this.failure);

  final UserVisibleFailure failure;
}

/// Moves a terminal startup failure back behind the readiness gate.
final class InitializationRetryStartedEvent extends CuratorEvent {
  const InitializationRetryStartedEvent();
}

/// Dispatched to change the active workflow step directly.
final class ChangeStepEvent extends CuratorEvent {
  const ChangeStepEvent(this.targetStep);
  final CuratorStep targetStep;
}

/// Dispatched to navigate to the next step.
final class NextStepEvent extends CuratorEvent {
  const NextStepEvent();
}

/// Dispatched to navigate to the previous step.
final class PreviousStepEvent extends CuratorEvent {
  const PreviousStepEvent();
}

/// Dispatched when the user toggles an item's inclusion during the scrapping confirmation step.
final class ToggleItemInclusionEvent extends CuratorEvent {
  const ToggleItemInclusionEvent(this.itemId);
  final String itemId;
}

/// Dispatched when the user approves an item with the OK button.
final class ApproveItemEvent extends CuratorEvent {
  const ApproveItemEvent(this.itemId);
  final String itemId;
}

/// Dispatched when the user clicks '재검토' to inspect alternative Target candidate images.
final class StartItemReviewEvent extends CuratorEvent {
  const StartItemReviewEvent(this.itemId);
  final String itemId;
}

/// Dispatched when the user confirms replacing the item with a detected candidate.
final class ReplaceItemImageEvent extends CuratorEvent {
  const ReplaceItemImageEvent({
    required this.itemId,
    required this.newImageUrl,
    this.newName,
    this.newPrice,
    this.newTargetUrl,
  });

  final String itemId;
  final String newImageUrl;
  final String? newName;
  final double? newPrice;
  final String? newTargetUrl;
}

/// Dispatched when the user cancels or closes the review dialog.
final class CancelItemReviewEvent extends CuratorEvent {
  const CancelItemReviewEvent(this.itemId);
  final String itemId;
}

/// Dispatched when directly loading manifest content.
final class LoadCuratorItemsEvent extends CuratorEvent {
  const LoadCuratorItemsEvent(this.jsonManifestContent);
  final String jsonManifestContent;
}

/// Dispatched when the user hovers the cursor over a specific item or leaves it.
final class HoverItemEvent extends CuratorEvent {
  const HoverItemEvent(this.itemId);
  final String? itemId;
}

/// Dispatched when the user clicks or taps on a specific item to open the price tag balloon.
final class SelectItemEvent extends CuratorEvent {
  const SelectItemEvent(this.itemId);
  final String? itemId;
}

/// Dispatched when the user dismisses the currently active price tag balloon.
final class DismissItemEvent extends CuratorEvent {
  const DismissItemEvent();
}

/// Dispatched when the user clicks '재스크래핑' to delete old assets and re-fetch all items fresh from Target.
final class RescrapeAllEvent extends CuratorEvent {
  const RescrapeAllEvent();
}

/// Dispatched when the user clicks '재검토' to fetch live Target candidate images for a specific item.
final class FetchLiveCandidatesEvent extends CuratorEvent {
  const FetchLiveCandidatesEvent(this.itemId);
  final String itemId;
}

/// Dispatched when the user enters a custom Target product or image URL in the review modal.
final class InspectTargetUrlEvent extends CuratorEvent {
  const InspectTargetUrlEvent({
    required this.itemId,
    required this.targetUrl,
  });

  final String itemId;
  final String targetUrl;
}

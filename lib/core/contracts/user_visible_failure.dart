// Pure Dart failure contract for messages that are explicitly safe to show.

/// Marks a failure message as intentionally safe for presentation to users.
///
/// Infrastructure exceptions can contain URLs, response bodies, credentials,
/// or implementation details. The BLoC therefore exposes details only from
/// this transport-neutral contract and uses fixed text for every other error.
abstract interface class UserVisibleFailure {
  String get userVisibleMessage;
}

/// A small immutable failure value for non-infrastructure initialization work.
final class SimpleUserVisibleFailure implements UserVisibleFailure {
  const SimpleUserVisibleFailure(this.userVisibleMessage);

  @override
  final String userVisibleMessage;
}

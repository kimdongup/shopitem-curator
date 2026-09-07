// Pure Dart backend readiness port (Zero Flutter Dependencies)

import 'user_visible_failure.dart';

enum BackendReadinessOutcome { ready, cancelled }

/// Safe startup capability exposed by the authenticated backend adapter.
abstract interface class BackendReadinessGateway {
  Future<BackendReadinessOutcome> waitUntilReady({
    Duration? timeout = const Duration(seconds: 8),
    Duration pollInterval = const Duration(milliseconds: 200),
    Duration maximumPollInterval = const Duration(seconds: 2),
    Duration attemptTimeout = const Duration(seconds: 1),
    bool retryConfigurationFailures = false,
    Future<void>? cancelSignal,
    void Function(UserVisibleFailure failure)? onWaiting,
  });
}

// Pure Dart startup orchestration (Zero Flutter Dependencies)

import 'dart:async';

import '../bloc/curator_event.dart';
import '../contracts/backend_readiness_gateway.dart';
import '../contracts/user_visible_failure.dart';

typedef CuratorEventDispatcher = void Function(CuratorEvent event);
typedef CuratorSourceImageLoader = Future<List<int>> Function(String path);

/// Waits for the backend and submits the initial image exactly once.
///
/// Only the safe `/ready` GET is repeated. Once readiness succeeds, the source
/// image event is dispatched once and all OCR/catalog POST retry decisions stay
/// with the user and BLoC workflow.
final class CuratorStartupCoordinator {
  CuratorStartupCoordinator({
    required BackendReadinessGateway backendGateway,
    required CuratorEventDispatcher dispatchEvent,
    required CuratorSourceImageLoader loadSourceImage,
    this.sourceImagePath = 'assets/images/new.jpg',
    this.readyEvent,
    this.pollInterval = const Duration(milliseconds: 200),
    this.maximumPollInterval = const Duration(seconds: 2),
    this.attemptTimeout = const Duration(seconds: 1),
  })  : _backendGateway = backendGateway,
        _dispatchEvent = dispatchEvent,
        _loadSourceImage = loadSourceImage;

  final BackendReadinessGateway _backendGateway;
  final CuratorEventDispatcher _dispatchEvent;
  final CuratorSourceImageLoader _loadSourceImage;
  final String sourceImagePath;

  /// Production loads the server document catalog instead of a bundled file.
  /// The legacy initial-image path remains available to offline demos/tests.
  final CuratorEvent? readyEvent;
  final Duration pollInterval;
  final Duration maximumPollInterval;
  final Duration attemptTimeout;

  final Completer<void> _cancelSignal = Completer<void>();
  Future<void>? _starting;
  Future<void>? _retrying;
  bool _isCancelled = false;
  bool _sourceSubmitted = false;

  bool get isCancelled => _isCancelled;

  Future<void> start() {
    if (_isCancelled || _sourceSubmitted) return Future.value();
    final active = _starting;
    if (active != null) return active;

    late final Future<void> starting;
    starting = _run().whenComplete(() {
      if (identical(_starting, starting)) _starting = null;
    });
    _starting = starting;
    return starting;
  }

  /// Re-runs the safe readiness gate after a terminal startup failure.
  ///
  /// Concurrent button presses share one retry and a successful startup can
  /// never submit the source image a second time.
  Future<void> retry() {
    final active = _retrying;
    if (active != null) return active;

    late final Future<void> retrying;
    retrying = _retry().whenComplete(() {
      if (identical(_retrying, retrying)) _retrying = null;
    });
    _retrying = retrying;
    return retrying;
  }

  Future<void> _retry() async {
    final activeStart = _starting;
    if (activeStart != null) await activeStart;
    if (_isCancelled || _sourceSubmitted) return;

    _dispatchEvent(const InitializationRetryStartedEvent());
    await start();
  }

  void cancel() {
    if (_isCancelled) return;
    _isCancelled = true;
    if (!_cancelSignal.isCompleted) _cancelSignal.complete();
  }

  Future<void> _run() async {
    if (_isCancelled) return;

    late final BackendReadinessOutcome readiness;
    try {
      readiness = await _backendGateway.waitUntilReady(
        timeout: null,
        pollInterval: pollInterval,
        maximumPollInterval: maximumPollInterval,
        attemptTimeout: attemptTimeout,
        retryConfigurationFailures: true,
        cancelSignal: _cancelSignal.future,
        onWaiting: (failure) {
          if (!_isCancelled) {
            _dispatchEvent(InitializationWaitingEvent(failure));
          }
        },
      );
    } on UserVisibleFailure catch (failure) {
      if (!_isCancelled) {
        _dispatchEvent(InitializationFailedEvent(failure));
      }
      return;
    } on Object {
      if (!_isCancelled) {
        _dispatchEvent(const InitializationFailedEvent(
          SimpleUserVisibleFailure('백엔드 준비 상태를 확인하지 못했습니다.'),
        ));
      }
      return;
    }

    if (_isCancelled || readiness == BackendReadinessOutcome.cancelled) return;

    final event = readyEvent;
    if (event != null) {
      _sourceSubmitted = true;
      _dispatchEvent(event);
      return;
    }

    late final Object loadResult;
    try {
      loadResult = await Future.any<Object>([
        _loadSourceImage(sourceImagePath).then<Object>(_LoadedSourceImage.new),
        _cancelSignal.future.then<Object>((_) => const _StartupCancelled()),
      ]);
    } on Object {
      if (!_isCancelled) {
        _dispatchEvent(const InitializationFailedEvent(
          SimpleUserVisibleFailure('초기 입력 이미지를 불러오지 못했습니다.'),
        ));
      }
      return;
    }

    if (_isCancelled || loadResult is _StartupCancelled || _sourceSubmitted) {
      return;
    }
    final imageBytes = (loadResult as _LoadedSourceImage).bytes;
    if (imageBytes.isEmpty) {
      _dispatchEvent(const InitializationFailedEvent(
        SimpleUserVisibleFailure('초기 입력 이미지가 비어 있습니다.'),
      ));
      return;
    }

    _sourceSubmitted = true;
    _dispatchEvent(SelectSourceImageEvent(
      sourceImagePath,
      imageBytes: imageBytes,
    ));
  }
}

final class _LoadedSourceImage {
  const _LoadedSourceImage(this.bytes);

  final List<int> bytes;
}

final class _StartupCancelled {
  const _StartupCancelled();
}

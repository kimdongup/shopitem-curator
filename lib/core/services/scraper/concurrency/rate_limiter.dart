// Pure Dart Service (Zero Flutter Dependencies)

import 'dart:math';

/// Spreads local worker starts to reduce request bursts. This delay does not
/// override Retry-After or access denials enforced by TargetRequestPolicy.
class RateLimiter {
  const RateLimiter({
    this.minDelayMs = 50,
    this.maxDelayMs = 150,
  });

  final int minDelayMs;
  final int maxDelayMs;

  static final Random _rng = Random();

  /// 지정된 범위 내의 무작위 밀리초 동안 비동기 대기합니다.
  Future<void> waitJitter([int? overrideMin, int? overrideMax]) async {
    final min = overrideMin ?? minDelayMs;
    final max = overrideMax ?? maxDelayMs;
    final delay = (min >= max) ? min : min + _rng.nextInt(max - min);
    if (delay > 0) {
      await Future.delayed(Duration(milliseconds: delay));
    }
  }
}

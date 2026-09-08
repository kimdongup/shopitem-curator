// Pure Dart Service (Zero Flutter Dependencies)

import 'browser_fingerprints.dart';
import '../target_request_policy.dart';

/// [Crawlee Session]
/// 개별 HTTP 요청 세션의 상태와 Anti-Bot 브라우저 지문을 보관하는 단위
class ScraperSession {
  ScraperSession({
    required this.id,
    required this.fingerprint,
    this.usageCount = 0,
    this.errorCount = 0,
    this.isBlocked = false,
  });

  final String id;
  final BrowserFingerprint fingerprint;
  int usageCount;
  int errorCount;
  bool isBlocked;

  // Legacy preset metadata is not a browser identity for outbound requests.
  Map<String, String> get headers => TargetRequestPolicy.headers;

  void markGood() {
    usageCount++;
    if (errorCount > 0) errorCount--;
  }

  void markBad() {
    errorCount++;
    if (errorCount >= 2) {
      isBlocked = true;
    }
  }

  void retire() {
    isBlocked = true;
  }
}

/// [Crawlee SessionPool]
/// 다중 세션 및 브라우저 지문을 순환 관리하며,
/// Legacy session bookkeeping; request denials are handled by [requests].
/// Replacing bookkeeping entries never resets host denials or changes headers.
class SessionPool {
  SessionPool({int maxPoolSize = 8, TargetRequestPolicy? requestPolicy})
      : _maxPoolSize = maxPoolSize,
        requests = requestPolicy ?? TargetRequestPolicy() {
    if (maxPoolSize < 1) {
      throw ArgumentError.value(maxPoolSize, 'maxPoolSize', 'must be positive');
    }
    _initPool();
  }

  final int _maxPoolSize;
  final TargetRequestPolicy requests;
  final List<ScraperSession> _sessions = [];
  int _currentIndex = 0;
  int _replacementCount = 0;

  void _initPool() {
    const presets = BrowserFingerprint.presets;
    for (int i = 0; i < _maxPoolSize; i++) {
      final fp = presets[i % presets.length];
      _sessions.add(ScraperSession(
        id: 'session_${i}_${fp.id}',
        fingerprint: fp,
      ));
    }
  }

  /// 사용 가능한 유효 세션을 획득합니다 (Round-Robin with Blocked Filter)
  ScraperSession getSession() {
    // 1. 활성 상태인 세션 필터링
    final activeSessions = _sessions.where((s) => !s.isBlocked).toList();

    // 2. 모든 세션이 차단된 경우, 풀을 새로 리프레시
    if (activeSessions.isEmpty) {
      _sessions.clear();
      _initPool();
      return _sessions.first;
    }

    _currentIndex = (_currentIndex + 1) % activeSessions.length;
    return activeSessions[_currentIndex];
  }

  /// 차단된 세션을 폐기하고 즉시 새 세션을 풀에 보충합니다 (RetryOnBlocked 지원)
  ScraperSession retireAndGetNew(ScraperSession badSession) {
    badSession.retire();
    const presets = BrowserFingerprint.presets;
    final nextPreset =
        presets[(_sessions.length + _replacementCount++) % presets.length];
    final freshSession = ScraperSession(
      id: 'session_${DateTime.now().microsecondsSinceEpoch}'
          '_${_replacementCount}_${nextPreset.id}',
      fingerprint: nextPreset,
    );

    final badIndex = _sessions.indexOf(badSession);
    if (badIndex >= 0) {
      _sessions[badIndex] = freshSession;
    } else if (_sessions.length < _maxPoolSize) {
      _sessions.add(freshSession);
    } else {
      final blockedIndex = _sessions.indexWhere((session) => session.isBlocked);
      final replacementIndex = blockedIndex >= 0
          ? blockedIndex
          : _currentIndex.clamp(0, _sessions.length - 1);
      _sessions[replacementIndex] = freshSession;
    }
    return freshSession;
  }

  int get activeSessionCount => _sessions.where((s) => !s.isBlocked).length;

  int get sessionCount => _sessions.length;
}

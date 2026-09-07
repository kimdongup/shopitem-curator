// Pure Dart Service (Zero Flutter Dependencies)

import 'dart:async';
import 'rate_limiter.dart';

/// [Crawlee AutoscaledPool / Concurrent Executor]
/// WAF 차단을 방지하면서도 순차 대기(Serial) 대비 5~10배 빠른 처리 속도를 내는 비동기 병렬 실행기
class ConcurrentExecutor {
  const ConcurrentExecutor({
    this.defaultConcurrency = 3,
    this.rateLimiter = const RateLimiter(),
  });

  final int defaultConcurrency;
  final RateLimiter rateLimiter;

  /// 리스트의 아이템들을 최대 [maxConcurrency] 병렬로 실행하며,
  /// 원래의 순서(Order)를 보존하여 결과를 반환합니다.
  Future<List<R>> execute<T, R>({
    required List<T> items,
    required Future<R> Function(T item, int index) task,
    int? maxConcurrency,
    void Function(int completed, int total, T currentItem)? onProgress,
  }) async {
    if (items.isEmpty) return [];

    final concurrency = maxConcurrency ?? defaultConcurrency;
    final results = List<R?>.filled(items.length, null);
    var currentIndex = 0;
    var completedCount = 0;

    Future<void> worker() async {
      while (true) {
        int index;
        T item;

        // 다음 작업 슬롯 가져오기
        if (currentIndex >= items.length) {
          break;
        }
        index = currentIndex;
        item = items[index];
        currentIndex++;

        // 지터 적용 (WAF 패턴 분산)
        await rateLimiter.waitJitter();

        // 작업 실행
        final result = await task(item, index);
        results[index] = result;

        completedCount++;
        onProgress?.call(completedCount, items.length, item);
      }
    }

    // concurrency 개수만큼 워커 비동기 풀 기동
    final workers = List.generate(
      concurrency.clamp(1, items.length),
      (_) => worker(),
    );

    await Future.wait(workers);

    return results.cast<R>();
  }
}

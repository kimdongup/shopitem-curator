// Pure Dart Service (Zero Flutter Dependencies)

class _CacheEntry<T> {
  _CacheEntry(this.data, this.expiresAt);
  final T data;
  final DateTime expiresAt;

  bool get isExpired => DateTime.now().isAfter(expiresAt);
}

/// [Crawlee KeyValueStore / Cache Layer]
/// 동일 검색어 및 TCIN에 대한 불필요한 중복 네트워크 왕복을 방지하고
/// 스크래핑 결과를 즉각 응답하는 TTL 기반 인메모리 캐시 저장소
class ScrapeCacheStore {
  ScrapeCacheStore({
    Duration defaultTtl = const Duration(hours: 1),
    int maxEntries = 256,
  })  : _defaultTtl = defaultTtl,
        _maxEntries = maxEntries {
    if (maxEntries < 1) {
      throw ArgumentError.value(maxEntries, 'maxEntries', 'must be positive');
    }
  }

  final Duration _defaultTtl;
  final int _maxEntries;
  final Map<String, _CacheEntry<dynamic>> _store = {};

  /// 캐시에서 값을 가져옵니다. 만료되었거나 없으면 null 반환.
  /// 조회가 성공하면 해당 키를 가장 최근 사용 항목(LRU)으로 갱신합니다.
  T? get<T>(String key) {
    final entry = _store[key];
    if (entry == null) return null;
    if (entry.isExpired) {
      _store.remove(key);
      return null;
    }
    // LRU 갱신: 기존 위치에서 제거 후 맨 뒤로 재삽입
    _store.remove(key);
    _store[key] = entry;
    return entry.data as T?;
  }

  /// 캐시에 값을 저장합니다. (용량 초과 시 가장 오래된 항목 퇴출)
  void set<T>(String key, T value, [Duration? ttl]) {
    _removeExpiredEntries();
    if (_store.containsKey(key)) {
      _store.remove(key);
    } else if (_store.length >= _maxEntries) {
      _store.remove(_store.keys.first);
    }
    final effectiveTtl = ttl ?? _defaultTtl;
    _store[key] = _CacheEntry<T>(
      value,
      DateTime.now().add(effectiveTtl),
    );
  }

  /// 특정 키가 캐시에 유효하게 존재하는지 확인합니다.
  bool contains(String key) => get(key) != null;

  /// 캐시를 초기화합니다.
  void clear() => _store.clear();

  int get size {
    _removeExpiredEntries();
    return _store.length;
  }

  void _removeExpiredEntries() {
    _store.removeWhere((_, entry) => entry.isExpired);
  }
}

import 'dart:async';

import 'package:shopitem_curator/core/models/curator_item.dart';
import 'package:shopitem_curator/core/services/scraper/concurrency/concurrent_executor.dart';
import 'package:shopitem_curator/core/services/scraper/concurrency/rate_limiter.dart';
import 'package:shopitem_curator/core/services/target_catalog_rescraper.dart';
import 'package:shopitem_curator/core/services/target_fetcher_service.dart';
import 'package:test/test.dart';

void main() {
  test('rescrape is bounded, ordered, progressive, and isolates item failures',
      () async {
    final fetcher = _ControlledFetcher();
    addTearDown(fetcher.close);
    final rescraper = TargetCatalogRescraper(
      fetcher,
      executor: const ConcurrentExecutor(
        rateLimiter: RateLimiter(minDelayMs: 0, maxDelayMs: 0),
      ),
      maxConcurrency: 3,
    );
    final items = List.generate(4, (index) => _item(index + 1));
    final completed = <int>[];
    final progressedIds = <String>[];

    final result = await rescraper.rescrapeAll(
      items: items,
      onProgress: (count, total, item) {
        expect(total, items.length);
        completed.add(count);
        progressedIds.add(item.id);
      },
    );

    expect(fetcher.maximumConcurrentResolutions, 3);
    expect(result.items.map((item) => item.id), items.map((item) => item.id));
    expect(result.successfulItemCount, 3);
    expect(result.failedItemCount, 1);
    expect(result.items[0].name, 'Live Item 1');
    expect(result.items[1].name, 'Live Item 2');
    expect(result.items[2].name, 'Item 3');
    expect(result.items[2].imageUrl, 'assets/items/item_3.png');
    expect(result.items[3].name, 'Live Item 4');
    expect(result.items.every((item) => !item.isApproved), isTrue);
    expect(completed, [1, 2, 3, 4]);
    expect(progressedIds.toSet(), items.map((item) => item.id).toSet());
  });
}

final class _ControlledFetcher extends TargetFetcherService {
  var _activeResolutions = 0;
  var maximumConcurrentResolutions = 0;

  @override
  Future<TargetPdpResolutionResult?> resolveTargetProductPdpUrl(
    String query,
  ) async {
    _activeResolutions++;
    if (_activeResolutions > maximumConcurrentResolutions) {
      maximumConcurrentResolutions = _activeResolutions;
    }
    final itemNumber = int.parse(query.split(' ').last);
    try {
      await Future<void>.delayed(Duration(
        milliseconds: switch (itemNumber) {
          1 => 30,
          2 => 20,
          3 => 1,
          _ => 5,
        },
      ));
      if (itemNumber == 3) {
        throw Exception('one upstream item failed');
      }
      return TargetPdpResolutionResult(
        name: 'Live Item $itemNumber',
        pdpUrl: 'https://www.target.com/p/-/A-1000000$itemNumber',
        price: itemNumber.toDouble(),
        primaryGuestId: 'guest-$itemNumber',
      );
    } finally {
      _activeResolutions--;
    }
  }

  @override
  Future<String?> adoptMainImageFromPdp(
    String pdpUrl, {
    String? fallbackImageUrl,
  }) async {
    return fallbackImageUrl;
  }
}

CuratorItem _item(int number) => CuratorItem(
      id: 'item_$number',
      name: 'Item $number',
      category: 'School supplies',
      isPersonal: false,
      quantity: 1,
      price: 1,
      priceCurrency: 'USD',
      description: 'Original item $number',
      targetUrl: 'https://www.target.com/p/-/A-2000000$number',
      imageUrl: 'assets/items/item_$number.png',
      bounds: ItemLayoutBounds(
        x: number * 10,
        y: 0,
        width: 10,
        height: 10,
      ),
      polygon: const [
        CuratorPoint(0, 0),
        CuratorPoint(10, 0),
        CuratorPoint(10, 10),
      ],
      centroid: const CuratorPoint(5, 5),
    );

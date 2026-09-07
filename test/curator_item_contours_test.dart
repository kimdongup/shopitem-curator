import 'package:shopitem_curator/core/models/curator_item.dart';
import 'package:test/test.dart';

void main() {
  group('CuratorItem compound contours', () {
    test('legacy polygon JSON becomes one immutable contour', () {
      final item = CuratorItem.fromJson({
        'id': 'legacy',
        'bounds': {'x': 0, 'y': 0, 'width': 10, 'height': 10},
        'polygon': [
          [0, 0],
          [10, 0],
          [0, 10],
        ],
      });

      expect(item.contours, hasLength(1));
      expect(item.contours.single, hasLength(3));
      expect(() => item.contours.add(const []), throwsUnsupportedError);
      expect(
        () => item.contours.single.add(const CuratorPoint(5, 5)),
        throwsUnsupportedError,
      );

      final roundTrip = CuratorItem.fromJson(item.toJson());
      expect(roundTrip.contours, hasLength(1));
      expect(roundTrip.toJson()['contours'], item.toJson()['contours']);
    });

    test('explicit polygon replacement clears stale compound geometry', () {
      final item = _compoundItem();
      const replacement = [
        CuratorPoint(20, 20),
        CuratorPoint(80, 20),
        CuratorPoint(50, 80),
      ];

      final updated = item.copyWith(polygon: replacement);

      expect(updated.contours, hasLength(1));
      expect(
        updated.contours.single.map((point) => point.toJson()).toList(),
        equals(replacement.map((point) => point.toJson()).toList()),
      );
    });

    test('unknown non-positive prices are displayed honestly', () {
      final item = _compoundItem().copyWith(price: 0);
      const candidate = TargetProductCandidate(
        id: 'unknown-price',
        name: 'Unknown price',
        price: 0,
        imageUrl: '',
        targetUrl: '',
        description: '',
      );

      expect(item.formattedPrice, '가격 확인 필요');
      expect(candidate.formattedPrice, '가격 확인 필요');
    });
  });
}

CuratorItem _compoundItem() {
  const left = [
    CuratorPoint(0, 0),
    CuratorPoint(30, 0),
    CuratorPoint(30, 30),
    CuratorPoint(0, 30),
  ];
  const right = [
    CuratorPoint(70, 0),
    CuratorPoint(100, 0),
    CuratorPoint(100, 30),
    CuratorPoint(70, 30),
  ];
  return CuratorItem(
    id: 'compound',
    name: 'Compound',
    category: 'test',
    isPersonal: false,
    quantity: 1,
    price: 1,
    priceCurrency: 'USD',
    description: '',
    targetUrl: '',
    imageUrl: '',
    bounds: const ItemLayoutBounds(x: 0, y: 0, width: 100, height: 100),
    polygon: left,
    contours: const [left, right],
    centroid: const CuratorPoint(50, 15),
  );
}

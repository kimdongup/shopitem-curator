import 'package:shopitem_curator/core/models/target_purchase_url.dart';
import 'package:test/test.dart';

void main() {
  group('TargetPurchaseUrl', () {
    test('accepts canonical Target PDP links', () {
      final result = TargetPurchaseUrl.tryParse(
        'https://www.target.com/p/example-product/-/A-12345678?preselect=123',
      );

      expect(result, isNotNull);
      expect(result.toString(), contains('/p/example-product/-/A-12345678'));
    });

    test('accepts slugless Target PDP links', () {
      final result = TargetPurchaseUrl.tryParse(
        'https://www.target.com/p/-/A-91530223',
      );

      expect(result, isNotNull);
      expect(result.toString(), 'https://www.target.com/p/-/A-91530223');
    });

    test('rejects search pages and image CDN links', () {
      expect(
        TargetPurchaseUrl.isValid(
          'https://www.target.com/s?searchTerm=school+supplies',
        ),
        isFalse,
      );
      expect(
        TargetPurchaseUrl.isValid(
          'https://target.scene7.com/is/image/Target/GUEST_123',
        ),
        isFalse,
      );
    });

    test('rejects foreign hosts and active schemes', () {
      expect(
        TargetPurchaseUrl.isValid(
          'https://target.com.example.org/p/item/-/A-123',
        ),
        isFalse,
      );
      expect(
        TargetPurchaseUrl.isValid('javascript:alert(1)'),
        isFalse,
      );
      expect(
        TargetPurchaseUrl.isValid('http://www.target.com/p/item/-/A-123'),
        isFalse,
      );
    });

    test('rejects embedded credentials and nonstandard ports', () {
      expect(
        TargetPurchaseUrl.isValid(
          'https://attacker@www.target.com/p/item/-/A-123',
        ),
        isFalse,
      );
      expect(
        TargetPurchaseUrl.isValid(
          'https://www.target.com:8443/p/item/-/A-123',
        ),
        isFalse,
      );
    });
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:inventory_plus/services/store_access_service.dart';

void main() {
  test(
    'legacy admin restriction is not retained after removing its control',
    () {
      final settings = StoreAccessSettings.fromMap({
        'location_id': 'store-1',
        'opening_time': '08:00:00',
        'closing_time': '21:00:00',
        'staff_access_before_minutes': 15,
        'staff_access_after_minutes': 15,
        'restrict_staff_login': true,
        'allow_admin_anytime': false,
      });

      expect(settings.allowAdminAnytime, isTrue);
      expect(settings.toMap()['allow_admin_anytime'], isTrue);
      expect(settings.staffAccessBeforeMinutes, 15);
      expect(settings.staffAccessAfterMinutes, 15);
    },
  );
}

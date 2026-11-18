import 'package:flutter_test/flutter_test.dart';
import 'package:inventory_plus/services/store_access_service.dart';

void main() {
  test('closed-day reason survives weekly-hours serialization', () {
    final settings = StoreAccessSettings.fromMap({
      'location_id': 'store-1',
      'opening_time': '07:30:00',
      'closing_time': '19:00:00',
      'weekly_hours': {
        '3': {
          'open': '07:30:00',
          'close': '19:00:00',
          'closed': true,
          'closed_reason': 'Maintenance',
        },
      },
    });

    expect(settings.hoursForWeekday(3).closedReason, 'Maintenance');
    final savedHours = settings.toMap()['weekly_hours'] as Map<String, dynamic>;
    expect(
      (savedHours['3'] as Map<String, dynamic>)['closed_reason'],
      'Maintenance',
    );
    expect(
      settings
          .hoursForWeekday(3)
          .copyWith(closed: false, closedReason: '')
          .toMap()['closed_reason'],
      '',
    );
  });

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

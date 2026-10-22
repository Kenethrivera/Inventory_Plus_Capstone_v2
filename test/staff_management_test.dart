import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:inventory_plus/logic/staff_management.dart';

void main() {
  test('new staff payload normalizes blank optional fields to null', () {
    final payload = buildStaffCreationPayload(
      name: ' Yves Santos ',
      username: ' yves ',
      passwordHash: 'hash',
      role: ' STAFF ',
      locationId: 'location-a',
      email: '   ',
      phone: '',
      address: '  ',
    );

    expect(payload['name'], 'Yves Santos');
    expect(payload['username'], 'yves');
    expect(payload['role'], 'staff');
    expect(payload['email'], isNull);
    expect(payload['phone'], isNull);
    expect(payload['address'], isNull);
    expect(payload, isNot(contains('id')));
    expect(payload, isNot(contains('must_change_password')));
  });

  test('duplicate username maps only from a username unique violation', () {
    expect(
      classifyStaffCreationFailure(
        code: '23505',
        message:
            'duplicate key value violates unique constraint '
            '"profiles_username_key"',
      ),
      StaffCreationFailure.duplicateUsername,
    );
    expect(
      staffCreationConstraintName(
        message:
            'duplicate key value violates unique constraint '
            '"profiles_username_key"',
      ),
      'profiles_username_key',
    );
  });

  test('other database failures are not mislabeled as username conflicts', () {
    expect(
      classifyStaffCreationFailure(
        code: '23505',
        details: 'Key (email)=() already exists.',
      ),
      StaffCreationFailure.duplicateEmail,
    );
    expect(
      classifyStaffCreationFailure(
        code: '23503',
        message: 'foreign key violation',
      ),
      StaffCreationFailure.unexpected,
    );
    expect(
      classifyStaffCreationFailure(
        code: 'PGRST205',
        message: 'Could not find the table in the schema cache',
      ),
      StaffCreationFailure.backendUnavailable,
    );
  });

  test('all non-admin application staff roles use the force-change gate', () {
    expect(roleRequiresForcedPasswordChange('helper'), isTrue);
    expect(roleRequiresForcedPasswordChange('staff'), isTrue);
    expect(roleRequiresForcedPasswordChange('cashier'), isTrue);
    expect(roleRequiresForcedPasswordChange('admin'), isFalse);
  });

  test('reset and change RPCs use identical non-admin role semantics', () {
    final sql = File(
      'database/phase_5b_app_sessions.sql',
    ).readAsStringSync().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();

    expect(
      sql,
      contains(
        "when v_target_role in ('helper', 'staff', 'cashier') then true",
      ),
    );
    expect(
      sql,
      contains("when v_role in ('helper', 'staff', 'cashier') then false"),
    );
  });

  test('legacy and newly created staff share role-based reset semantics', () {
    final newlyCreated = buildStaffCreationPayload(
      name: 'Abdul Malik',
      username: 'abdul',
      passwordHash: 'hash',
      role: 'staff',
      locationId: 'location-a',
    );

    expect(
      roleRequiresForcedPasswordChange(newlyCreated['role']?.toString()),
      roleRequiresForcedPasswordChange('staff'),
    );
  });
}

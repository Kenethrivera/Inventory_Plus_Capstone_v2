enum StaffCreationFailure {
  duplicateUsername,
  duplicateEmail,
  duplicatePhone,
  backendUnavailable,
  unauthorized,
  databaseConflict,
  unexpected,
}

class StaffCreationResult {
  const StaffCreationResult._({required this.success, this.failure});

  const StaffCreationResult.success() : this._(success: true);

  const StaffCreationResult.failure(StaffCreationFailure failure)
    : this._(success: false, failure: failure);

  final bool success;
  final StaffCreationFailure? failure;
}

String? normalizeOptionalStaffField(String? value) {
  final normalized = value?.trim();
  return normalized == null || normalized.isEmpty ? null : normalized;
}

String generateStaffPassword({required String name, required String role}) {
  final parts = name.trim().split(RegExp(r'\s+'));
  if (parts.isEmpty || parts.first.isEmpty) return '';
  final initials = parts.length == 1
      ? parts.first[0].toUpperCase()
      : '${parts.first[0]}${parts.last[0]}'.toUpperCase();
  final prefix = switch (role.trim().toLowerCase()) {
    'admin' => 'Admin',
    'helper' => 'Helper',
    'bodegero' => 'Bodegero',
    _ => 'Cashier',
  };
  return '$prefix$initials@123';
}

Map<String, dynamic> buildStaffCreationPayload({
  required String name,
  required String username,
  required String passwordHash,
  required String role,
  required String locationId,
  String? email,
  String? phone,
  String? address,
  bool mustChangePassword = false,
}) {
  return <String, dynamic>{
    'name': name.trim(),
    'username': username.trim(),
    'password': passwordHash,
    'role': role.trim().toLowerCase(),
    'location_id': locationId,
    'email': normalizeOptionalStaffField(email),
    'phone': normalizeOptionalStaffField(phone),
    'address': normalizeOptionalStaffField(address),
    if (mustChangePassword) 'must_change_password': true,
  };
}

StaffCreationFailure classifyStaffCreationFailure({
  String? code,
  String? message,
  String? details,
  String? hint,
}) {
  final normalizedCode = code?.trim().toUpperCase() ?? '';
  final diagnostic = <String?>[
    message,
    details,
    hint,
  ].whereType<String>().join(' ').toLowerCase();

  if (normalizedCode == '23505') {
    if (diagnostic.contains('username')) {
      return StaffCreationFailure.duplicateUsername;
    }
    if (diagnostic.contains('email')) {
      return StaffCreationFailure.duplicateEmail;
    }
    if (diagnostic.contains('phone')) {
      return StaffCreationFailure.duplicatePhone;
    }
    return StaffCreationFailure.databaseConflict;
  }

  if (normalizedCode == '42501' || normalizedCode == 'PGRST301') {
    return StaffCreationFailure.unauthorized;
  }

  if (normalizedCode == '42883' ||
      normalizedCode == 'PGRST202' ||
      normalizedCode == 'PGRST205') {
    return StaffCreationFailure.backendUnavailable;
  }

  return StaffCreationFailure.unexpected;
}

String? staffCreationConstraintName({String? message, String? details}) {
  final diagnostic = '${message ?? ''} ${details ?? ''}';
  final match = RegExp(
    r'''unique constraint ["']([^"']+)["']''',
    caseSensitive: false,
  ).firstMatch(diagnostic);
  return match?.group(1);
}

bool roleRequiresForcedPasswordChange(String? role) {
  return switch (role?.trim().toLowerCase()) {
    'helper' || 'bodegero' || 'staff' || 'cashier' => true,
    _ => false,
  };
}

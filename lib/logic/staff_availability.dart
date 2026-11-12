enum StaffAvailability { offline, onBreak, busy, available }

bool isCurrentStaffPresence(
  Map<String, dynamic> row, {
  required DateTime now,
  required Duration activeTimeout,
}) {
  if (row['logged_out_at'] != null) return false;
  final online = row['is_online'] == true;
  final onBreak =
      row['user_role']?.toString().toLowerCase() == 'helper' &&
      row['is_online'] == false &&
      row['current_module'] == 'On break';
  if (!online && !onBreak) return false;
  final lastSeen = DateTime.tryParse(row['last_seen_at']?.toString() ?? '');
  if (lastSeen == null) return false;
  final age = now.toUtc().difference(lastSeen.toUtc());
  return age < activeTimeout;
}

StaffAvailability resolveStaffAvailability({
  required bool isOnline,
  required bool isOnBreak,
  required bool isHelper,
  required int activeOrders,
}) {
  if (isOnBreak) return StaffAvailability.onBreak;
  if (!isOnline) return StaffAvailability.offline;
  if (isHelper && activeOrders > 0) return StaffAvailability.busy;
  return StaffAvailability.available;
}

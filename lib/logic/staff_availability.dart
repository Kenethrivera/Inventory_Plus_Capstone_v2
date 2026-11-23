import '../data/inventory.dart';

const String staffPreparingModule = 'Preparing order';
const String staffLoadingModule = 'Loading order';

enum StaffAvailability { offline, onBreak, preparing, loading, available }

Map<String, int> activeLoadingWorkloads(Iterable<CustomerOrder> orders) {
  final counts = <String, int>{};
  for (final order in orders) {
    if (order.status != 'pending' && order.status != 'solo_picking') continue;
    if (order.loadingVerifiedAt != null) continue;
    if (!order.items.any((item) => item.requiresLoading)) continue;
    final bodegeroId = order.assignedBodegeroId?.trim();
    if (bodegeroId == null || bodegeroId.isEmpty) continue;
    counts[bodegeroId] = (counts[bodegeroId] ?? 0) + 1;
  }
  return Map<String, int>.unmodifiable(counts);
}

bool isCurrentStaffPresence(
  Map<String, dynamic> row, {
  required DateTime now,
  required Duration activeTimeout,
}) {
  if (row['logged_out_at'] != null) return false;
  final online = row['is_online'] == true;
  final onBreak =
      const {
        'helper',
        'bodegero',
      }.contains(row['user_role']?.toString().toLowerCase()) &&
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
  bool isBodegero = false,
  required int activeOrders,
  String? currentModule,
}) {
  if (isOnBreak) {
    return StaffAvailability.onBreak;
  }

  if (!isOnline) {
    return StaffAvailability.offline;
  }

  if (isHelper &&
      (currentModule?.trim() == staffPreparingModule ||
          currentModule?.trim().startsWith('$staffPreparingModule:') == true)) {
    return StaffAvailability.preparing;
  }

  if (isBodegero &&
      (currentModule?.trim() == staffLoadingModule ||
          currentModule?.trim().startsWith('$staffLoadingModule:') == true)) {
    return StaffAvailability.loading;
  }

  // Assigned orders are workload, not proof of active work.
  return StaffAvailability.available;
}

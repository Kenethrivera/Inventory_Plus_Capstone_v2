import '../data/inventory.dart';

class HelperAssignmentCandidate {
  const HelperAssignmentCandidate({
    required this.id,
    required this.name,
    required this.locationId,
    required this.lastSeenAt,
  });

  final String id;
  final String name;
  final String locationId;
  final DateTime lastSeenAt;
}

class AutomaticHelperAssignmentResult {
  const AutomaticHelperAssignmentResult({
    required this.orderId,
    required this.helperId,
    required this.helperName,
    required this.assignedAt,
  });

  final String orderId;
  final String helperId;
  final String helperName;
  final DateTime assignedAt;

  factory AutomaticHelperAssignmentResult.fromJson(Map<String, dynamic> json) {
    return AutomaticHelperAssignmentResult(
      orderId: json['order_id'].toString(),
      helperId: json['helper_id'].toString(),
      helperName: json['helper_name']?.toString() ?? 'Helper',
      assignedAt:
          DateTime.tryParse(json['assigned_at']?.toString() ?? '')?.toUtc() ??
          DateTime.now().toUtc(),
    );
  }
}

List<HelperAssignmentCandidate> eligibleHelpersFromPresence({
  required Iterable<Map<String, dynamic>> presenceRows,
  required String locationId,
  required DateTime now,
  required Duration activeTimeout,
}) {
  final normalizedLocation = locationId.trim();
  final helpers = <HelperAssignmentCandidate>[];

  for (final row in presenceRows) {
    final role = row['user_role']?.toString().trim().toLowerCase();
    final rowLocation = row['location_id']?.toString().trim();
    final id = row['user_id']?.toString().trim();
    final name = row['user_name']?.toString().trim();
    final lastSeenAt = DateTime.tryParse(
      row['last_seen_at']?.toString() ?? '',
    )?.toUtc();

    if (row['is_online'] != true ||
        role != 'helper' ||
        rowLocation != normalizedLocation ||
        id == null ||
        id.isEmpty ||
        name == null ||
        name.isEmpty ||
        lastSeenAt == null) {
      continue;
    }

    final age = now.toUtc().difference(lastSeenAt);
    if (age >= activeTimeout) continue;

    helpers.add(
      HelperAssignmentCandidate(
        id: id,
        name: name,
        locationId: rowLocation!,
        lastSeenAt: lastSeenAt,
      ),
    );
  }

  helpers.sort((left, right) {
    final byName = left.name.toLowerCase().compareTo(right.name.toLowerCase());
    return byName != 0 ? byName : _compareStableIds(left.id, right.id);
  });
  return List<HelperAssignmentCandidate>.unmodifiable(helpers);
}

Map<String, dynamic> initialHelperAssignmentFields({
  required HelperAssignmentCandidate? helper,
  required DateTime assignedAt,
}) {
  if (helper == null) return const <String, dynamic>{};
  return <String, dynamic>{
    'assigned_helper_id': helper.id,
    'assigned_helper_name': helper.name,
    'assigned_at': assignedAt.toUtc().toIso8601String(),
  };
}

List<HelperAssignmentCandidate> rankHelpersByActiveWorkload({
  required Iterable<HelperAssignmentCandidate> helpers,
  required Iterable<CustomerOrder> orders,
}) {
  final helperList = helpers.toList(growable: false);
  final activeCounts = <String, int>{};
  final lastAssignedAt = <String, DateTime>{};

  for (final order in orders) {
    final helperId = order.assignedHelperId?.trim();
    if (helperId == null || helperId.isEmpty) continue;

    if (order.status.trim().toLowerCase() == 'pending') {
      activeCounts[helperId] = (activeCounts[helperId] ?? 0) + 1;
    }

    final assignedAt = order.assignedAt;
    final previous = lastAssignedAt[helperId];
    if (assignedAt != null &&
        (previous == null || assignedAt.isAfter(previous))) {
      lastAssignedAt[helperId] = assignedAt;
    }
  }

  final ranked = helperList.toList(growable: false);
  ranked.sort((left, right) {
    final byLoad = (activeCounts[left.id] ?? 0).compareTo(
      activeCounts[right.id] ?? 0,
    );
    if (byLoad != 0) return byLoad;

    final leftAssigned = lastAssignedAt[left.id];
    final rightAssigned = lastAssignedAt[right.id];
    if (leftAssigned == null && rightAssigned != null) return -1;
    if (leftAssigned != null && rightAssigned == null) return 1;
    if (leftAssigned != null && rightAssigned != null) {
      final byLastAssignment = leftAssigned.compareTo(rightAssigned);
      if (byLastAssignment != 0) return byLastAssignment;
    }

    return _compareStableIds(left.id, right.id);
  });
  return List<HelperAssignmentCandidate>.unmodifiable(ranked);
}

int _compareStableIds(String left, String right) {
  final leftNumber = BigInt.tryParse(left);
  final rightNumber = BigInt.tryParse(right);
  if (leftNumber != null && rightNumber != null) {
    return leftNumber.compareTo(rightNumber);
  }
  return left.compareTo(right);
}

class AssignmentReconciliationGate {
  bool _inFlight = false;
  bool _rerunQueued = false;
  bool _disposed = false;

  bool get isInFlight => _inFlight;

  Future<void> schedule(Future<void> Function() reconcileOnce) async {
    if (_disposed) return;
    if (_inFlight) {
      _rerunQueued = true;
      return;
    }

    _inFlight = true;
    try {
      do {
        _rerunQueued = false;
        await reconcileOnce();
      } while (_rerunQueued && !_disposed);
    } finally {
      _inFlight = false;
    }
  }

  void dispose() {
    _disposed = true;
    _rerunQueued = false;
  }
}

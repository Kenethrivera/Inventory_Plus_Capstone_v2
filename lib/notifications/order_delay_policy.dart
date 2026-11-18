import '../data/inventory.dart';

enum OrderDelayStage {
  waitingForStaff('Waiting for staff'),
  beingPrepared('Being prepared'),
  readyForRelease('Ready for release');

  const OrderDelayStage(this.label);
  final String label;
}

class OverdueOrderStage {
  const OverdueOrderStage({
    required this.orderId,
    required this.stage,
    required this.startedAt,
    required this.elapsed,
  });

  final String orderId;
  final OrderDelayStage stage;
  final DateTime startedAt;
  final Duration elapsed;

  String get identity => 'order-delay:$orderId:${stage.name}';
}

OverdueOrderStage? overdueOrderStage(
  CustomerOrder order,
  DateTime now, {
  Duration threshold = const Duration(minutes: 15),
}) {
  final current = currentOrderDelayStage(order, now);
  if (current == null ||
      current.elapsed.isNegative ||
      current.elapsed < threshold) {
    return null;
  }
  return current;
}

OverdueOrderStage? currentOrderDelayStage(CustomerOrder order, DateTime now) {
  if (order.items.isEmpty) return null;

  final status = order.status.toLowerCase();
  OrderDelayStage stage;
  DateTime startedAt;
  if (status == 'prepared') {
    stage = OrderDelayStage.readyForRelease;
    startedAt = order.preparedAt ?? order.updatedAt ?? order.createdAt;
  } else if (status == 'pending' || status == 'solo_picking') {
    final hasLightItems = order.items.any((item) => !item.requiresLoading);
    final waiting =
        status == 'pending' &&
        (hasLightItems
            ? order.assignedHelperId == null
            : order.assignedBodegeroId == null);
    if (waiting) {
      stage = OrderDelayStage.waitingForStaff;
      startedAt = order.createdAt;
    } else {
      stage = OrderDelayStage.beingPrepared;
      // Heavy-only assignments do not have an assigned_at column. Their last
      // order update is a conservative starting point for this stage.
      startedAt = order.assignedAt ?? order.updatedAt ?? order.createdAt;
    }
  } else {
    return null;
  }

  final elapsed = now.difference(startedAt);
  return OverdueOrderStage(
    orderId: order.id,
    stage: stage,
    startedAt: startedAt,
    elapsed: elapsed,
  );
}

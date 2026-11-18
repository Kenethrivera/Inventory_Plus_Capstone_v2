import '../data/inventory.dart';

bool orderIsWaitingForStaff(CustomerOrder order) {
  final status = order.status.toLowerCase();
  if (status != 'pending' && status != 'solo_picking') return false;

  final needsHelper =
      status == 'pending' && order.items.any((item) => !item.requiresLoading);
  final needsBodegero = order.items.any((item) => item.requiresLoading);
  return (needsHelper && order.assignedHelperId == null) ||
      (needsBodegero && order.assignedBodegeroId == null);
}

String orderActivityStatusLabel(CustomerOrder order) {
  final status = order.status.toLowerCase();
  if (orderIsWaitingForStaff(order)) return 'Waiting';
  return switch (status) {
    'solo_picking' => 'Preparing',
    'pending'
        when order.items.any((item) => item.picked || item.heavyVerified) =>
      'Preparing',
    'pending' => 'Assigned',
    'prepared' => 'Ready',
    'completed' => 'Completed',
    'cancelled' => 'Cancelled',
    'returned' => 'Returned',
    _ => order.status,
  };
}

import '../data/inventory.dart';

bool orderNeedsHelper(CustomerOrder order) =>
    order.items.any((item) => !item.requiresLoading);

String orderAssignedStaffLabel(CustomerOrder order) {
  if (orderNeedsHelper(order)) {
    final helper = order.assignedHelperName?.trim();
    return helper == null || helper.isEmpty ? 'Unassigned' : helper;
  }

  if (order.items.any((item) => item.requiresLoading)) {
    final bodegero = order.assignedBodegeroName?.trim();
    return bodegero == null || bodegero.isEmpty
        ? 'Bodegero unassigned'
        : 'Bodegero: $bodegero';
  }

  return 'Unassigned';
}

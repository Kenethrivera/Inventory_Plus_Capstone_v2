import '../data/inventory.dart';

bool orderNeedsHelper(CustomerOrder order) =>
    order.items.any((item) => !item.requiresLoading);

String orderAssignedStaffLabel(CustomerOrder order) {
  final needsHelper = orderNeedsHelper(order);
  final needsBodegero = order.items.any((item) => item.requiresLoading);
  final helper = order.assignedHelperName?.trim();
  final bodegero = order.assignedBodegeroName?.trim();
  final helperLabel = helper != null && helper.isNotEmpty
      ? helper
      : order.assignedHelperId != null
          ? 'Assigned'
          : 'Unassigned';
  final bodegeroLabel = bodegero != null && bodegero.isNotEmpty
      ? bodegero
      : order.assignedBodegeroId != null
          ? 'Assigned'
          : 'Unassigned';

  if (needsHelper && needsBodegero) {
    return 'Helper: $helperLabel\nBodegero: $bodegeroLabel';
  }

  if (needsHelper) {
    return helperLabel;
  }

  if (needsBodegero) {
    return 'Bodegero: $bodegeroLabel';
  }

  return 'Unassigned';
}

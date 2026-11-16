import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../data/inventory.dart';
import '../../logic/order_work_progress.dart';

const _ink = Color(0xFF211F1D);
const _muted = Color(0xFF756D67);
const _green = Color(0xFF21804A);
const _orange = Color(0xFFC83D08);

String cashierPreparationSubtitle(CustomerOrder order) {
  if (order.status == 'prepared') return 'Ready for Pickup';
  final progress = OrderWorkProgress.fromOrder(order);
  final parts = <String>[
    if (progress.lightTotal > 0)
      '${progress.lightPicked}/${progress.lightTotal} light',
    if (progress.heavyTotal > 0)
      '${progress.heavyScanned}/${progress.heavyTotal} heavy',
  ];
  return parts.isEmpty ? 'Being Prepared' : 'Preparing · ${parts.join(' · ')}';
}

({String label, bool complete}) cashierItemProgress(
  CustomerOrder order,
  CustomerOrderItem item,
) {
  if (item.requiresLoading) {
    if (order.loadingVerifiedAt != null) {
      return (label: 'Loaded onto truck', complete: true);
    }
    if (item.heavyVerified) {
      return (label: 'QR verified · loading pending', complete: false);
    }
    return (label: 'Awaiting Bodegero scan', complete: false);
  }
  if (item.picked || order.status == 'prepared') {
    return (label: 'Picked by Helper', complete: true);
  }
  return (label: 'Awaiting Helper scan', complete: false);
}

class CashierOrderPreparation extends StatelessWidget {
  const CashierOrderPreparation({super.key, required this.order});

  final CustomerOrder order;

  @override
  Widget build(BuildContext context) {
    final progress = OrderWorkProgress.fromOrder(order);
    if (progress.lightTotal == 0 && progress.heavyTotal == 0) {
      return const SizedBox.shrink();
    }
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFFAF8F5),
        border: Border.all(color: const Color(0xFFE8E1D9)),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(LucideIcons.activity, size: 16, color: _orange),
              SizedBox(width: 8),
              Text(
                'Live preparation',
                style: TextStyle(
                  color: _ink,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          if (progress.lightTotal > 0) ...[
            const SizedBox(height: 12),
            _roleProgress(
              'Helper',
              order.assignedHelperName,
              progress.helperSummary,
              progress.lightComplete,
            ),
          ],
          if (progress.heavyTotal > 0) ...[
            const SizedBox(height: 12),
            _roleProgress(
              'Bodegero',
              order.assignedBodegeroName,
              progress.bodegeroSummary,
              progress.heavyComplete,
            ),
          ],
        ],
      ),
    );
  }

  Widget _roleProgress(
    String role,
    String? name,
    String summary,
    bool complete,
  ) {
    final worker = name?.trim();
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          complete ? LucideIcons.circleCheck : LucideIcons.clock3,
          size: 17,
          color: complete ? _green : _orange,
        ),
        const SizedBox(width: 9),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '$role · ${worker == null || worker.isEmpty ? 'Unassigned' : worker}',
                style: const TextStyle(
                  color: _ink,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                summary,
                style: TextStyle(
                  color: complete ? _green : _muted,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class CashierOrderItemRow extends StatelessWidget {
  const CashierOrderItemRow({
    super.key,
    required this.order,
    required this.item,
  });

  final CustomerOrder order;
  final CustomerOrderItem item;

  @override
  Widget build(BuildContext context) {
    final progress = cashierItemProgress(order, item);
    final quantity = item.quantity == item.quantity.truncateToDouble()
        ? item.quantity.toInt().toString()
        : item.quantity.toString();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.productName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13, color: _ink),
                ),
                const SizedBox(height: 2),
                Text(
                  progress.label,
                  style: TextStyle(
                    fontSize: 11,
                    color: progress.complete ? _green : _orange,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Text(
            'Qty: $quantity',
            style: const TextStyle(fontSize: 13, color: _ink),
          ),
        ],
      ),
    );
  }
}

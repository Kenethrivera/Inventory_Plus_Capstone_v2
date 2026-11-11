import 'package:flutter/material.dart';

import '../logic/inventory_approval.dart';
import '../logic/inventory_controller.dart';

class CashierRequestsPage extends StatefulWidget {
  const CashierRequestsPage({
    super.key,
    required this.controller,
    required this.onOpenRegister,
    required this.onOpenInventory,
  });

  final InventoryController controller;
  final VoidCallback onOpenRegister;
  final VoidCallback onOpenInventory;

  @override
  State<CashierRequestsPage> createState() => _CashierRequestsPageState();
}

class _CashierRequestsPageState extends State<CashierRequestsPage> {
  late final Stream<InventoryApprovalRequest?> _requestStream;

  @override
  void initState() {
    super.initState();
    _requestStream = widget.controller.streamDiscountApproval();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: const Color(0xFFF7F5F3),
    body: SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(32, 32, 32, 56),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 960),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 16,
                runSpacing: 12,
                children: [
                  const Text(
                    'Discount requests',
                    style: TextStyle(
                      fontSize: 26,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF171717),
                    ),
                  ),
                  OutlinedButton.icon(
                    onPressed: widget.onOpenInventory,
                    icon: const Icon(Icons.inventory_2_outlined, size: 17),
                    label: const Text('Inventory'),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              const Text(
                'Track the approval request for your current checkout.',
                style: TextStyle(color: Color(0xFF756F69)),
              ),
              const SizedBox(height: 24),
              StreamBuilder<InventoryApprovalRequest?>(
                stream: _requestStream,
                builder: (context, snapshot) {
                  final request = snapshot.data;
                  if (request == null) {
                    return _card(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Icon(
                            Icons.approval_outlined,
                            size: 32,
                            color: Color(0xFF9A8B80),
                          ),
                          const SizedBox(height: 14),
                          const Text(
                            'No active discount request',
                            style: TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 5),
                          const Text(
                            'Request an approval from Register when a discount needs an admin decision.',
                            style: TextStyle(color: Color(0xFF756F69)),
                          ),
                          const SizedBox(height: 18),
                          FilledButton(
                            onPressed: widget.onOpenRegister,
                            style: FilledButton.styleFrom(
                              backgroundColor: const Color(0xFFC83D08),
                            ),
                            child: const Text('Open Register'),
                          ),
                        ],
                      ),
                    );
                  }

                  final statusColor = switch (request.status) {
                    InventoryApprovalStatus.pending => const Color(0xFFB45309),
                    InventoryApprovalStatus.approved => const Color(0xFF15803D),
                    InventoryApprovalStatus.rejected => const Color(0xFFB91C1C),
                  };
                  return _card(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Expanded(
                              child: Text(
                                'Current discount request',
                                style: TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 11,
                                vertical: 6,
                              ),
                              decoration: BoxDecoration(
                                color: statusColor.withValues(alpha: .10),
                                borderRadius: BorderRadius.circular(999),
                              ),
                              child: Text(
                                request.status.label,
                                style: TextStyle(
                                  color: statusColor,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 18),
                        Text(
                          request.discountMode == 'percentage'
                              ? '${request.discountValue?.toStringAsFixed(0) ?? '0'}% discount'
                              : '₱${request.discountValue?.toStringAsFixed(2) ?? '0.00'} discount',
                          style: const TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        if (request.reason?.trim().isNotEmpty ?? false) ...[
                          const SizedBox(height: 9),
                          Text('Reason: ${request.reason}'),
                        ],
                        if (request.reviewNote?.trim().isNotEmpty ?? false) ...[
                          const SizedBox(height: 9),
                          Text('Admin note: ${request.reviewNote}'),
                        ],
                        const SizedBox(height: 20),
                        OutlinedButton(
                          onPressed: widget.onOpenRegister,
                          child: const Text('Back to Register'),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ],
          ),
        ),
      ),
    ),
  );

  Widget _card({required Widget child}) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(24),
    decoration: BoxDecoration(
      color: Colors.white,
      border: Border.all(color: const Color(0xFFE7E0D9)),
      borderRadius: BorderRadius.circular(16),
    ),
    child: child,
  );
}

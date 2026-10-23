import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:inventory_plus/logic/inventory_approval.dart';

void main() {
  final migration = File(
    'database/phase_2a_inventory_approvals.sql',
  ).readAsStringSync();
  final controller = File(
    'lib/logic/inventory_controller.dart',
  ).readAsStringSync();
  final evidenceMigration = File(
    'database/phase_2a_approval_evidence.sql',
  ).readAsStringSync();
  final evidenceFunction = File(
    'supabase/functions/approval-evidence/index.ts',
  ).readAsStringSync();
  final realtime = File(
    'lib/services/realtime/realtime_sync_service.dart',
  ).readAsStringSync();
  final notificationService = File(
    'lib/notifications/notification_service.dart',
  ).readAsStringSync();
  final notificationFactory = File(
    'lib/notifications/notification_factory.dart',
  ).readAsStringSync();
  final notificationRepository = File(
    'lib/notifications/notification_repository.dart',
  ).readAsStringSync();
  final requesterUi = File('lib/ui/item_detail_page.dart').readAsStringSync();
  final approvalUi = File(
    'lib/ui/approval_center_page.dart',
  ).readAsStringSync();

  String sqlFunction(String name) {
    final start = migration.indexOf('create or replace function public.$name');
    expect(start, greaterThanOrEqualTo(0), reason: '$name must exist');
    final next = migration.indexOf(
      'create or replace function public.',
      start + 40,
    );
    return migration.substring(start, next < 0 ? migration.length : next);
  }

  test('Helper creates Restock request without changing quantity', () {
    final create = sqlFunction('create_inventory_approval_request_v1');
    expect(
      create,
      contains("v_profile.role not in ('helper', 'staff', 'cashier')"),
    );
    expect(create, contains("v_type not in ('restock', 'write_off')"));
    expect(create, isNot(contains('update public.products')));
    expect(create, isNot(contains('insert into public.transaction_history')));
    expect(requesterUi, contains('InventoryApprovalType.restock'));
  });

  test('Cashier creates Write-off request without changing quantity', () {
    final create = sqlFunction('create_inventory_approval_request_v1');
    expect(
      create,
      contains("v_profile.role not in ('helper', 'staff', 'cashier')"),
    );
    expect(create, contains("v_type = 'write_off'"));
    expect(create, isNot(contains('update public.products')));
    expect(requesterUi, contains('InventoryApprovalType.writeOff'));
  });

  test('approval SQL and Dart use live UUID identifier contracts', () {
    expect(
      migration,
      contains('product_id uuid not null references public.products(id)'),
    );
    expect(migration, contains('transaction_id uuid'));
    expect(migration, contains('p_product_id uuid'));
    expect(migration, contains('v_transaction_id uuid'));
    expect(migration, contains('text, text, uuid, numeric, text, text'));
    expect(migration, isNot(contains('request_payload')));
    expect(controller, contains("'p_product_id': productId"));
    expect(controller, isNot(contains('numericProductId')));
  });

  test('new requests require a one-use durable proof image', () {
    expect(evidenceMigration, contains('proof_storage_path text'));
    expect(
      evidenceMigration,
      isNot(contains('proof_storage_path text not null')),
    );
    expect(evidenceMigration, contains('private.approval_evidence_uploads'));
    expect(evidenceMigration, contains('for update'));
    expect(
      evidenceMigration,
      contains("evidence.bucket_id = 'approval_evidence'"),
    );
    expect(
      evidenceMigration,
      contains('delete from private.approval_evidence_uploads'),
    );
    expect(
      controller,
      contains("'p_proof_storage_path': proofStoragePath.trim()"),
    );
  });

  test('evidence uses private storage and scoped signed previews', () {
    expect(evidenceMigration, contains("'approval_evidence',\n  false"));
    expect(
      evidenceMigration,
      contains('inventory_approval_evidence_access_v1'),
    );
    expect(evidenceFunction, contains('SUPABASE_SERVICE_ROLE_KEY'));
    expect(evidenceFunction, contains('createSignedUrl(storagePath, 300)'));
    expect(evidenceFunction, contains(".from('approval_evidence')"));
    expect(controller, isNot(contains('approvalEvidencePublicUrl')));
  });

  test('Approval Center requires proof viewing before review actions', () {
    expect(approvalUi, contains('Approval Center'));
    expect(approvalUi, contains('No proof — legacy request'));
    expect(approvalUi, contains('_viewedRequests.contains(request.id)'));
    expect(approvalUi, contains('fetchApprovalEvidenceUrl(request.id)'));
  });

  test('Admin approves Restock and quantity increases once', () {
    final approve = sqlFunction('approve_inventory_approval_request_v1');
    expect(
      approve,
      contains(
        "when 'restock' then v_product.product_quantity + "
        'v_request.requested_quantity',
      ),
    );
    expect(
      RegExp('update public\\.products').allMatches(approve),
      hasLength(1),
    );
    expect(approve, contains("then 'stock_in'"));
  });

  test('Admin approves Write-off and quantity decreases once', () {
    final approve = sqlFunction('approve_inventory_approval_request_v1');
    expect(
      approve,
      contains(
        'else v_product.product_quantity - v_request.requested_quantity',
      ),
    );
    expect(approve, contains("else 'write_off'"));
    expect(approve, contains('else -v_request.requested_quantity'));
  });

  test('Admin rejection changes status but not inventory quantity', () {
    final reject = sqlFunction('reject_inventory_approval_request_v1');
    expect(reject, contains("set status = 'rejected'"));
    expect(reject, isNot(contains('update public.products')));
    expect(reject, isNot(contains('insert into public.transaction_history')));
  });

  test('duplicate approval cannot apply the mutation twice', () {
    final approve = sqlFunction('approve_inventory_approval_request_v1');
    expect(approve, contains('for update'));
    expect(approve, contains("if v_request.status <> 'pending'"));
    expect(approve, contains("Approval request is already %"));
  });

  test('approval revalidates current available stock under product lock', () {
    final approve = sqlFunction('approve_inventory_approval_request_v1');
    expect(approve, contains('from public.products product'));
    expect(
      RegExp('for update').allMatches(approve).length,
      greaterThanOrEqualTo(2),
    );
    expect(
      approve,
      contains('v_request.requested_quantity > v_product.product_quantity'),
    );
    expect(approve, contains('Write-off conflict'));
  });

  test('wrong role cannot approve or reject', () {
    expect(
      sqlFunction('approve_inventory_approval_request_v1'),
      contains("if v_profile.role <> 'admin'"),
    );
    expect(
      sqlFunction('reject_inventory_approval_request_v1'),
      contains("if v_profile.role <> 'admin'"),
    );
  });

  test('wrong location cannot create or review a request', () {
    expect(
      sqlFunction('create_inventory_approval_request_v1'),
      contains('product.location_id = v_profile.location_id'),
    );
    expect(
      sqlFunction('approve_inventory_approval_request_v1'),
      contains('v_request.location_id <> v_profile.location_id'),
    );
    expect(
      sqlFunction('reject_inventory_approval_request_v1'),
      contains('v_request.location_id <> v_profile.location_id'),
    );
  });

  test('requester receives approved or rejected status update', () {
    expect(
      notificationFactory,
      contains("targetRoles: isPending ? const ['admin'] : [requestedByRole]"),
    );
    expect(
      notificationFactory,
      contains("'recipientId': isPending ? null : requestedById"),
    );
    expect(controller, contains('onApprovalRequestChanged'));
    expect(
      notificationRepository,
      contains('approvalRecipientId != recipientId'),
    );
    expect(
      migration,
      contains('notification.location_id = p_request.location_id::text'),
    );
    expect(migration, contains('p_request.location_id::text, v_target_roles'));
  });

  test('Admin receives pending request through centralized realtime', () {
    expect(realtime, contains("table: 'approval_request_realtime_signals'"));
    expect(realtime, contains('_approvalRequestChangesController.add(null)'));
    expect(controller, contains('.approvalRequestChanges'));
    expect(requesterUi, isNot(contains('onPostgresChanges')));
    expect(approvalUi, isNot(contains('onPostgresChanges')));
  });

  test('notification lifecycle identity does not duplicate requests', () {
    expect(
      notificationService,
      contains(
        "return requestId == null ? null : 'inventory-approval:\$requestId'",
      ),
    );
    expect(notificationFactory, contains("'stage': status"));
    expect(
      migration,
      contains('private.upsert_inventory_approval_notification_v1'),
    );
    expect(
      migration,
      contains(
        "notification.payload ->> 'approvalRequestId' = p_request.id::text",
      ),
    );
  });

  test(
    'approved mutation preserves inventory transaction history behavior',
    () {
      final approve = sqlFunction('approve_inventory_approval_request_v1');
      expect(approve, contains('insert into public.transaction_history'));
      expect(approve, contains("when 'restock' then 'stock_in'"));
      expect(approve, contains("else 'write_off'"));
      expect(approve, contains('v_request.requested_by_id'));
      expect(approve, contains('v_request.requested_by_name'));
      expect(approve, contains("'Approved by ' || v_profile.profile_name"));
    },
  );

  test('approval page cache is bounded and marks snapshots stale', () {
    const key = InventoryApprovalPageKey(
      accountId: '1',
      locationId: 'store-a',
      status: InventoryApprovalStatus.pending,
      page: 1,
    );
    final cache = InventoryApprovalPageCache(maximumEntries: 1);
    cache.write(
      InventoryApprovalPage(
        key: key,
        requests: const [],
        totalCount: 0,
        loadedAt: DateTime(2026, 10, 23),
      ),
    );
    cache.markAllStale();
    expect(cache.read(key)?.stale, isTrue);
    expect(cache.read(key)?.totalPages, 1);
  });
}

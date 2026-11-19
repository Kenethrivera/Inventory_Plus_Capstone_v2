#!/usr/bin/env python3
"""Inventory Plus POS: Helper + Bodegero assignment, responsive web/mobile.

Run from Flutter project root (typically ...-integration):
    python apply_pos_helper_bodegero_assignment.py --check
    python apply_pos_helper_bodegero_assignment.py

IMPORTANT: This patch DOES NOT execute database SQL. Apply the companion
SQL migration in Supabase before launching the updated app for manual
Bodegero assignment. Auto assignment continues to use existing RPC.

- Light-only carts: existing Helper control is unchanged.
- Heavy/mixed carts: side-by-side Helper / Bodegero dropdowns in current footer.
- Heavy-only: Helper selection is disabled; server already removes Helper.
- Manual Bodegero choice saved by new session-validated atomic RPC.
- Existing auto-Bodegero DB trigger remains intact.
- No changes to notifications, auth, inventory valuation, cart positions,
  checkout pricing, web-versus-mobile screens or POS button arrangement.
- Fails closed on unexpected source; creates external backups.
- No Git operations, Flutter analyzer, Flutter tests or DB mutations.
"""

from __future__ import annotations

import argparse
import difflib
from pathlib import Path
import shutil
import sys
import tempfile

MARKER = 'POS_BODEGERO_ASSIGNMENT_V1'
FILES = (
    'lib/logic/helper_assignment.dart',
    'lib/services/staff_presence_service.dart',
    'lib/ui/widgets/helper_assignment_selector.dart',
    'lib/logic/inventory_controller.dart',
    'lib/ui/pos_cart_page.dart',
)


def replace_one(text: str, before: str, after: str, what: str) -> str:
    count = text.count(before)
    if count != 1:
        raise RuntimeError(f'{what}: expected one anchor, found {count}')
    return text.replace(before, after, 1)


def patch_helpers(s: str) -> str:
    s = replace_one(s,
        '  required Duration activeTimeout,\n}) {\n  final normalizedLocation = locationId.trim();',
        '  required Duration activeTimeout,\n  String targetRole = \'helper\',\n}) {\n  final normalizedLocation = locationId.trim();',
        'eligible staff role parameter')
    s = replace_one(s, "        role != 'helper' ||\n", "        role != targetRole ||\n", 'eligible staff role filter')
    return s


def patch_presence(s: str) -> str:
    anchor = '''  List<HelperAssignmentCandidate> get eligibleHelpersForAssignment =>
      eligibleHelpersFromPresence(
        presenceRows: _activeStaff,
        locationId: locationId,
        now: DateTime.now().toUtc(),
        activeTimeout: activeTimeout,
      );'''
    add = '''  // POS_BODEGERO_ASSIGNMENT_V1: same location/presence freshness as Helper.
  List<HelperAssignmentCandidate> get eligibleBodegerosForAssignment =>
      eligibleHelpersFromPresence(
        presenceRows: _activeStaff,
        locationId: locationId,
        now: DateTime.now().toUtc(),
        activeTimeout: activeTimeout,
        targetRole: 'bodegero',
      );'''
    return replace_one(s, anchor, anchor+'\n'+add, 'presence eligibility getter')


def patch_selector(s: str) -> str:
    s = replace_one(s,
        '''    required this.onChanged,
  });''',
        '''    required this.onChanged,
    this.roleName = 'Helper',
    this.showInlineLabel = true,
    this.compact = false,
    this.disabledLabel,
  });''',
        'selector constructor')
    s = replace_one(s,
        '''  final ValueChanged<String?>? onChanged;
''',
        '''  final ValueChanged<String?>? onChanged;
  // POS_BODEGERO_ASSIGNMENT_V1: opt-in role-neutral selector presentation.
  final String roleName;
  final bool showInlineLabel;
  final bool compact;
  final String? disabledLabel;
''',
        'selector properties')
    s = replace_one(s,
        "                    subtitle: 'Least-loaded available Helper',",
        "                    subtitle: 'Least-loaded available ${widget.roleName}',",
        'selector auto option role')
    old = '''        const Text(
          'Helper packs',
          style: TextStyle(
            color: _muted,
            fontSize: 12,
            fontWeight: FontWeight.w700,
            fontFamily: _fontFamily,
          ),
        ),
        const SizedBox(width: 12),'''
    new = '''        if (widget.showInlineLabel) ...[
          const Text(
            'Helper packs',
            style: TextStyle(
              color: _muted,
              fontSize: 12,
              fontWeight: FontWeight.w700,
              fontFamily: _fontFamily,
            ),
          ),
          const SizedBox(width: 12),
        ],'''
    s = replace_one(s, old, new, 'selector optional inline label')
    s = replace_one(s,
        '''                  label: selectedHelper == null
                      ? 'Auto-assign Helper, least loaded'
                      : 'Assigned Helper ${selectedHelper.name}',''',
        '''                  label: selectedHelper == null
                      ? '${widget.roleName}: auto-assign least loaded'
                      : 'Assigned ${widget.roleName} ${selectedHelper.name}',''',
        'selector accessibility role')
    old = '''                            Container(
                              width: 28,
                              height: 28,
                              decoration: BoxDecoration(
                                color: highlighted
                                    ? const Color(0xFFFBE2D4)
                                    : Colors.white,
                                borderRadius: BorderRadius.circular(7),
                              ),
                              child: Icon(
                                selectedHelper == null
                                    ? LucideIcons.zap
                                    : LucideIcons.userRound,
                                size: 15,
                                color: _accent,
                              ),
                            ),
                            const SizedBox(width: 10),'''
    new = '''                            if (!widget.compact) ...[
                              Container(
                                width: 28,
                                height: 28,
                                decoration: BoxDecoration(
                                  color: highlighted
                                      ? const Color(0xFFFBE2D4)
                                      : Colors.white,
                                  borderRadius: BorderRadius.circular(7),
                                ),
                                child: Icon(
                                  selectedHelper == null
                                      ? LucideIcons.zap
                                      : LucideIcons.userRound,
                                  size: 15,
                                  color: _accent,
                                ),
                              ),
                              const SizedBox(width: 10),
                            ],'''
    s = replace_one(s, old, new, 'compact selector icon spacing')
    s = replace_one(s,
        '''                                selectedHelper == null
                                    ? 'Auto-assign — least loaded'
                                    : '${selectedHelper.name} — '
                                          '${_activeOrderLabel(selectedCount)}',''',
        '''                                !widget.enabled && widget.disabledLabel != null
                                    ? widget.disabledLabel!
                                    : selectedHelper == null
                                        ? (widget.compact
                                            ? '${widget.roleName}: Auto'
                                            : 'Auto-assign — least loaded')
                                        : (widget.compact
                                            ? '${widget.roleName}: ${selectedHelper.name}'
                                            : '${selectedHelper.name} — '
                                              '${_activeOrderLabel(selectedCount)}'),''',
        'compact selector role text')
    return s


def patch_controller(s: str) -> str:
    start = s.find('  Future<CustomerOrder?> createCustomerOrder(')
    end = s.find('  Future<void> cancelOrder(', start)
    if start == -1 or end == -1:
        raise RuntimeError('checkout controller method boundaries not found')
    head, section, tail = s[:start], s[start:end], s[end:]
    section = replace_one(section,
        '    HelperAssignmentCandidate? assignedHelper,\n  }) async {',
        '    HelperAssignmentCandidate? assignedHelper,\n    HelperAssignmentCandidate? assignedBodegero,\n  }) async {',
        'checkout assigned bodegero argument')
    section = replace_one(section,
        '''      final response = await supabase.rpc(
        'create_customer_order_v2',
        params: <String, dynamic>{''',
        '''      // POS_BODEGERO_ASSIGNMENT_V1: use existing checkout RPC for auto;
      // opt into the guarded atomic RPC only for explicit manual selection.
      final rpcParams = <String, dynamic>{''',
        'checkout RPC parameters')
    section = replace_one(section,
        '''          'p_change_amount': changeAmount,
        },
      );
      return CustomerOrder.fromJson''',
        '''          'p_change_amount': changeAmount,
      };
      if (assignedBodegero != null) {
        rpcParams['p_selected_bodegero_id'] = assignedBodegero.id;
      }
      final response = await supabase.rpc(
        assignedBodegero == null
            ? 'create_customer_order_v2'
            : 'create_customer_order_with_bodegero_v1',
        params: rpcParams,
      );
      return CustomerOrder.fromJson''',
        'checkout RPC branch')
    return head+section+tail


def patch_pos(s: str) -> str:
    s = replace_one(s,
        "import '../logic/helper_assignment.dart';\n",
        "import '../logic/helper_assignment.dart';\nimport '../logic/staff_availability.dart';\n",
        'POS workload import')
    s = replace_one(s,
        '  String? _selectedHelperId;\n',
        '  String? _selectedHelperId;\n  String? _selectedBodegeroId; // POS_BODEGERO_ASSIGNMENT_V1\n',
        'POS selected Bodegero state')
    s = replace_one(s,
        '''      final assignedHelper = _soloMode ? null : _selectedEligibleHelper();
''',
        '''      final assignedHelper = _soloMode || !_cartHasLightItems
          ? null : _selectedEligibleHelper();
      final assignedBodegero = _soloMode || !_cartHasHeavyItems
          ? null : _selectedEligibleBodegero();
      if (_cartHasHeavyItems && _selectedBodegeroId != null &&
          assignedBodegero == null) {
        throw StateError(
          'Selected Bodegero is no longer available. Select Auto-assign or another available Bodegero.',
        );
      }
''',
        'POS checkout staff selection')
    s = replace_one(s,
        '''            assignedHelper: assignedHelper,
          );''',
        '''            assignedHelper: assignedHelper,
            assignedBodegero: assignedBodegero,
          );''',
        'POS checkout explicit Bodegero parameter')
    s = replace_one(s,
        '''        _selectedHelperId = null;
''',
        '''        _selectedHelperId = null;
        _selectedBodegeroId = null;
''',
        'POS successful checkout resets selection')
    anchor = '''  Future<void> _completeOrderFlow(
'''
    add = '''  // POS_BODEGERO_ASSIGNMENT_V1: use product handling tags in the cart,
  // not a string/name heuristic or the order's not-yet-created line items.
  bool get _cartHasHeavyItems => widget.controller.allItems.any(
    (item) => item.requiresLoading && (_cart[item.id] ?? 0) > 0,
  );

  bool get _cartHasLightItems => widget.controller.allItems.any(
    (item) => !item.requiresLoading && (_cart[item.id] ?? 0) > 0,
  );

  List<HelperAssignmentCandidate> _eligibleBodegeros() {
    final candidates = widget.presenceService?.eligibleBodegerosForAssignment;
    if (candidates == null || candidates.isEmpty) {
      return const <HelperAssignmentCandidate>[];
    }
    final workloads = activeLoadingWorkloads(widget.controller.currentOrders);
    final ranked = candidates.toList();
    ranked.sort((a, b) {
      final byLoad = (workloads[a.id] ?? 0).compareTo(workloads[b.id] ?? 0);
      if (byLoad != 0) return byLoad;
      final aId = BigInt.tryParse(a.id);
      final bId = BigInt.tryParse(b.id);
      if (aId != null && bId != null) return aId.compareTo(bId);
      return a.id.compareTo(b.id);
    });
    return List<HelperAssignmentCandidate>.unmodifiable(ranked);
  }

  HelperAssignmentCandidate? _selectedEligibleBodegero() {
    final selectedId = _selectedBodegeroId;
    if (selectedId == null) return null;
    for (final worker in _eligibleBodegeros()) {
      if (worker.id == selectedId) return worker;
    }
    return null;
  }

'''
    s = replace_one(s,anchor,add+anchor,'POS staff helper methods')
    start = s.find('  Widget _buildHelperAssignmentControl() {')
    end = s.find('\n}\n\nclass _DashedDivider', start)
    if start == -1 or end == -1 or s.count('  Widget _buildHelperAssignmentControl() {') != 1:
        raise RuntimeError('POS assignment footer method boundary changed')
    old = s[start:end]
    if 'return HelperAssignmentSelector(' not in old or 'activePreparationWorkloads' not in old:
        raise RuntimeError('POS assignment footer no longer matches supported implementation')
    new = '''  Widget _buildHelperAssignmentControl() {
    final presenceService = widget.presenceService;
    final needsBodegero = _cartHasHeavyItems;
    final hasLightItems = _cartHasLightItems;

    if (presenceService == null && !needsBodegero) {
      return const HelperAssignmentSelector(
        helpers: <HelperAssignmentCandidate>[],
        workloads: <String, int>{},
        selectedHelperId: null,
        enabled: false,
        onChanged: null,
      );
    }

    return StreamBuilder<List<CustomerOrder>>(
      stream: widget.controller.orderSnapshots,
      initialData: widget.controller.currentOrders,
      builder: (context, orderSnapshot) {
        final orders = orderSnapshot.data ?? widget.controller.currentOrders;
        if (presenceService == null) {
          return _buildStaffAssignmentPair(
            helpers: const <HelperAssignmentCandidate>[],
            bodegeros: const <HelperAssignmentCandidate>[],
            helperWorkloads: const <String, int>{},
            bodegeroWorkloads: const <String, int>{},
            hasLightItems: hasLightItems,
          );
        }
        return AnimatedBuilder(
          animation: presenceService,
          builder: (context, _) {
            final helpers = rankHelpersByActiveWorkload(
              helpers: presenceService.eligibleHelpersForAssignment,
              orders: orders,
            );
            if (!needsBodegero) {
              // Preserve the entire existing light-only POS presentation.
              return HelperAssignmentSelector(
                helpers: helpers,
                workloads: activePreparationWorkloads(orders),
                selectedHelperId: _selectedHelperId,
                enabled: !_isProcessingCart,
                onChanged: (helperId) {
                  if (_selectedHelperId == helperId) return;
                  setState(() => _selectedHelperId = helperId);
                },
              );
            }
            final bodegeroWorkloads = activeLoadingWorkloads(orders);
            final bodegeros = presenceService.eligibleBodegerosForAssignment
                .toList();
            bodegeros.sort((a, b) {
              final load = (bodegeroWorkloads[a.id] ?? 0)
                  .compareTo(bodegeroWorkloads[b.id] ?? 0);
              if (load != 0) return load;
              final aId = BigInt.tryParse(a.id);
              final bId = BigInt.tryParse(b.id);
              if (aId != null && bId != null) return aId.compareTo(bId);
              return a.id.compareTo(b.id);
            });
            return _buildStaffAssignmentPair(
              helpers: helpers,
              bodegeros: bodegeros,
              helperWorkloads: activePreparationWorkloads(orders),
              bodegeroWorkloads: bodegeroWorkloads,
              hasLightItems: hasLightItems,
            );
          },
        );
      },
    );
  }

  // Only the existing staff-assignment footer row changes on heavy carts.
  Widget _buildStaffAssignmentPair({
    required List<HelperAssignmentCandidate> helpers,
    required List<HelperAssignmentCandidate> bodegeros,
    required Map<String, int> helperWorkloads,
    required Map<String, int> bodegeroWorkloads,
    required bool hasLightItems,
  }) {
    final helper = HelperAssignmentSelector(
      key: const ValueKey('pos-dual-helper'),
      helpers: hasLightItems ? helpers : const <HelperAssignmentCandidate>[],
      workloads: helperWorkloads,
      selectedHelperId: hasLightItems ? _selectedHelperId : null,
      enabled: hasLightItems && !_isProcessingCart &&
          widget.presenceService != null,
      onChanged: hasLightItems ? (id) {
        if (_selectedHelperId != id) setState(() => _selectedHelperId = id);
      } : null,
      roleName: 'Helper',
      showInlineLabel: false,
      compact: true,
      disabledLabel: hasLightItems ? null : 'Helper: N/A',
    );
    final bodegero = HelperAssignmentSelector(
      key: const ValueKey('pos-dual-bodegero'),
      helpers: bodegeros,
      workloads: bodegeroWorkloads,
      selectedHelperId: _selectedBodegeroId,
      enabled: !_isProcessingCart && widget.presenceService != null,
      onChanged: (id) {
        if (_selectedBodegeroId != id) {
          setState(() => _selectedBodegeroId = id);
        }
      },
      roleName: 'Bodegero',
      showInlineLabel: false,
      compact: true,
    );

    return LayoutBuilder(builder: (context, constraints) {
      if (constraints.maxWidth < 300) {
        // Very narrow panels: avoid overflowing either dropdown.
        return Column(children: [
          helper,
          const SizedBox(height: 8),
          bodegero,
        ]);
      }
      return Row(children: [
        Expanded(child: helper),
        const SizedBox(width: 8),
        Expanded(child: bodegero),
      ]);
    });
  }
'''
    s = s[:start] + new + s[end:]
    return s


def build_patches(files: dict[str, str]) -> dict[str, str]:
    operations = (patch_helpers,patch_presence,patch_selector,patch_controller,patch_pos)
    return {path: fn(files[path]) for path, fn in zip(FILES, operations)}


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--check', action='store_true', help='validate without changing files')
    args = p.parse_args()
    paths = {name: Path(name) for name in FILES}
    for name, path in paths.items():
        if not path.is_file():
            raise RuntimeError(f'missing {name}; run from the Flutter project root')

    current = {name: path.read_text(encoding='utf-8-sig') for name,path in paths.items()}
    if MARKER in current['lib/ui/pos_cart_page.dart']:
        raise RuntimeError('patch already present; refusing duplicate application')
    if any(MARKER in content for key,content in current.items() if key!='lib/ui/pos_cart_page.dart'):
        raise RuntimeError('partial patch marker found; inspect before retrying')

    updated = build_patches(current)
    if args.check:
        for name in FILES:
            print(f'[READY] {name}: {len(current[name].splitlines())} -> {len(updated[name].splitlines())} lines')
        print('[CHECK OK] local anchors compatible. No files changed.')
        return 0

    backup_dir = Path(tempfile.mkdtemp(prefix='inventory_plus_pos_bodegero_backup_'))
    for name, path in paths.items():
        dest = backup_dir/name
        dest.parent.mkdir(parents=True,exist_ok=True)
        shutil.copy2(path,dest)
    try:
        for name, path in paths.items():
            # Write via a local sibling temporary file before atomic replacement.
            pending = path.with_name(path.name + '.bodegero-patch.tmp')
            try:
                pending.write_text(updated[name], encoding='utf-8', newline='\n')
                pending.replace(path)
            finally:
                if pending.exists():
                    pending.unlink()
    except Exception:
        for name,path in paths.items():
            shutil.copy2(backup_dir/name,path)
        raise

    print('[OK] POS Helper/Bodegero dropdown patch applied.')
    print('[OK] Light-only Helper UI unchanged; heavy carts use responsive dual selectors.')
    print('[IMPORTANT] Apply companion SQL migration BEFORE manual Bodegero checkout.')
    print('[IMPORTANT] SQL was NOT executed by this script.')
    print(f'[BACKUP] {backup_dir}')
    print('Review: git diff -- lib/logic lib/services/staff_presence_service.dart lib/ui/pos_cart_page.dart lib/ui/widgets/helper_assignment_selector.dart')
    return 0

if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except Exception as e:
        print(f'[SAFE STOP] {e}', file=sys.stderr)
        raise SystemExit(1)

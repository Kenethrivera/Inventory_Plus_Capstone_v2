#!/usr/bin/env python3
"""Inventory Plus / Helper picking UI parity patch.

Run from the repository root on Windows:
    python .\apply_helper_desktop_picking_layout.py

Latest source target: lib/ui/order_queue_page.dart, class OrderChecklistPage.
- Desktop (>=900 logical px): Bodegero-style 2-column store map / walking-order scan list.
- Mobile/tablet (<900 logical px): unchanged mobile checklist content and behavior.
- Reuses existing Helper QR scanning, persisted picking state, mixed-order rules,
  order preparation, 2D/3D selection and location highlighting.
- No backend, model, Supabase, Git, Flutter analyzer or tests are changed/run.
- Aborts safely when the expected old desktop method is not present.
"""

from pathlib import Path
import difflib
import shutil
import sys
import tempfile

TARGET = Path('lib/ui/order_queue_page.dart')
MARKER = 'HELPER_DESKTOP_PICKING_LAYOUT_V2'
CLASS_START = 'class _OrderChecklistPageState extends State<OrderChecklistPage> {'
NEXT_CLASS = '\nclass _ChecklistItemCard extends StatelessWidget {'
METHOD_START = '  @override\n  Widget build(BuildContext context) {'

DESKTOP_METHOD = r'''  // HELPER_DESKTOP_PICKING_LAYOUT_V2_START
  // UI-ONLY parity: Desktop follows Bodegero's map-left / work-list-right
  // composition, but every Helper pick, scan, and finish action is reused
  // from the existing mobile implementation. No backend behavior changed.
  Widget _buildDesktopPickingChecklist(BuildContext context) {
    final sharedProgress = OrderWorkProgress.fromOrder(order);
    final walkingItems = _walkingOrderItems();
    final pickStopMarkers = <PickStopMarker>[];
    for (var i = 0; i < walkingItems.length; i++) {
      final locationId =
          controller.findAnyItemById(walkingItems[i].productId)?.locationId;
      if (locationId != null && locationId.isNotEmpty) {
        pickStopMarkers.add(
          PickStopMarker(
            locationId: locationId,
            number: i + 1,
            label: _itemLocation(walkingItems[i]),
          ),
        );
      }
    }

    final pickedCount = workItems
        .where((item) => pickedItems.contains(item.productId))
        .length;
    final remaining = workItems.length - pickedCount;
    final nextItems = walkingItems.where(
      (item) => !pickedItems.contains(item.productId),
    );
    final highlightedProductId = _focusedProductId ??
        (nextItems.isEmpty ? null : nextItems.first.productId);
    final highlightedLocationId = highlightedProductId == null
        ? null
        : controller.findAnyItemById(highlightedProductId)?.locationId;

    return Scaffold(
      backgroundColor: const Color(0xFFF6F5F2),
      body: Column(
        children: [
          // Desktop order heading matches the Bodegero checklist layout.
          Container(
            width: double.infinity,
            color: Colors.white,
            padding: const EdgeInsets.fromLTRB(40, 22, 40, 22),
            child: Row(
              children: [
                IconButton(
                  tooltip: 'Back to queue',
                  onPressed: onBack,
                  icon: const Icon(LucideIcons.arrowLeft,
                      color: _helperInk),
                ),
                const SizedBox(width: 18),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _shortOrderId(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: _helperInk,
                          fontSize: 25,
                          fontWeight: FontWeight.w800,
                          fontFamily: _fontFam,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        sharedProgress.isMixed
                            ? 'Bring light items to loading area'
                            : 'Deliver to checkout counter',
                        maxLines: 2,
                        style: const TextStyle(
                          color: _helperMuted,
                          fontSize: 16,
                          fontFamily: _fontFam,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Text(
                  '$pickedCount/${workItems.length}',
                  style: const TextStyle(
                    color: _helperInk,
                    fontSize: 23,
                    fontWeight: FontWeight.w800,
                    fontFamily: _fontFam,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(32, 28, 32, 36),
              children: [
                Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 1600),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Container(
                            padding: const EdgeInsets.all(24),
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Wrap(
                                  alignment: WrapAlignment.spaceBetween,
                                  crossAxisAlignment:
                                      WrapCrossAlignment.center,
                                  spacing: 12,
                                  runSpacing: 12,
                                  children: [
                                    const Text(
                                      'Store map · light item locations',
                                      style: TextStyle(
                                        color: _helperInk,
                                        fontSize: 20,
                                        fontWeight: FontWeight.w800,
                                        fontFamily: _fontFam,
                                      ),
                                    ),
                                    Container(
                                      padding: const EdgeInsets.all(4),
                                      decoration: BoxDecoration(
                                        color: const Color(0xFFEDEBE6),
                                        borderRadius: BorderRadius.circular(10),
                                      ),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          for (final style in MapViewStyle.values)
                                            InkWell(
                                              onTap: () => setState(
                                                  () => _mobileMapStyle = style),
                                              borderRadius:
                                                  BorderRadius.circular(7),
                                              child: Container(
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                  horizontal: 12,
                                                  vertical: 8,
                                                ),
                                                decoration: BoxDecoration(
                                                  color: _mobileMapStyle == style
                                                      ? Colors.white
                                                      : Colors.transparent,
                                                  borderRadius:
                                                      BorderRadius.circular(7),
                                                ),
                                                child: Text(
                                                  style == MapViewStyle.twoD
                                                      ? '2D plan'
                                                      : '3D view',
                                                  style: TextStyle(
                                                    color: _mobileMapStyle == style
                                                        ? _helperInk
                                                        : _helperMuted,
                                                    fontFamily: _fontFam,
                                                    fontWeight:
                                                        _mobileMapStyle == style
                                                            ? FontWeight.w700
                                                            : FontWeight.w500,
                                                    fontSize: 13,
                                                  ),
                                                ),
                                              ),
                                            ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 20),
                                SizedBox(
                                  height: 530,
                                  child: controller.storeLayout.isEmpty
                                      ? const Center(
                                          child: Text(
                                            'Store map unavailable.',
                                            style: TextStyle(
                                              color: _helperMuted,
                                              fontFamily: _fontFam,
                                            ),
                                          ),
                                        )
                                      : StoreMap(
                                          controller: controller,
                                          mode: MapMode.view,
                                          viewStyle: _mobileMapStyle,
                                          highlightId: highlightedLocationId,
                                          pickStopMarkers: pickStopMarkers,
                                          showProductCounts: false,
                                          showItemPopup: false,
                                          showZoomControls: true,
                                          compactZoomControls: true,
                                          miniZoomControls: true,
                                          zoomAccentColor: _helperOrange,
                                          showMobileToolbar: false,
                                          itemAssignmentEnabled: false,
                                          fitEntireMap: true,
                                        ),
                                ),
                                if (_mobileMapStyle == MapViewStyle.threeD &&
                                    pickStopMarkers.isNotEmpty) ...[
                                  const SizedBox(height: 12),
                                  Wrap(
                                    spacing: 8,
                                    runSpacing: 8,
                                    children: [
                                      for (final marker in pickStopMarkers)
                                        Container(
                                          padding: const EdgeInsets.symmetric(
                                              horizontal: 10, vertical: 7),
                                          decoration: BoxDecoration(
                                            color: const Color(0xFFF6F5F2),
                                            borderRadius:
                                                BorderRadius.circular(18),
                                          ),
                                          child: Text(
                                            '${marker.number}. ${marker.label ?? 'Pick stop'}',
                                            maxLines: 2,
                                            style: const TextStyle(
                                              fontFamily: _fontFam,
                                              color: _helperInk,
                                              fontSize: 12,
                                            ),
                                          ),
                                        ),
                                    ],
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(width: 24),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              const Text(
                                'Pick list · in walking order',
                                style: TextStyle(
                                  color: _helperInk,
                                  fontSize: 21,
                                  fontWeight: FontWeight.w800,
                                  fontFamily: _fontFam,
                                ),
                              ),
                              const SizedBox(height: 8),
                              const Text(
                                'Tap a product to highlight its location, '
                                'then scan its shelf QR to verify the item.',
                                style: TextStyle(
                                  color: _helperMuted,
                                  fontSize: 12,
                                  fontFamily: _fontFam,
                                ),
                              ),
                              const SizedBox(height: 16),
                              if (sharedProgress.isMixed) ...[
                                Container(
                                  padding: const EdgeInsets.all(14),
                                  decoration: BoxDecoration(
                                    color: Colors.white,
                                    borderRadius: BorderRadius.circular(12),
                                    border: Border.all(color: _helperLine),
                                  ),
                                  child: Text(
                                    'Shared order · Bodegero: '
                                    '${sharedProgress.bodegeroSummary}',
                                    style: const TextStyle(
                                      color: _helperInk,
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600,
                                      fontFamily: _fontFam,
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 16),
                              ],
                              for (var index = 0;
                                  index < walkingItems.length;
                                  index++)
                                // Same scanning/verifying card as mobile.
                                _buildMobilePickCard(
                                  context,
                                  walkingItems[index],
                                  index + 1,
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          // Persistent action mirrors mobile's enabled/disabled and mixed-order
          // rules; no change to _finishLightWork, _markPrepared or RPC calls.
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(32, 14, 32, 20),
            decoration: const BoxDecoration(
              color: Colors.white,
              border: Border(top: BorderSide(color: _helperLine)),
            ),
            child: SafeArea(
              top: false,
              child: SizedBox(
                width: double.infinity,
                height: 54,
                child: FilledButton(
                  onPressed: remaining == 0 && !_isSubmittingPreparation
                      ? () => _finishLightWork(context)
                      : null,
                  style: FilledButton.styleFrom(
                    backgroundColor: _helperOrange,
                    disabledBackgroundColor: const Color(0xFFE9B79F),
                    disabledForegroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  child: Text(
                    order.status == 'prepared'
                        ? 'Order ready · Back to queue'
                        : _isSubmittingPreparation
                            ? 'Saving preparation…'
                            : remaining == 0
                                ? order.items.any(
                                            (item) => item.requiresLoading) &&
                                        order.loadingVerifiedAt == null
                                    ? 'Finish light items'
                                    : 'Finish preparing'
                                : 'Scan $remaining more to finish',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                      fontFamily: _fontFam,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
  // HELPER_DESKTOP_PICKING_LAYOUT_V2_END

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, constraints) {
          // Smaller laptops and tablets use the existing stacked mobile
          // composition instead of squeezing the map and scan list together.
          if (constraints.maxWidth < 900) {
            return _buildMobileChecklist(context);
          }
          return _buildDesktopPickingChecklist(context);
        },
      );
'''


def main() -> None:
    if not TARGET.is_file():
        raise RuntimeError(f'Cannot find {TARGET}. Run from Inventory Plus repository root.')
    current = TARGET.read_text(encoding='utf-8-sig')
    if MARKER in current:
        raise RuntimeError('Patch marker already found. Refusing to apply twice.')
    class_at = current.find(CLASS_START)
    if class_at < 0 or current.count(CLASS_START) != 1:
        raise RuntimeError('Could not uniquely find Helper checklist state class.')
    next_class = current.find(NEXT_CLASS, class_at)
    if next_class < 0 or current.count(NEXT_CLASS) != 1:
        raise RuntimeError('Could not uniquely find _ChecklistItemCard boundary.')
    section = current[class_at:next_class]
    start_relative = section.rfind(METHOD_START)
    if start_relative < 0:
        raise RuntimeError('Could not locate Helper checklist desktop build method.')
    start = class_at + start_relative
    old_tail = current[start:next_class]

    # Expected existing latest-main desktop branch; if it is not there,
    # stop rather than clobber other developers' changes or new business logic.
    required = [
        'if (MediaQuery.sizeOf(context).width < 600)',
        'return _buildMobileChecklist(context);',
        "'#ORD-$shortId'",
        'Widget build(BuildContext context)',
        '_ChecklistItemCard(',
        '_finishLightWork(context)',
        'onScanTap:',
    ]
    missing = [x for x in required if x not in old_tail]
    if missing:
        raise RuntimeError('Old desktop checklist differs from expected version. '
                           'No changes made. Missing: ' + ', '.join(missing))
    if 'Widget _buildDesktopPickingChecklist(' in current:
        raise RuntimeError('A custom desktop checklist already exists. No changes made.')
    # This replacement should never alter mobile helpers/scanning code.
    earlier = current[:start]
    updated = earlier + DESKTOP_METHOD + '}\n' + current[next_class:]
    if updated.count('class _OrderChecklistPageState') != 1 or updated.count(
            'Widget _buildMobilePickCard(') != 1:
        raise RuntimeError('Unexpected duplicate classes; refusing to write.')
    if updated.count('_openScannerToCheckoff(') < 2:
        raise RuntimeError('Scanner callback references not preserved.')

    backup_dir = Path(tempfile.mkdtemp(prefix='inventory_plus_helper_layout_backup_'))
    backup = backup_dir / 'order_queue_page.dart'
    shutil.copy2(TARGET, backup)
    try:
        TARGET.write_text(updated, encoding='utf-8', newline='\n')
    except Exception:
        shutil.copy2(backup, TARGET)
        raise
    print('[OK] Updated only Helper OrderChecklistPage desktop presentation.')
    print('[OK] Mobile pick list, QR verification and restock workflows preserved.')
    print('[OK] Responsive: 2 columns at >=900px, stacked below 900px.')
    print(f'[BACKUP] {backup}')
    print(f'[FILE] {TARGET} ({len(current.splitlines())} -> {len(updated.splitlines())} lines)')
    print('Review: git diff --check; git diff -- lib/ui/order_queue_page.dart')
    print('No Flutter analyzer, tests, Git commit or push were run.')


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        print(f'[SAFE STOP] {error}', file=sys.stderr)
        sys.exit(1)

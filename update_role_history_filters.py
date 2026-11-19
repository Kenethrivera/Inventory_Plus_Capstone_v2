"""Inventory Plus: Cashier pending filter + Bodegero Cashier-style toolbar.

Run from repository root: python .\\update_role_history_filters.py

Changes local source only. It never deploys SQL, runs tests, commits, or pushes.
Creates backups outside the repository and a SQL apply file for review.
"""

from pathlib import Path
import re
import shutil
import tempfile
import sys

ROOT = Path.cwd()
STAFF = ROOT / 'lib/ui/staff_history_page.dart'
BODEGERO = ROOT / 'lib/ui/bodegero_history_page.dart'
FUNCTION = ROOT / 'supabase/schemas/public/functions/history_page_v1.sql'
APPLY = ROOT / 'database/CASHIER_PENDING_HISTORY_FILTER_APPLY.sql'

class PatchMismatch(RuntimeError):
    pass


def exact(text, old, new, description):
    count = text.count(old)
    if count != 1:
        raise PatchMismatch(f'{description}: expected exactly one original block, found {count}. File left unchanged.')
    return text.replace(old, new, 1)


def pattern_once(text, pattern, replacement, description):
    result, count = re.subn(pattern, lambda _: replacement, text, count=1, flags=re.M | re.S)
    if count != 1:
        raise PatchMismatch(f'{description}: expected one block, found {count}. File left unchanged.')
    return result


def update_staff(source):
    source = exact(
        source,
        ": const ['All', 'Created', 'Completed', 'Cancelled'];",
        ": const ['All', 'Pending', 'Completed', 'Cancelled'];",
        'Cashier status labels',
    )
    # Keep Orders as the only visible tab; leave existing Restocks domain code
    # untouched to avoid accidental changes to the separate restock workflows.
    source = exact(
        source,
        '            if (!_isHelper) _buildSectionSelector(expanded: isNarrow),\n',
        '',
        'Remove redundant Cashier Orders/Restocks switch',
    )
    return source


BODEGERO_SEARCH = '''  // HISTORY_FILTER_VISUAL_PARITY: Cashier-style search; Bodegero behavior unchanged.
  Widget _searchField() => SizedBox(
    height: 36,
    child: TextField(
      controller: _searchController,
      onChanged: (_) {
        _searchDebounce?.cancel();
        _searchDebounce = Timer(const Duration(milliseconds: 300), () {
          if (mounted) _setPage(1);
        });
      },
      style: const TextStyle(fontSize: 12, color: _ink),
      decoration: InputDecoration(
        hintText: 'Search order, truck, or product',
        hintStyle: const TextStyle(fontSize: 12, color: Color(0xFF94A3B8)),
        prefixIcon: const Icon(LucideIcons.search, size: 17, color: _muted),
        prefixIconConstraints: const BoxConstraints(minWidth: 36, minHeight: 36),
        suffixIcon: _searchController.text.isEmpty
            ? null
            : IconButton(
                tooltip: 'Clear search',
                icon: const Icon(Icons.close, size: 16),
                onPressed: () {
                  _searchDebounce?.cancel();
                  _searchController.clear();
                  _setPage(1);
                },
              ),
        filled: true,
        fillColor: const Color(0xFFFAF8F6),
        contentPadding: EdgeInsets.zero,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: _line),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: _line),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: _orange),
        ),
      ),
    ),
  );

'''

BODEGERO_TOOLBAR = '''  // HISTORY_FILTER_VISUAL_PARITY: Match Cashier toolbar DESIGN only.
  // Bodegero still uses its own all-time/date/status filters and _load().
  Widget _historyFilters() => Container(
    padding: const EdgeInsets.all(9),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(11),
      border: Border.all(color: _line),
    ),
    child: LayoutBuilder(
      builder: (context, constraints) {
        final narrow = constraints.maxWidth < 600;
        final groups = <Widget>[
          _BodegeroHistorySegments(
            expanded: narrow,
            options: const ['All time', 'Daily', 'Weekly', 'Monthly'],
            selected: !_periodActive ? 'All time' : _period.mode.label,
            onSelected: (value) {
              if (value == 'All time') {
                setState(() {
                  _periodActive = false;
                  _page = 1;
                  _history = _load();
                });
                return;
              }
              final mode = switch (value) {
                'Daily' => HistoryPeriodMode.daily,
                'Weekly' => HistoryPeriodMode.weekly,
                _ => HistoryPeriodMode.monthly,
              };
              _changePeriod(_period.withMode(mode));
            },
          ),
          HistoryPeriodControls(
            selection: _period,
            onChanged: _changePeriod,
            fullWidth: narrow,
          ),
          _BodegeroHistorySegments(
            expanded: narrow,
            options: const ['All', 'Waiting', 'Ready', 'Completed', 'Cancelled'],
            selected: _statusFilter,
            onSelected: _changeStatus,
          ),
        ];

        if (narrow) {
          // No horizontal scrolling or clipped five-option status selector.
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < groups.length; i++) ...[
                if (i != 0) const SizedBox(height: 9),
                SizedBox(width: double.infinity, child: groups[i]),
              ],
              const SizedBox(height: 10),
              _searchField(),
            ],
          );
        }
        if (constraints.maxWidth >= 1020) {
          return Row(
            children: [
              for (var i = 0; i < groups.length; i++) ...[
                if (i != 0) const SizedBox(width: 8),
                groups[i],
              ],
              const SizedBox(width: 8),
              Expanded(child: _searchField()),
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(spacing: 9, runSpacing: 8, children: groups),
            const SizedBox(height: 8),
            _searchField(),
          ],
        );
      },
    ),
  );

'''

BODEGERO_SEGMENTS = '''
// HISTORY_FILTER_VISUAL_PARITY: Cashier's segmented visual design, Bodegero options.
// All time / Waiting / Ready retain their existing query semantics.
class _BodegeroHistorySegments extends StatelessWidget {
  const _BodegeroHistorySegments({
    required this.options,
    required this.selected,
    required this.onSelected,
    this.expanded = false,
  });

  final List<String> options;
  final String selected;
  final ValueChanged<String> onSelected;
  final bool expanded;

  Widget _segment(String option) {
    final active = option == selected;
    return InkWell(
      onTap: () => onSelected(option),
      borderRadius: BorderRadius.circular(7),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 8),
        decoration: BoxDecoration(
          color: active ? Colors.white : Colors.transparent,
          borderRadius: BorderRadius.circular(7),
          boxShadow: active
              ? const [BoxShadow(color: Color(0x120F172A), blurRadius: 4,
                  offset: Offset(0, 1))]
              : null,
        ),
        child: Text(
          option,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: active ? const Color(0xFF211F1D) : const Color(0xFF756D67),
            fontSize: 11,
            fontWeight: active ? FontWeight.w800 : FontWeight.w600,
            fontFamily: 'Hellix',
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(3),
    decoration: BoxDecoration(
      color: const Color(0xFFF2ECE7),
      borderRadius: BorderRadius.circular(9),
    ),
    child: !expanded
        ? Wrap(children: [for (final option in options) _segment(option)])
        : LayoutBuilder(
            builder: (context, constraints) {
              final width = constraints.maxWidth;
              final columns = options.length >= 5
                  ? (width < 310 ? 2 : 3)
                  : options.length >= 4 && width < 320
                      ? 2
                      : options.length;
              const spacing = 4.0;
              final buttonWidth =
                  (width - spacing * (columns - 1)) / columns;
              return Wrap(
                spacing: spacing,
                runSpacing: spacing,
                children: [
                  for (final option in options)
                    SizedBox(width: buttonWidth, child: _segment(option)),
                ],
              );
            },
          ),
  );
}
'''

OLD_DESKTOP_TOOLBAR = '''              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.white,
                  border: Border.all(color: _line),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: LayoutBuilder(
                  builder: (context, constraints) =>
                      constraints.maxWidth >= 1030
                      ? Row(
                          children: [
                            Expanded(child: _historyFilters()),
                            const SizedBox(width: 8),
                            SizedBox(
                              width: 235,
                              child: _searchField(compact: true),
                            ),
                          ],
                        )
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _historyFilters(),
                            const SizedBox(height: 8),
                            _searchField(compact: true),
                          ],
                        ),
                ),
              ),
'''


def update_bodegero(source):
    source = pattern_once(
        source,
        r'^  Widget _searchField\(\{bool compact = false\}\) => TextField\(.*?(?=^  Widget _filterChip\()',
        BODEGERO_SEARCH,
        'Bodegero search field style',
    )
    source = pattern_once(
        source,
        r'^  Widget _filterChip\(.*?(?=^  Widget _metric\()',
        BODEGERO_TOOLBAR,
        'Bodegero filter toolbar',
    )
    source = exact(
        source,
        OLD_DESKTOP_TOOLBAR,
        '              _historyFilters(),\n',
        'Bodegero desktop toolbar mounting',
    )
    source = exact(
        source,
        '''                    _searchField(),
                    const SizedBox(height: 10),
                    _historyFilters(),
''',
        '''                    _historyFilters(),
''',
        'Bodegero mobile toolbar mounting',
    )
    if 'class _BodegeroHistorySegments extends StatelessWidget' in source:
        raise PatchMismatch('Bodegero segmented control already exists; refusing to duplicate it.')
    return source.rstrip() + '\n\n' + BODEGERO_SEGMENTS.lstrip() + '\n'


SQL_OLD = """        or (p_domain = 'cashierOrders' and v_filter = 'created'
          and created_by_id = v_account_id)"""
SQL_NEW = """        -- CASHIER_PENDING_HISTORY_FILTER: UI Pending means status pending or
        -- solo_picking for orders already scoped to this cashier and location.
        or (p_domain = 'cashierOrders' and v_filter = 'pending'
          and lower(status) in ('pending', 'solo_picking'))
        or (p_domain = 'cashierOrders' and v_filter = 'created'
          and created_by_id = v_account_id)"""


def main():
    missing = [str(p) for p in (STAFF, BODEGERO, FUNCTION) if not p.is_file()]
    if missing:
        raise PatchMismatch('Missing source file(s): ' + ', '.join(missing))

    old = {p: p.read_text(encoding='utf-8-sig') for p in (STAFF, BODEGERO, FUNCTION)}
    if 'HISTORY_FILTER_VISUAL_PARITY' in old[BODEGERO]:
        raise PatchMismatch('Bodegero patch already applied. No changes were made.')
    updated = {
        STAFF: update_staff(old[STAFF]),
        BODEGERO: update_bodegero(old[BODEGERO]),
        FUNCTION: exact(old[FUNCTION], SQL_OLD, SQL_NEW, 'Cashier Pending database filter'),
    }
    if APPLY.exists():
        raise PatchMismatch(f'{APPLY} already exists. No files were overwritten.')

    # Back up first, then write. A preflight failure above leaves all sources intact.
    backup = Path(tempfile.mkdtemp(prefix='inventory_plus_history_filters_'))
    for path in updated:
        target = backup / path.relative_to(ROOT)
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(path, target)

    try:
        for path, contents in updated.items():
            path.write_text(contents, encoding='utf-8')
        APPLY.parent.mkdir(parents=True, exist_ok=True)
        APPLY.write_text(
            '-- CASHIER_PENDING_HISTORY_FILTER\n'
            '-- REVIEW before executing this file in the Supabase SQL Editor.\n'
            '-- It re-deploys the existing SECURITY DEFINER history_page_v1\n'
            '-- function with one additional Cashier Pending filter clause.\n'
            '-- This SQL has NOT been applied to the database automatically.\n\n'
            + updated[FUNCTION],
            encoding='utf-8',
        )
    except Exception:
        for path in updated:
            shutil.copy2(backup / path.relative_to(ROOT), path)
        if APPLY.is_file():
            APPLY.unlink()
        raise

    print('[OK] Updated Cashier label: Created -> Pending and hid Orders/Restocks switch.')
    print('[OK] Helper filters unchanged: All / Assigned / Prepared.')
    print('[OK] Updated Bodegero desktop/mobile filter DESIGN only; logic preserved.')
    print('[OK] Updated local SQL definition for Cashier pending query support.')
    print('[IMPORTANT] Database is NOT yet updated. Review and deploy:')
    print(f'    {APPLY}')
    print(f'Original files backed up at: {backup}')
    print('Next: git diff --check; git diff --stat; test on localhost.')


if __name__ == '__main__':
    try:
        main()
    except PatchMismatch as exc:
        print('[STOP] ' + str(exc), file=sys.stderr)
        sys.exit(1)
    except Exception as exc:
        print(f'[ERROR] {type(exc).__name__}: {exc}', file=sys.stderr)
        sys.exit(1)

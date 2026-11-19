"""Inventory Plus targeted UI patch: Bodegero status width + Helper/Bodegero store hours.

Run from the Flutter project root with `python fix_bodegero_status_and_staff_hours.py`.
Creates backups in the user's Temp folder and aborts if any expected code anchor is missing.
Does not change backend, authorization, or countdown logic.
"""
from pathlib import Path
from tempfile import mkdtemp
import shutil
import sys

ROOT = Path.cwd()
HISTORY = Path('lib/ui/bodegero_history_page.dart')
MAIN = Path('lib/ui/main_screen.dart')
QUEUE = Path('lib/ui/bodegero_queue_page.dart')


def once(src: str, before: str, after: str, location: str) -> str:
    count = src.count(before)
    if count != 1:
        raise RuntimeError(f'{location}: expected exactly one matching anchor; found {count}. No files modified.')
    return src.replace(before, after, 1)


def replace_in_section(src: str, start: str, end: str, old: str, new: str, what: str) -> str:
    if src.count(start) != 1 or src.count(end) != 1:
        raise RuntimeError(f'{what}: section boundaries differ; no files modified.')
    a = src.index(start)
    b = src.index(end, a + len(start))
    section = once(src[a:b], old, new, what)
    return src[:a] + section + src[b:]


def change_history(text: str) -> str:
    text = once(text, "_desktopCell('STATUS'),", "_desktopCell('STATUS', flex: 2),", 'Bodegero status table heading')
    text = once(text,
        'Expanded(flex: 1, child: _statusBadge(record.status)),',
        '''Expanded(
            flex: 2,
            child: Align(
              alignment: Alignment.centerLeft,
              child: _statusBadge(record.status),
            ),
          ),''',
        'Bodegero status table cell')
    text = once(text,
        """      child: Text(
        normalized.replaceAll('_', ' '),
        style: TextStyle(""",
        """      child: Text(
        normalized.replaceAll('_', ' '),
        // BODEGERO_STATUS_COLUMN_FIX: Keep the pill inside its own column.
        maxLines: 1,
        softWrap: false,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(""",
        'Bodegero status badge text')
    return text


def change_main(text: str) -> str:
    text = once(text,
        'Widget _buildHelperUnifiedWorkspace({',
        '''// STAFF_STORE_HOURS_HEADER_FIX: Reuse the live store-hours clock for
  // Helper and Bodegero. The widget reads the existing store-access settings;
  // no store-hour values are hardcoded.
  Widget _roleStoreHours() => SizedBox(
    width: 224,
    child: AdminStoreStatusClock(
      resolveWindow: _resolveAdminStoreHoursWindow,
      closureReason: _adminClosureReason,
      compact: true,
    ),
  );

  // On narrower screens, put store hours on its own compact row so tabs,
  // availability, notifications, and the logout timer cannot overflow.
  Widget _roleStoreHoursRow() => Container(
    width: double.infinity,
    height: 34,
    padding: const EdgeInsets.symmetric(horizontal: 12),
    alignment: Alignment.centerLeft,
    decoration: const BoxDecoration(
      color: Colors.white,
      border: Border(bottom: BorderSide(color: Color(0xFFE8E3DF))),
    ),
    child: _roleStoreHours(),
  );

Widget _buildHelperUnifiedWorkspace({''',
        'main helper builder insertion')
    start = 'Widget _buildHelperUnifiedWorkspace({'
    end = 'Widget _buildHelperMobileNavigationBar({'
    text = replace_in_section(text, start, end,
        'final isMobile = MediaQuery.sizeOf(context).width < 600;',
        '''final width = MediaQuery.sizeOf(context).width;
    final isMobile = width < 600;
    final storeHoursBelow = width < 1120;''',
        'helper width behavior')
    text = replace_in_section(text, start, end,
        '''              onLogout: () => unawaited(_handleLogout()),
              showTabs: selectedTab != 0 || !_helperChecklistVisible,''',
        '''              onLogout: () => unawaited(_handleLogout()),
              // STAFF_STORE_HOURS_HEADER_FIX: Inline only on wide screens.
              extra: storeHoursBelow ? null : _roleStoreHours(),
              showTabs: selectedTab != 0 || !_helperChecklistVisible,''',
        'helper desktop hours')
    text = replace_in_section(text, start, end,
        '''              ),
            ),

            Expanded(
              child: IndexedStack(index: selectedTab, children: helperPages),''',
        '''              ),
            ),
            if (storeHoursBelow) _roleStoreHoursRow(),

            Expanded(
              child: IndexedStack(index: selectedTab, children: helperPages),''',
        'helper compact hours')
    text = once(text,
        '''        onLogout: () => unawaited(_handleLogout()),
        // STORE_LOGOUT_COUNTDOWN_HEADER: Bodegero has its own app bar.''',
        '''        onLogout: () => unawaited(_handleLogout()),
        // STAFF_STORE_HOURS_HEADER_FIX: Forward the same live store hours.
        storeHours: _roleStoreHours(),
        // STORE_LOGOUT_COUNTDOWN_HEADER: Bodegero has its own app bar.''',
        'Bodegero constructor in MainScreen')
    return text


def change_queue(text: str) -> str:
    text = once(text,
        '''    this.presenceService,
    this.storeLogoutCountdown,
    this.imagePicker,''',
        '''    this.presenceService,
    this.storeLogoutCountdown,
    this.storeHours,
    this.imagePicker,''',
        'Bodegero widget constructor')
    text = once(text,
        '''  final Widget? storeLogoutCountdown;
  final ImagePicker? imagePicker;''',
        '''  final Widget? storeLogoutCountdown;
  // STAFF_STORE_HOURS_HEADER_FIX: Optional live clock supplied by MainScreen.
  final Widget? storeHours;
  final ImagePicker? imagePicker;''',
        'Bodegero widget fields')
    text = once(text,
        '''    final desktop = MediaQuery.sizeOf(context).width >= 900;
    final countdown = widget.storeLogoutCountdown;
    final mobileCountdown = !desktop && countdown != null;
    return PreferredSize(
      preferredSize: Size.fromHeight(mobileCountdown ? 98 : 67),''',
        '''    final width = MediaQuery.sizeOf(context).width;
    final desktop = width >= 900;
    final countdown = widget.storeLogoutCountdown;
    final mobileCountdown = !desktop && countdown != null;
    // STAFF_STORE_HOURS_HEADER_FIX: Avoid crowding the role's main toolbar.
    final storeHoursBelow = widget.storeHours != null && width < 1120;
    return PreferredSize(
      preferredSize: Size.fromHeight(
        (width < 600 ? 64.0 : 66.0) +
        (storeHoursBelow ? 34.0 : 0.0) +
        (mobileCountdown ? 34.0 : 0.0),
      ),''',
        'Bodegero header heights')
    text = once(text,
        '''        onLogout: widget.onLogout,
        availability: widget.presenceService == null''',
        '''        onLogout: widget.onLogout,
        // STAFF_STORE_HOURS_HEADER_FIX: Show inline only on wide desktop.
        extra: storeHoursBelow ? null : widget.storeHours,
        availability: widget.presenceService == null''',
        'Bodegero inline hours')
    text = once(text,
        '''        showTabs: desktop,
          ),
          // STORE_LOGOUT_COUNTDOWN_HEADER: Mobile uses a second compact''',
        '''        showTabs: desktop,
          ),
          // STAFF_STORE_HOURS_HEADER_FIX: Real store hours on mobile/tablet.
          if (storeHoursBelow)
            Container(
              height: 34,
              width: double.infinity,
              alignment: Alignment.centerLeft,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: const BoxDecoration(
                color: Colors.white,
                border: Border(bottom: BorderSide(color: _line)),
              ),
              child: widget.storeHours!,
            ),
          // STORE_LOGOUT_COUNTDOWN_HEADER: Mobile uses a second compact''',
        'Bodegero compact hours')
    return text


def main():
    paths = (HISTORY, MAIN, QUEUE)
    for path in paths:
        if not (ROOT/path).is_file():
            raise RuntimeError(f'Missing {path}; run the script from the Flutter project root.')
    # Preserve original Windows CRLF/LF and optional UTF-8 BOM.
    raw_files = {p: (ROOT/p).read_bytes() for p in paths}
    endings = {p: ('\r\n' if b'\r\n' in raw_files[p] else '\n') for p in paths}
    boms = {p: raw_files[p].startswith(b'\xef\xbb\xbf') for p in paths}
    originals = {p: raw_files[p].decode('utf-8-sig').replace('\r\n', '\n') for p in paths}
    updates = {
        HISTORY: change_history(originals[HISTORY]),
        MAIN: change_main(originals[MAIN]),
        QUEUE: change_queue(originals[QUEUE]),
    }
    folder = Path(mkdtemp(prefix='inventory_plus_staff_ui_backup_'))
    for path in paths:
        target = folder/path
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(ROOT/path, target)
    for path, value in updates.items():
        encoded = value.replace('\n', endings[path]).encode('utf-8')
        if boms[path]:
            encoded = b'\xef\xbb\xbf' + encoded
        (ROOT/path).write_bytes(encoded)
    print('Successfully applied targeted UI changes:')
    for path in paths:
        print('  ' + str(path))
    print('Originals backed up at: ' + str(folder))
    print('Review: git diff --check; git diff --stat; git diff -- lib/ui/bodegero_history_page.dart lib/ui/main_screen.dart lib/ui/bodegero_queue_page.dart')
    print('Do not commit until you visually verify the headers and status pill on mobile + desktop.')

if __name__ == '__main__':
    try:
        main()
    except Exception as exc:
        print('[ERROR] ' + str(exc), file=sys.stderr)
        sys.exit(1)

#!/usr/bin/env python3
"""Inventory Plus -- Bodegero Android/iOS status-bar overlap fix.

Run from your INVENTORY PLUS INTEGRATION repository root on Windows:
    python .\apply_bodegero_mobile_status_bar_safearea.py --check
    python .\apply_bodegero_mobile_status_bar_safearea.py

- Fixes ONLY Bodegero's native Android/iOS workspace boundary.
- Keeps web, Windows/macOS/Linux desktop layouts unchanged.
- Compatible with either SafeArea-based or otherwise padded StaffRoleHeader implementations.
- Does not change notification panels, role actions, tabs, backend, or data.
- Uses SafeArea outside the custom Scaffold.appBar, preventing the header
  from rendering under Android system status-bar icons. SafeArea consumes the
  top MediaQuery inset exactly once; a nested StaffRoleHeader sees zero inset.
- Existing Scaffold bottom navigation handles its own bottom system inset.
- Creates a timestamped backup outside the repository before modifying code.
- Refuses to change an unfamiliar Bodegero source; supports --check.
- Does NOT invoke Flutter analyzer/tests, Gradle, or Git.
"""

from pathlib import Path
import argparse
import difflib
import shutil
import sys
import tempfile

TARGET = Path('lib/ui/bodegero_queue_page.dart')
MAIN = Path('lib/ui/main_screen.dart')
HEADER = Path('lib/ui/widgets/staff_role_header.dart')
MARKER = 'BODEGERO_NATIVE_STATUS_BAR_SAFEAREA_V1'

OLD = '''  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: _background,
    appBar: _header(),'''

NEW = '''  // BODEGERO_NATIVE_STATUS_BAR_SAFEAREA_V1
  // The native mobile page owns the top system inset. Do not shift individual
  // header controls: Android status-bar height can vary by phone, cutout and
  // system font/display settings. Child widgets inherit a MediaQuery with
  // the top inset consumed, preventing accidental double top padding.
  // Web and desktop presentation, notification actions and all tabs stay intact.
  @override
  Widget build(BuildContext context) {
    final workspace = _buildBodegeroWorkspace();
    if (kIsWeb ||
        (defaultTargetPlatform != TargetPlatform.android &&
            defaultTargetPlatform != TargetPlatform.iOS)) {
      return workspace;
    }

    return ColoredBox(
      color: Colors.white,
      child: SafeArea(
        top: true,
        bottom: false,
        child: workspace,
      ),
    );
  }

  Widget _buildBodegeroWorkspace() => Scaffold(
    backgroundColor: _background,
    appBar: _header(),'''


def read(path: Path) -> str:
    if not path.is_file():
        raise RuntimeError(f'Missing {path}; run from the integration project ROOT.')
    return path.read_text(encoding='utf-8-sig')


def verify_other_roles() -> None:
    """Read-only reference checks; do not require identical header internals."""
    main = read(MAIN)
    header = read(HEADER)
    requirements = {
        str(MAIN): [
            "if (widget.controller.currentUserRole?.toLowerCase() == 'bodegero')",
            'return BodegeroQueuePage(',
            'Widget _buildHelperUnifiedWorkspace(',
            'body: SafeArea(',
        ],
        str(HEADER): [
            'class StaffRoleHeader',
        ],
    }
    for name, source in ((str(MAIN), main), (str(HEADER), header)):
        missing = [s for s in requirements[name] if s not in source]
        if missing:
            raise RuntimeError(f'{name} differs from expected source; missing {missing}. No changes made.')
    print('[CHECK] Helper uses outer SafeArea; shared StaffRoleHeader is present (internal implementation may vary).')
    print('[CHECK] Admin and Cashier routing is untouched. Web/desktop will remain unchanged.')


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true', help='Inspect the source without changing files.')
    args = parser.parse_args()

    verify_other_roles()
    current = read(TARGET)
    if MARKER in current:
        if current.count(MARKER) != 1 or '_buildBodegeroWorkspace() => Scaffold(' not in current:
            raise RuntimeError('Marker found but implementation looks incomplete. No changes made.')
        print('[ALREADY APPLIED] Bodegero native status-bar protection exists.')
        return
    if current.count(OLD) != 1:
        raise RuntimeError('Bodegero build method no longer matches the expected pattern. No changes made.')
    if "import 'package:flutter/foundation.dart';" not in current:
        raise RuntimeError('Expected Flutter foundation import is missing. No changes made.')
    if '_buildBodegeroWorkspace(' in current:
        raise RuntimeError('A similarly named workspace already exists. No changes made.')
    # Ensure the known Scaffold has the expected content and closing shape.
    for required in (
        'PreferredSizeWidget _header()',
        'body: IndexedStack(',
        'bottomNavigationBar:',
        '_bottomNavigation(),',
        '  );\n}',
    ):
        if required not in current:
            raise RuntimeError(f'Missing expected Bodegero widget: {required!r}. No changes made.')

    updated = current.replace(OLD, NEW, 1)
    assert updated.count(MARKER) == 1
    assert updated.count('Widget _buildBodegeroWorkspace() => Scaffold(') == 1
    assert updated.count('    appBar: _header(),') == current.count('    appBar: _header(),')
    assert updated.count('bottomNavigationBar:') == current.count('bottomNavigationBar:')
    assert updated.count('helperMobilePanel:') == current.count('helperMobilePanel:')
    assert updated.count('NotificationBell(') == current.count('NotificationBell(')

    diff = ''.join(difflib.unified_diff(
        current.splitlines(keepends=True), updated.splitlines(keepends=True),
        fromfile=str(TARGET) + ' (before)', tofile=str(TARGET) + ' (after)',
    ))
    if args.check:
        print('[DRY RUN] Source is compatible. Planned change:')
        print(diff)
        print('[NO CHANGES MADE] Run without --check to apply.')
        return

    backup_dir = Path(tempfile.mkdtemp(prefix='inventory_plus_bodegero_statusbar_backup_'))
    backup = backup_dir / 'bodegero_queue_page.dart'
    shutil.copy2(TARGET, backup)
    try:
        with TARGET.open('w', encoding='utf-8', newline='\n') as out:
            out.write(updated)
        if MARKER not in read(TARGET):
            raise RuntimeError('Post-write verification failed.')
    except Exception:
        shutil.copy2(backup, TARGET)
        raise

    print('[OK] Native Android/iOS Bodegero header now respects the status bar top inset.')
    print('[OK] Web, desktop, Helper, Admin and Cashier remain unchanged.')
    print('[OK] Notification UI, unread badges, actions, and order flows remain unchanged.')
    print(f'[BACKUP] {backup}')
    print(f'[MODIFIED] {TARGET}')
    print('Review manually, then fully restart flutter run on your device.')
    print('No Flutter analyzer/tests, Gradle or Git commands were run.')


if __name__ == '__main__':
    try:
        main()
    except Exception as ex:
        print(f'[SAFE STOP] {ex}', file=sys.stderr)
        sys.exit(1)

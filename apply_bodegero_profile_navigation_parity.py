#!/usr/bin/env python3
r"""Inventory Plus — Bodegero profile navigation parity (WEB + MOBILE).

Run from the integration Flutter project root:
    python .\apply_bodegero_profile_navigation_parity.py --check
    python .\apply_bodegero_profile_navigation_parity.py

Only two files are touched:
    lib/ui/main_screen.dart
    lib/ui/bodegero_queue_page.dart

The working Admin/Cashier/Helper _showProfileDialog() is reused:
    - Wide layout: existing profile Dialog with close button.
    - Narrow/mobile: existing full profile MaterialPageRoute with back arrow.

Bodegero's main tabs, queue/loading, availability, logout, notifications,
SafeArea, store hours, and backend are not modified. Original Bodegero
internal-profile behavior remains as a compatibility fallback for standalone
BodegeroQueuePage instantiations that do not supply the optional callback.
This patch does not invoke Git, Flutter, tests, or any database operations.

Safety: all anchors prevalidated before writing; backup outside repo;
preflight --check; atomic writes; rollback on failure; repeat-run guard.
"""

from __future__ import annotations

import argparse
import codecs
from datetime import datetime
import difflib
import os
from pathlib import Path
import shutil
import sys
import tempfile

MAIN = Path('lib/ui/main_screen.dart')
BODEGERO = Path('lib/ui/bodegero_queue_page.dart')
MARKER = 'BODEGERO_PROFILE_NAV_PARITY_V1'


def require_once(source: str, before: str, after: str, purpose: str) -> str:
    matches = source.count(before)
    if matches != 1:
        raise RuntimeError(f'{purpose}: expected one source anchor, found {matches}. No files changed.')
    return source.replace(before, after, 1)


def patch_main(source: str) -> str:
    if MARKER in source:
        raise RuntimeError('main_screen.dart already contains this profile patch (partial/repeat run).')

    # Make sure the common navigation is still the reference design.
    if 'void _showProfileDialog()' not in source or 'Navigator.of(context).push(' not in source:
        raise RuntimeError('Common profile navigation in MainScreen is different from the reference version.')
    if 'child: SizedBox(' not in source or 'HelperMePage(' not in source:
        raise RuntimeError('Expected shared profile dialog content not found in MainScreen.')

    anchor = '''      return BodegeroQueuePage(
        controller: widget.controller,
        onLogout: () => unawaited(_handleLogout()),'''
    patched = '''      return BodegeroQueuePage(
        controller: widget.controller,
        onLogout: () => unawaited(_handleLogout()),
        // BODEGERO_PROFILE_NAV_PARITY_V1: Use the same profile modal/route
        // as Admin, Cashier, and Helper. No extra Bodegero profile tab.
        onProfile: _showProfileDialog,'''
    return require_once(source, anchor, patched, 'MainScreen Bodegero callback')


def patch_bodegero(source: str) -> str:
    if MARKER in source:
        raise RuntimeError('bodegero_queue_page.dart already contains this profile patch (partial/repeat run).')
    if 'class BodegeroQueuePage extends StatefulWidget' not in source:
        raise RuntimeError('BodegeroQueuePage class is missing.')
    if 'Widget build(BuildContext context) => Scaffold(' not in source and '_buildBodegeroWorkspace() => Scaffold(' not in source:
        raise RuntimeError('Bodegero scaffold differs significantly from inspected version.')

    source = require_once(
        source,
        '''    required this.onLogout,
    this.approvalChanges,''',
        '''    required this.onLogout,
    this.onProfile,
    this.approvalChanges,''',
        'Bodegero constructor',
    )
    source = require_once(
        source,
        '''  final VoidCallback onLogout;
  final Stream<void>? approvalChanges;''',
        '''  final VoidCallback onLogout;
  // Optional to retain standalone test/caller compatibility.
  final VoidCallback? onProfile;
  final Stream<void>? approvalChanges;''',
        'Bodegero callback field',
    )
    old = '''        onProfile: () {
          setState(() {
            _tabIndex = 4;
            _visitedTabs.add(4);
          });
          widget.onModuleChanged?.call('Profile');
          final presence = widget.presenceService;
          if (presence != null) {
            unawaited(presence.setWorkMode(null));
          }
        },'''
    new = '''        onProfile: () {
          // BODEGERO_PROFILE_NAV_PARITY_V1: The main app opens the shared
          // profile dialog on web/desktop, and a push route with back arrow
          // on mobile. Do not replace the active queue tab or show bottom
          // navigation behind the mobile profile.
          final openSharedProfile = widget.onProfile;
          if (openSharedProfile != null) {
            openSharedProfile();
            return;
          }
          // Preserve existing behavior for legacy/standalone callers.
          setState(() {
            _tabIndex = 4;
            _visitedTabs.add(4);
          });
          widget.onModuleChanged?.call('Profile');
          final presence = widget.presenceService;
          if (presence != null) {
            unawaited(presence.setWorkMode(null));
          }
        },'''
    source = require_once(source, old, new, 'Bodegero header onProfile')
    return source


def read_file(path: Path) -> tuple[str, bytes, bool, str]:
    raw = path.read_bytes()
    bom = raw.startswith(codecs.BOM_UTF8)
    text = raw.decode('utf-8-sig')
    crlf = text.count('\r\n')
    newline = '\r\n' if crlf and crlf == text.count('\n') else '\n'
    return text.replace('\r\n', '\n'), raw, bom, newline


def encode_file(text: str, bom: bool, newline: str) -> bytes:
    value = text.replace('\n', newline).encode('utf-8')
    return codecs.BOM_UTF8 + value if bom else value


def write_atomic(path: Path, data: bytes) -> None:
    fd, name = tempfile.mkstemp(prefix='.bodegero_profile_', suffix='.tmp', dir=path.parent)
    try:
        with os.fdopen(fd, 'wb') as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--check', action='store_true', help='Show changes only; write nothing.')
    p.add_argument('--root', default='.', help='Flutter integration repo root, defaults to current directory.')
    args = p.parse_args()

    root = Path(args.root).resolve()
    if root.name.casefold() != 'inventory_plus_capstone_v2-integration':
        raise RuntimeError('Wrong project root. Run inside Inventory_Plus_Capstone_v2-integration, not the other worktree.')
    paths = [root / MAIN, root / BODEGERO]
    if any(not f.is_file() for f in paths):
        raise RuntimeError('Missing main_screen.dart or bodegero_queue_page.dart. No changes made.')

    before_raw: dict[Path, bytes] = {}
    after_raw: dict[Path, bytes] = {}
    for file, callback in ((paths[0], patch_main), (paths[1], patch_bodegero)):
        original, raw, bom, newline = read_file(file)
        updated = callback(original)
        if updated == original:
            raise RuntimeError(f'No modifications generated for {file}.')
        before_raw[file] = raw
        after_raw[file] = encode_file(updated, bom, newline)

    # Minimality assertions: no changes to code beyond the targeted control path.
    main_updated = after_raw[paths[0]].decode('utf-8-sig')
    bodegero_updated = after_raw[paths[1]].decode('utf-8-sig')
    if main_updated.count('BodegeroQueuePage(') != before_raw[paths[0]].decode('utf-8-sig').count('BodegeroQueuePage('):
        raise RuntimeError('Unexpected Bodegero construction change. No files changed.')
    for token in ('NotificationBell(', '_bottomNavigation()', 'BodegeroHistoryPage(',
                  'HelperMePage(', 'widget.onLogout', 'presence.setWorkMode(null)'):
        old_n = before_raw[paths[1]].decode('utf-8-sig').count(token)
        new_n = bodegero_updated.count(token)
        if old_n != new_n:
            raise RuntimeError(f'Unexpected change to {token} ({old_n}->{new_n}). No files changed.')

    if args.check:
        for file in paths:
            old = before_raw[file].decode('utf-8-sig').splitlines(keepends=True)
            new = after_raw[file].decode('utf-8-sig').splitlines(keepends=True)
            print(''.join(difflib.unified_diff(
                old, new,
                fromfile=str(file.relative_to(root)) + ' (before)',
                tofile=str(file.relative_to(root)) + ' (after)',
            )).replace('\r\n', '\n'))
        print('[CHECK OK] Both files are compatible. No changes made.')
        return

    timestamp = datetime.now().strftime('%Y%m%d_%H%M%S_%f')
    backup = Path(tempfile.mkdtemp(prefix=f'inventory_plus_profile_{timestamp}_'))
    for file in paths:
        out = backup / file.relative_to(root)
        out.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(file, out)

    written: list[Path] = []
    try:
        for file in paths:
            if file.read_bytes() != before_raw[file]:
                raise RuntimeError(f'Concurrent source edit detected: {file.name}.')
            write_atomic(file, after_raw[file])
            written.append(file)
        for file in paths:
            if file.read_bytes() != after_raw[file]:
                raise RuntimeError(f'Post-write verification failed: {file.name}.')
    except Exception:
        for file in written:
            write_atomic(file, before_raw[file])
        raise

    print('[OK] Bodegero web: shared profile dialog with close button.')
    print('[OK] Bodegero mobile: full-screen profile with back arrow, no underlying role header/footer.')
    print('[OK] Admin/Cashier/Helper, notifications, queue, and backend unchanged.')
    for file in paths:
        print(f'[MODIFIED] {file.relative_to(root)}')
    print(f'[BACKUP] {backup}')
    print('[NEXT] Fully restart Flutter and test profile open/close on web and mobile.')
    print('[NOTE] No Flutter, Git, database, or test commands were run.')


if __name__ == '__main__':
    try:
        main()
    except Exception as exc:
        print(f'[SAFE STOP] {exc}', file=sys.stderr)
        raise SystemExit(1)

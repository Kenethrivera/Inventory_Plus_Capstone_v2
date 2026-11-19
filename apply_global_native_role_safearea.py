#!/usr/bin/env python3
"""Inventory Plus: shared native Android/iOS safe-area patch for every role workspace.

From the *integration* project's root in PowerShell:
    python .\apply_global_native_role_safearea.py --check
    python .\apply_global_native_role_safearea.py

Scope:
- Admin, Cashier, Helper, Bodegero inside MainScreen, including their tabs.
- Android/iOS native ONLY; web and Windows/macOS/Linux are unchanged.
- Applies the top/left/right OS safe inset above the role Scaffold.
- Does not add bottom padding; existing Scaffold bottom navigation remains in charge.
- Nested SafeArea widgets automatically receive consumed MediaQuery padding,
  avoiding a second top inset on existing Helper/Bodegero pages.
- Does not wrap MaterialApp/Navigator; camera, login, and modal routes are unchanged.
- No notification, auth, Supabase, backend, role, or navigation callback changes.
- Updates ONE source file, with a preflight check, dry-run, and an external backup.
- Does NOT run Flutter, Gradle, tests, analyzer, or Git commands.
"""

from pathlib import Path
import argparse
import difflib
import shutil
import sys
import tempfile

TARGET = Path('lib/ui/main_screen.dart')
MARKER = 'GLOBAL_NATIVE_ROLE_SAFEAREA_V1'

OLD = '''    return NotificationProvider(
      controller: notificationController,
      child: _buildMainContent(),
    );'''

NEW = '''    // GLOBAL_NATIVE_ROLE_SAFEAREA_V1
    // A single outer safe-area boundary for every authenticated role workspace.
    // It covers the Cashier, Admin, Helper, and Bodegero main screens/tabs.
    // SafeArea consumes the top MediaQuery inset before the child Scaffold,
    // so nested Helper/Bodegero SafeArea widgets never add it a second time.
    // Keep the bottom inset owned by the existing Scaffold/navigation controls.
    // Native Android/iOS only; the web/desktop layout is unaffected.
    return NotificationProvider(
      controller: notificationController,
      child: !kIsWeb &&
              (defaultTargetPlatform == TargetPlatform.android ||
                  defaultTargetPlatform == TargetPlatform.iOS)
          ? ColoredBox(
              color: Colors.white,
              child: SafeArea(
                top: true,
                bottom: false,
                child: _buildMainContent(),
              ),
            )
          : _buildMainContent(),
    );'''


def load(path: Path) -> str:
    if not path.is_file():
        raise RuntimeError(f'Missing {path}. Run from the Inventory Plus integration project root.')
    return path.read_text(encoding='utf-8-sig')


def verify_structure(current: str) -> None:
    # Only check the stable root routing and imports. Never hardcode the
    # internal StaffRoleHeader layout; it differs across local versions.
    required = [
        "import 'package:flutter/foundation.dart';",
        'class MainScreen extends StatefulWidget',
        'return NotificationProvider(',
        'controller: notificationController,',
        'Widget _buildMainContent()',
        "currentUserRole?.toLowerCase() == 'bodegero'",
        'BodegeroQueuePage(',
        '_buildHelperUnifiedWorkspace(',
        'final isAdmin = role ==',
        'final isCashier = role ==',
    ]
    missing = [fragment for fragment in required if fragment not in current]
    if missing:
        raise RuntimeError('MainScreen differs from the inspected routing structure. '
                           f'No changes made. Missing: {missing}')
    if current.count('return NotificationProvider(') != 1:
        raise RuntimeError('Expected a single NotificationProvider in MainScreen. No changes made.')
    if current.count('Widget _buildMainContent()') != 1:
        raise RuntimeError('Expected one role-workspace entrypoint. No changes made.')


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true', help='Preview only; no source modifications.')
    args = parser.parse_args()

    current = load(TARGET)
    verify_structure(current)

    if MARKER in current:
        if current.count(MARKER) != 1 or current.count('child: SafeArea(') < 1:
            raise RuntimeError('Global SafeArea marker is present but its source looks incomplete.')
        print('[ALREADY APPLIED] Shared native role SafeArea is present; no changes made.')
        return

    if current.count(OLD) != 1:
        raise RuntimeError('The NotificationProvider root differs from the expected source. '
                           'No changes made; share the surrounding MainScreen.build code.')

    updated = current.replace(OLD, NEW, 1)
    if updated.count(MARKER) != 1:
        raise RuntimeError('Unexpected patch marker count. No changes made.')
    if updated.count('return NotificationProvider(') != current.count('return NotificationProvider('):
        raise RuntimeError('NotificationProvider count changed. No changes made.')
    if updated.count('_buildMainContent()') != current.count('_buildMainContent()') + 1:
        # The conditional has two calls in separate branches, but only one runs.
        raise RuntimeError('Unexpected root-workspace method change. No changes made.')
    if updated.count('BodegeroQueuePage(') != current.count('BodegeroQueuePage('):
        raise RuntimeError('Bodegero page routing changed unexpectedly. No changes made.')
    if updated.count('NotificationBell(') != current.count('NotificationBell('):
        raise RuntimeError('Notification bell usage changed unexpectedly. No changes made.')

    diff = ''.join(difflib.unified_diff(
        current.splitlines(keepends=True), updated.splitlines(keepends=True),
        fromfile=f'{TARGET} (before)', tofile=f'{TARGET} (after)'))

    if args.check:
        print('[DRY RUN] Compatible MainScreen found. Planned one-file modification:\n')
        print(diff)
        print('[NO CHANGES MADE] Run the script without --check to apply.')
        return

    backup_dir = Path(tempfile.mkdtemp(prefix='inventory_plus_global_safearea_backup_'))
    backup = backup_dir / TARGET.name
    shutil.copy2(TARGET, backup)
    try:
        with TARGET.open('w', encoding='utf-8', newline='\n') as output:
            output.write(updated)
        observed = load(TARGET)
        if observed != updated:
            raise RuntimeError('Post-write verification mismatch.')
    except Exception:
        shutil.copy2(backup, TARGET)
        raise

    print('[OK] Shared native Android/iOS safe-area boundary added for all four role workspaces.')
    print('[OK] Existing Helper/Bodegero SafeArea widgets consume no extra top inset.')
    print('[OK] Web/desktop layouts, notifications, profile actions and backend unchanged.')
    print('[OK] Existing bottom navigation and system gesture area unchanged.')
    print(f'[BACKUP] {backup}')
    print(f'[MODIFIED] {TARGET}')
    print('Fully restart flutter run (q then flutter run) and check each role on-device.')
    print('No Flutter analyzer/tests, Gradle or Git commands were run.')


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        print(f'[SAFE STOP] {error}', file=sys.stderr)
        sys.exit(1)

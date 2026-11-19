#!/usr/bin/env python3
r"""Inventory Plus - native mobile notification presentation parity patch.

Run in Windows PowerShell from the INTEGRATION Flutter repository root:

    cd C:\inventory_plus_capstone_v2\Inventory_Plus_Capstone_v2-integration
    python .\apply_mobile_staff_notification_parity.py

Or run from anywhere using --root:

    python .\apply_mobile_staff_notification_parity.py --root "C:\inventory_plus_capstone_v2\Inventory_Plus_Capstone_v2-integration"

Changes ONLY:
  - lib/notifications/notification_bell.dart
  - lib/notifications/notification_page.dart

Result:
  - Native Android/iOS Helper and Bodegero notification bells open the same
    92%-height modal bottom sheet as Admin/Cashier.
  - Helper/Bodegero retain their existing All, Archived, Orders, Approvals
    filter choices and all notification actions and routing callbacks.
  - Web behavior, including narrow web screens, is unchanged.
  - Admin/Cashier presentation and filters stay unchanged.
  - Notification repository, Supabase/RLS, and business logic are untouched.

Safety:
  - Checks precise source anchors and refuses unexpected versions.
  - Refuses to apply twice.
  - Backs up BOTH files before writing; restores on writing errors.
  - Preserves original UTF-8 BOM and line endings.
  - Does NOT run Flutter, Dart analyzer/tests, Git, or commits.
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

MARKER = 'STAFF_NATIVE_MOBILE_NOTIFICATION_PARITY_V1'
EXPECTED_DIR_NAME = 'inventory_plus_capstone_v2-integration'
BELL_PATH = Path('lib/notifications/notification_bell.dart')
PAGE_PATH = Path('lib/notifications/notification_page.dart')


def replace_exact(source: str, old: str, new: str, description: str) -> str:
    count = source.count(old)
    if count != 1:
        raise RuntimeError(
            f'{description}: expected exactly one matching code block, found {count}. '
            'No files changed. Your local source may differ from this patch version.'
        )
    return source.replace(old, new, 1)


def patch_bell(text: str) -> str:
    if MARKER in text:
        raise RuntimeError('NotificationBell already contains this patch marker.')

    text = replace_exact(
        text,
        "import 'dart:async';\n\nimport 'package:flutter/material.dart';",
        "import 'dart:async';\n\nimport 'package:flutter/foundation.dart' show kIsWeb;\nimport 'package:flutter/material.dart';",
        'Add kIsWeb import',
    )

    text = replace_exact(
        text,
        "    if (!isDesktop) {\n      if (helperMobilePanel) {\n",
        "    if (!isDesktop) {\n"
        f"      // {MARKER}: Preserve web popover. On native mobile,\n"
        "      // Helper/Bodegero share the Admin/Cashier bottom-sheet presentation.\n"
        "      if (helperMobilePanel && kIsWeb) {\n",
        'Keep existing web popover and route native mobile to sheet',
    )

    text = replace_exact(
        text,
        "            child: NotificationPage(\n"
        "              controller: controller,\n"
        "              isModal: true,\n"
        "              onValidateNotification: onValidateNotification,",
        "            child: NotificationPage(\n"
        "              controller: controller,\n"
        "              isModal: true,\n"
        "              staffMobileFilters: helperMobilePanel && !kIsWeb,\n"
        "              onValidateNotification: onValidateNotification,",
        'Pass mobile staff filter mode to shared sheet only',
    )

    # This method's desktop branches and all existing callbacks are untouched.
    if text.count('_showHelperMobilePanel(') < 2:
        raise RuntimeError('Original web popover function appears missing.')
    if 'staffMobileFilters: helperMobilePanel && !kIsWeb' not in text:
        raise RuntimeError('Mobile-only staff filter routing not present.')
    return text


def patch_page(text: str) -> str:
    if MARKER in text:
        raise RuntimeError('NotificationPage already contains this patch marker.')

    text = replace_exact(
        text,
        '  transactions,\n  system,\n}\n\nclass NotificationPage',
        '  transactions,\n  system,\n  approvals,\n}\n\nclass NotificationPage',
        'Add approvals filter enum',
    )

    text = replace_exact(
        text,
        '  final bool isModal;\n  final Future<String?> Function(AppNotification notification)?',
        '  final bool isModal;\n'
        f'  // {MARKER}: Helper/Bodegero native-mobile filters only.\n'
        '  final bool staffMobileFilters;\n'
        '  final Future<String?> Function(AppNotification notification)?',
        'Add mobile-staff-only filter option',
    )

    text = replace_exact(
        text,
        '    this.isModal = false,\n    this.onValidateNotification,',
        '    this.isModal = false,\n'
        '    this.staffMobileFilters = false,\n'
        '    this.onValidateNotification,',
        'Default other roles to original filter behavior',
    )

    text = replace_exact(
        text,
        '    final filters = _availableFilters(widget.controller.notifications);',
        '    final filters = widget.staffMobileFilters\n'
        '        ? const <NotificationFilter>[\n'
        '            NotificationFilter.all,\n'
        '            NotificationFilter.archived,\n'
        '            NotificationFilter.orders,\n'
        '            NotificationFilter.approvals,\n'
        '          ]\n'
        '        : _availableFilters(widget.controller.notifications);',
        'Keep exact original Helper/Bodegero filter options on mobile',
    )

    text = replace_exact(
        text,
        '      case NotificationFilter.stock:\n'
        '        return notifications.where((n) {',
        '      case NotificationFilter.approvals:\n'
        '        return notifications\n'
        "            .where((n) => n.payload['category'] == 'inventoryApproval')\n"
        '            .toList();\n\n'
        '      case NotificationFilter.stock:\n'
        '        return notifications.where((n) {',
        'Keep existing approval-category filtering',
    )

    text = replace_exact(
        text,
        '      case NotificationFilter.archived:\n'
        "        return 'Archived';",
        '      case NotificationFilter.approvals:\n'
        "        return 'Approvals';\n"
        '      case NotificationFilter.archived:\n'
        "        return 'Archived';",
        'Label Approvals filter',
    )

    text = replace_exact(
        text,
        '      case NotificationFilter.archived:\n'
        "        return 'No archived notifications';",
        '      case NotificationFilter.approvals:\n'
        "        return 'No approval notifications';\n"
        '      case NotificationFilter.archived:\n'
        "        return 'No archived notifications';",
        'Keep approval-specific empty-state message',
    )

    if 'NotificationActionsMenu(' not in text or 'widget.isActionable(' not in text:
        raise RuntimeError('Shared notification actions missing; refusing to write.')
    return text


def read_source(path: Path) -> tuple[str, bytes, bool, str]:
    data = path.read_bytes()
    has_bom = data.startswith(codecs.BOM_UTF8)
    text = data.decode('utf-8-sig')
    # Normalization only for matching. Original source's newline style is retained.
    newline = '\r\n' if text.count('\r\n') > (text.count('\n') / 2) else '\n'
    return text.replace('\r\n', '\n'), data, has_bom, newline


def encode_source(text: str, bom: bool, newline: str) -> bytes:
    rendered = text.replace('\n', newline).encode('utf-8')
    return (codecs.BOM_UTF8 + rendered) if bom else rendered


def atomic_write(path: Path, payload: bytes) -> None:
    fd, name = tempfile.mkstemp(prefix='.ip_notification_', suffix='.tmp', dir=path.parent)
    try:
        with os.fdopen(fd, 'wb') as stream:
            stream.write(payload)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', default='.', help='Integration repository root (default: current directory).')
    parser.add_argument('--dry-run', action='store_true', help='Show the diff without modifying any files.')
    args = parser.parse_args()

    root = Path(args.root).resolve()
    if root.name.casefold() != EXPECTED_DIR_NAME:
        raise RuntimeError(
            f'Wrong project folder: {root}\n'
            f'Expected folder name: Inventory_Plus_Capstone_v2-integration\n'
            'No files changed. Run from the integration project root or supply --root.'
        )
    paths = [root / BELL_PATH, root / PAGE_PATH]
    for path in paths:
        if not path.is_file():
            raise RuntimeError(f'Missing expected Flutter source: {path}')

    originals = {}
    updates = {}
    for path, patcher in zip(paths, (patch_bell, patch_page)):
        source, raw, bom, eol = read_source(path)
        modified = patcher(source)
        if modified == source:
            raise RuntimeError(f'No code changes produced for {path}.')
        originals[path] = raw
        updates[path] = encode_source(modified, bom, eol)

    print(f'[ROOT] {root}')
    print('[SCOPE] Native mobile only: Helper and Bodegero bottom sheet parity')
    print('[UNCHANGED] Web, Admin/Cashier, notification actions and backends')

    if args.dry_run:
        for path in paths:
            before = originals[path].decode('utf-8-sig').splitlines(keepends=True)
            after = updates[path].decode('utf-8-sig').splitlines(keepends=True)
            diff = difflib.unified_diff(
                before, after,
                fromfile=str(path.relative_to(root)) + ' (before)',
                tofile=str(path.relative_to(root)) + ' (after)',
            )
            print(''.join(diff).replace('\r\n', '\n'))
        print('[DRY-RUN] No files modified.')
        return

    stamp = datetime.now().strftime('%Y%m%d_%H%M%S_%f')
    backup = root / '.inventory_plus_patch_backups' / f'mobile_notifications_{stamp}'
    backup.mkdir(parents=True, exist_ok=False)
    for path in paths:
        target = backup / path.relative_to(root)
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(path, target)

    written = []
    try:
        for path in paths:
            # Abort if another editor changed the file since preflight.
            if path.read_bytes() != originals[path]:
                raise RuntimeError(f'{path} changed during patch preparation; aborting.')
            atomic_write(path, updates[path])
            written.append(path)
    except Exception:
        for path in written:
            atomic_write(path, originals[path])
        raise

    for path in paths:
        print(f'[OK] Updated: {path.relative_to(root)}')
    print(f'[BACKUP] {backup}')
    print('[OK] Helper/Bodegero native-mobile bell now uses Admin/Cashier bottom sheet.')
    print('[OK] All, Archived, Orders, Approvals filters preserved for staff.')
    print('[OK] Web popover, existing actions, callback routing and backend preserved.')
    print('[NOTE] No Flutter commands, analyzer/tests, Git operations or commits run.')
    print('[NEXT] Hot restart an existing Flutter debug session; test both roles on mobile.')


if __name__ == '__main__':
    try:
        main()
    except Exception as exc:
        print(f'[SAFE STOP] {exc}', file=sys.stderr)
        sys.exit(1)

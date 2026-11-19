#!/usr/bin/env python3
"""Build complete merged Inventory Plus staff Dart files from the in-progress Git merge.

Reads the *incoming main* versions from unmerged index stage 3, then reapplies
only activity-based Helper/Bodegero status behavior. Does not perform any Git
stage/commit/push and does not alter any other source file.

Requires an active merge with unmerged lib/ui/main_screen.dart and
lib/ui/bodegero_queue_page.dart. Run from the repository root using `py`.
"""
from __future__ import annotations

import datetime
import difflib
from pathlib import Path
import re
import subprocess
import sys
import tempfile

PATH_B = 'lib/ui/bodegero_queue_page.dart'
PATH_M = 'lib/ui/main_screen.dart'


def git(*args: str) -> bytes:
    result = subprocess.run(['git', *args], stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, check=False)
    if result.returncode != 0:
        raise RuntimeError(f"git {' '.join(args)} failed:\n{result.stderr.decode('utf-8', 'replace')}")
    return result.stdout


def replace(text: str, old: str, new: str, label: str, count: int = 1) -> str:
    seen = text.count(old)
    if seen != count:
        raise RuntimeError(f'{label}: expected {count} exact match(es), found {seen}. No files were replaced.')
    return text.replace(old, new)


def bodegero(text: str) -> str:
    text = replace(text,
        "  @override\n  void dispose() {\n    widget.presenceService?.removeListener(_scheduleAutoClaim);",
        "  @override\n  void dispose() {\n"
        "    if (_selectedOrderId != null) {\n"
        "      final presence = widget.presenceService;\n"
        "      if (presence != null) {\n"
        "        unawaited(presence.setWorkMode(null));\n"
        "      }\n"
        "    }\n"
        "    widget.presenceService?.removeListener(_scheduleAutoClaim);",
        'Bodegero disposal cleanup')
    text = replace(text,
        "          isBodegero: true,\n          activeOrders: activeOrders,\n",
        "          isBodegero: true,\n          activeOrders: activeOrders,\n          currentModule: presence.workMode,\n",
        'Bodegero current work mode')
    text = replace(text,
        "          StaffAvailability.busy => 'Preparing',",
        "          StaffAvailability.preparing => 'Preparing',\n          StaffAvailability.loading => 'Loading',",
        'Bodegero status labels')
    text = replace(text,
        '          StaffAvailability.busy => _orange,',
        '          StaffAvailability.preparing => _orange,\n          StaffAvailability.loading => _orange,',
        'Bodegero status colors')
    text = replace(text,
        "    setState(() {\n      _selectedOrderId = order.id;\n      _completedOrder = null;\n      _photoJpeg = null;\n    });\n    return true;\n  }\n\n  CustomerOrder? _notifiedLoadingOrder",
        "    setState(() {\n      _selectedOrderId = order.id;\n      _completedOrder = null;\n      _photoJpeg = null;\n    });\n"
        "    final presence = widget.presenceService;\n"
        "    if (presence != null) {\n"
        "      unawaited(presence.setWorkMode(staffLoadingModule));\n"
        "    }\n"
        "    return true;\n  }\n\n"
        "  void _closeLoadingChecklist() {\n"
        "    if (!mounted) return;\n"
        "    setState(() {\n"
        "      _selectedOrderId = null;\n"
        "    });\n"
        "    final presence = widget.presenceService;\n"
        "    if (presence != null) {\n"
        "      unawaited(presence.setWorkMode(null));\n"
        "    }\n"
        "  }\n\n"
        "  CustomerOrder? _notifiedLoadingOrder",
        'Bodegero checklist entry/exit')
    text = replace(text,
        "    setState(() => _tabIndex = 0);\n    return _open(order);",
        "    setState(() => _tabIndex = 0);\n"
        "    widget.onModuleChanged?.call('Heavy loading');\n"
        "    return _open(order);",
        'Bodegero notification opens queue')
    text = replace(text,
        "      setState(() {\n        _selectedOrderId = null;\n        _completedOrder = updated;\n        _photoJpeg = null;\n      });\n      _message(",
        "      setState(() {\n        _selectedOrderId = null;\n        _completedOrder = updated;\n        _photoJpeg = null;\n      });\n"
        "      final presence = widget.presenceService;\n"
        "      if (presence != null) {\n"
        "        unawaited(presence.setWorkMode(null));\n"
        "      }\n"
        "      _message(",
        'Bodegero finishing work clears Loading')
    text = replace(text,
        "          widget.onModuleChanged?.call('Profile');\n",
        "          widget.onModuleChanged?.call('Profile');\n"
        "          final presence = widget.presenceService;\n"
        "          if (presence != null) {\n"
        "            unawaited(presence.setWorkMode(null));\n"
        "          }\n",
        'Bodegero profile clears Loading')
    text = replace(text,
        "    widget.onModuleChanged?.call(\n"
        "      const [\n"
        "        'Heavy loading',\n"
        "        'Store map',\n"
        "        'Loading history',\n"
        "        'Stock request',\n"
        "        'Profile',\n"
        "      ][index],\n"
        "    );\n",
        "    widget.onModuleChanged?.call(\n"
        "      const [\n"
        "        'Heavy loading',\n"
        "        'Store map',\n"
        "        'Loading history',\n"
        "        'Stock request',\n"
        "        'Profile',\n"
        "      ][index],\n"
        "    );\n"
        "    final presence = widget.presenceService;\n"
        "    if (presence != null) {\n"
        "      final mode = index == 0 && _selectedOrderId != null\n"
        "          ? staffLoadingModule\n"
        "          : null;\n"
        "      unawaited(presence.setWorkMode(mode));\n"
        "    }\n",
        'Bodegero tab changes work mode')
    text = replace(text,
        "                    : () => setState(() => _selectedOrderId = null),",
        "                    : _closeLoadingChecklist,",
        'Bodegero mobile and desktop back buttons', count=2)
    text = replace(text,
        "      CustomerOrder? selected;\n"
        "      for (final order in orders) {\n"
        "        if (order.id == _selectedOrderId) selected = order;\n"
        "      }\n"
        "      return selected == null",
        "      CustomerOrder? selected;\n"
        "      for (final order in orders) {\n"
        "        if (order.id == _selectedOrderId) selected = order;\n"
        "      }\n"
        "      if (selected == null && _selectedOrderId != null) {\n"
        "        WidgetsBinding.instance.addPostFrameCallback((_) {\n"
        "          if (!mounted || _selectedOrderId == null) return;\n"
        "          _closeLoadingChecklist();\n"
        "        });\n"
        "      }\n"
        "      return selected == null",
        'Bodegero invalidated checklist cleanup')
    for forbidden in ['_loadingPaused', '_toggleLoadingPause', 'setOrderLoadingPause', 'StaffAvailability.busy',
                      '<<<<<<<', '=======\n', '>>>>>>>']:
        if forbidden in text:
            raise RuntimeError(f'Bodegero output contains obsolete or conflict code: {forbidden}')
    return text


def main_screen(text: str) -> str:
    text = replace(text,
        "  void _updateStaffPresenceModule() {\n"
        "    _staffPresenceService?.updateModule(_currentModuleName());\n"
        "  }",
        "  void _syncHelperWorkStatus() {\n"
        "    final presence = _staffPresenceService;\n"
        "    if (presence == null || _sessionRole != 'helper') return;\n\n"
        "    final preparing =\n"
        "        _helperChecklistVisible &&\n"
        "        _helperMobileTab == 0 &&\n"
        "        _currentMainSection == MainSection.queue;\n\n"
        "    unawaited(presence.setWorkMode(preparing ? staffPreparingModule : null));\n"
        "  }\n\n"
        "  void _updateStaffPresenceModule() {\n"
        "    _staffPresenceService?.updateModule(_currentModuleName());\n"
        "    _syncHelperWorkStatus();\n"
        "  }",
        'Helper presence synchronization')
    text = replace(text,
        "    try {\n"
        "      await presence.setOnBreak(!presence.isOnBreak);\n"
        "    } catch (_) {\n"
        "      if (mounted) {\n"
        "        AppToast.error(context, 'Could not update your availability.');\n"
        "      }\n"
        "    } finally {",
        "    try {\n"
        "      await presence.setOnBreak(!presence.isOnBreak);\n"
        "    } on StateError catch (error) {\n"
        "      if (mounted) {\n"
        "        AppToast.error(context, error.message);\n"
        "      }\n"
        "    } catch (_) {\n"
        "      if (mounted) {\n"
        "        AppToast.error(context, 'Could not update your availability.');\n"
        "      }\n"
        "    } finally {",
        'Helper break error handling')
    text = replace(text,
        "              onChecklistVisibilityChanged: (visible) {\n"
        "                if (mounted && _helperChecklistVisible != visible) {\n"
        "                  setState(() => _helperChecklistVisible = visible);\n"
        "                }\n"
        "              },",
        "              onChecklistVisibilityChanged: (visible) {\n"
        "                if (!mounted) return;\n"
        "                if (_helperChecklistVisible != visible) {\n"
        "                  setState(() => _helperChecklistVisible = visible);\n"
        "                }\n"
        "                _syncHelperWorkStatus();\n"
        "              },",
        'Helper checklist visibility callback')
    text = replace(text,
        "    setState(() {\n"
        "      _helperMobileTab = tab;\n"
        "      if (tab != 0) {\n"
        "        _helperChecklistVisible = false;\n"
        "      }\n"
        "    });",
        "    setState(() {\n"
        "      _helperMobileTab = tab;\n"
        "    });",
        'Helper tab switching preserves checklist visibility')
    text = replace(text,
        "    _staffPresenceService?.updateModule(modules[tab]);",
        "    _staffPresenceService?.updateModule(modules[tab]);\n"
        "    _syncHelperWorkStatus();",
        'Helper tab switching syncs activity')
    text = replace(text,
        "            activeOrders: activeOrders,\n",
        "            activeOrders: activeOrders,\n"
        "            currentModule: presence.workMode,\n",
        'Helper availability uses work mode', count=2)
    text = replace(text,
        "            StaffAvailability.busy => 'Busy',",
        "            StaffAvailability.preparing => 'Preparing',\n"
        "            StaffAvailability.loading => 'Loading',",
        'Helper unified label')
    text = replace(text,
        "            StaffAvailability.busy => 'Preparing',",
        "            StaffAvailability.preparing => 'Preparing',\n"
        "            StaffAvailability.loading => 'Loading',",
        'Helper top header label')
    text = replace(text,
        "            StaffAvailability.busy => const Color(0xFFC83D08),",
        "            StaffAvailability.preparing => const Color(0xFFC83D08),\n"
        "            StaffAvailability.loading => const Color(0xFFC83D08),",
        'Helper work state colors', count=2)
    text = replace(text,
        "              showTabs: !_helperChecklistVisible,",
        "              showTabs: selectedTab != 0 || !_helperChecklistVisible,",
        'Helper navigation header visibility')
    text = replace(text,
        "      bottomNavigationBar: isMobile && !_helperChecklistVisible",
        "      bottomNavigationBar:\n          isMobile && (selectedTab != 0 || !_helperChecklistVisible)",
        'Helper mobile navigation visibility')
    for forbidden in ['StaffAvailability.busy', '<<<<<<<', '=======\n', '>>>>>>>']:
        if forbidden in text:
            raise RuntimeError(f'Main screen output contains obsolete/conflict code: {forbidden}')
    return text


def main() -> None:
    root = Path(git('rev-parse', '--show-toplevel').decode().strip())
    branch = git('branch', '--show-current').decode().strip()
    if branch != 'feature/ui-workflow-updates-nov19':
        raise RuntimeError(f'Refusing to modify unexpected branch {branch!r}.')
    # Stage 3 is the incoming origin/main in this regular merge.
    originals = {}
    for name in (PATH_B, PATH_M):
        data = git('show', ':3:' + name)
        originals[name] = data.decode('utf-8-sig').replace('\r\n', '\n')

    merged = {PATH_B: bodegero(originals[PATH_B]), PATH_M: main_screen(originals[PATH_M])}
    for path, code in merged.items():
        if code.count('{') < 100 or len(code) < 30000:
            raise RuntimeError(f'Unexpectedly small output: {path}')
        if not code.endswith('\n'):
            code += '\n'
        merged[path] = code

    backup = Path(tempfile.mkdtemp(prefix='inventory_plus_merge_backup_'))
    for name in (PATH_B, PATH_M):
        p = root / name
        if not p.is_file():
            raise RuntimeError(f'Not found: {p}')
        (backup / p.name).write_bytes(p.read_bytes())

    for name, code in merged.items():
        target = root / name
        target.write_bytes(code.encode('utf-8'))
        old_lines = originals[name].splitlines()
        new_lines = code.splitlines()
        operations = list(difflib.SequenceMatcher(a=old_lines, b=new_lines, autojunk=False).get_opcodes())
        changed = sum(max(j2-j1,i2-i1) for op,i1,i2,j1,j2 in operations if op != 'equal')
        print(f'Merged {name}: {len(new_lines)} lines, {changed} changed/inserted lines vs incoming main.')

    print('\nBoth complete Dart files are now in your repo; not staged or committed.')
    print(f'Conflicted-file originals backed up at: {backup}')
    print('Next: git diff --check; git diff --name-only --diff-filter=U')
    print('Then, when reviewed: git add -- lib/ui/bodegero_queue_page.dart lib/ui/main_screen.dart')


if __name__ == '__main__':
    try:
        main()
    except Exception as exc:
        print(f'ERROR: {exc}', file=sys.stderr)
        sys.exit(1)

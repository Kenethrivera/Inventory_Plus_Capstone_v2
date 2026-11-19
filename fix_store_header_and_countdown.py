"""Inventory Plus: repair store-hours labels and restore Bodegero logout countdown.

Run from repository root: python .\\fix_store_header_and_countdown.py

No Git commands, database writes, tests or Flutter commands are run.
Changes are conservative, backed up, and require exact source anchors.
"""
from __future__ import annotations

from datetime import datetime
from pathlib import Path
import re
import shutil
import sys
import tempfile

ROOT = Path.cwd()
MAIN = ROOT / "lib/ui/main_screen.dart"
BODEGERO = ROOT / "lib/ui/bodegero_queue_page.dart"
ADMIN_CLOCK = ROOT / "lib/ui/widgets/admin_store_status_clock.dart"
CLOCK_TEST = ROOT / "test/admin_store_status_clock_test.dart"


def once(src: str, old: str, new: str, tag: str) -> str:
    found = src.count(old)
    if found != 1:
        raise RuntimeError(f"{tag}: expected 1 anchor, found {found}; no files modified")
    return src.replace(old, new, 1)


def patch_main(s: str) -> str:
    if "Widget _buildStoreLogoutCountdownChip()" in s:
        raise RuntimeError("main_screen.dart already appears patched; stop to avoid duplicates")
    section_start = s.find("        if (_showStoreLogoutCountdownChip &&\n            _storeLogoutRemainingSeconds > 0) ...[")
    if section_start < 0:
        raise RuntimeError("Could not find existing countdown inside _buildNotificationControls")
    section_end = s.find("        NotificationBell(", section_start)
    if section_end < 0 or section_end - section_start > 3700:
        raise RuntimeError("Could not bound countdown segment safely")
    old = s[section_start:section_end]
    for required in ["Tooltip(", "_formatStoreLogoutCountdown(", "LucideIcons.timer", "const SizedBox(width: 4)"]:
        if required not in old:
            raise RuntimeError(f"Unexpected countdown UI: {required} missing")
    chip = old[old.index("          Tooltip("):old.rfind("          const SizedBox(width: 4),")].rstrip()
    if not chip.endswith(","):
        raise RuntimeError("Countown Tooltip did not end in a comma")
    # Extract original Tooltip widget with identical visual styling.
    chip = chip[:-1]  # remove list comma, now a Dart expression
    helper = (
        "  // STORE_LOGOUT_COUNTDOWN_HEADER_START\n"
        "  // Shared final-minute countdown used by all role headers. The Wait button\n"
        "  // only dismisses the dialog; it does not pause the logout deadline.\n"
        "  Widget _buildStoreLogoutCountdownChip() =>\n"
        + "\n".join(line[4:] if line.startswith("    ") else line for line in chip.splitlines())
        + ";\n"
        "  // STORE_LOGOUT_COUNTDOWN_HEADER_END\n\n"
    )
    # New shared builder sits immediately before the existing notification header control.
    anchor = "  Widget _buildNotificationControls({"
    s = once(s, anchor, helper + anchor, "insert shared countdown builder")
    s = once(
        s, old,
        "        if (_showStoreLogoutCountdownChip &&\n"
        "            _storeLogoutRemainingSeconds > 0) ...[\n"
        "          _buildStoreLogoutCountdownChip(),\n"
        "          const SizedBox(width: 4),\n"
        "        ],\n",
        "reuse shared countdown on existing role headers"
    )

    constructor_start = s.index("      return BodegeroQueuePage(")
    constructor_end = s.index("      );", constructor_start) + len("      );")
    old_ctor = s[constructor_start:constructor_end]
    new_ctor = once(
        old_ctor,
        "        onLogout: () => unawaited(_handleLogout()),\n",
        "        onLogout: () => unawaited(_handleLogout()),\n"
        "        // STORE_LOGOUT_COUNTDOWN_HEADER: Bodegero has its own app bar.\n"
        "        storeLogoutCountdown: _showStoreLogoutCountdownChip &&\n"
        "                _storeLogoutRemainingSeconds > 0\n"
        "            ? _buildStoreLogoutCountdownChip()\n"
        "            : null,\n",
        "pass countdown to Bodegero"
    )
    s = once(s, old_ctor, new_ctor, "modify Bodegero constructor in MainScreen")
    return s


def patch_bodegero(s: str) -> str:
    if "storeLogoutCountdown" in s:
        raise RuntimeError("bodegero_queue_page.dart already appears patched")
    s = once(
        s, "    this.presenceService,\n    this.imagePicker,",
        "    this.presenceService,\n    this.storeLogoutCountdown,\n    this.imagePicker,",
        "Bodegero constructor"
    )
    s = once(
        s, "  final StaffPresenceService? presenceService;\n  final ImagePicker? imagePicker;",
        "  final StaffPresenceService? presenceService;\n"
        "  // STORE_LOGOUT_COUNTDOWN_HEADER: Provided by MainScreen, not generated here.\n"
        "  final Widget? storeLogoutCountdown;\n"
        "  final ImagePicker? imagePicker;",
        "Bodegero fields"
    )
    start = s.find("  PreferredSizeWidget _header() {")
    end = s.find("  void _selectTab(int index) {", start)
    if start < 0 or end < 0:
        raise RuntimeError("Bodegero _header method not found")
    old = s[start:end]
    h = once(
        old, "    final desktop = MediaQuery.sizeOf(context).width >= 900;",
        "    final desktop = MediaQuery.sizeOf(context).width >= 900;\n"
        "    final countdown = widget.storeLogoutCountdown;\n"
        "    final mobileCountdown = !desktop && countdown != null;",
        "Bodegero _header state"
    )
    h = once(
        h,
        "      preferredSize: const Size.fromHeight(67),\n      child: StaffRoleHeader(",
        "      preferredSize: Size.fromHeight(mobileCountdown ? 98 : 67),\n"
        "      child: Column(\n"
        "        mainAxisSize: MainAxisSize.min,\n"
        "        children: [\n"
        "          StaffRoleHeader(",
        "Bodegero mobile dynamic app-bar height"
    )
    nstart = h.index("        notifications: NotificationProvider.maybeOf(context) == null")
    nend = h.index("        showTabs: desktop,", nstart)
    old_notifs = h[nstart:nend]
    must = ["NotificationBell(", "onNotificationSelected: _openNotifiedLoadingOrder,"]
    if not all(token in old_notifs for token in must):
        raise RuntimeError("Unexpected Bodegero notification widget; cannot patch safely")
    bell = old_notifs[old_notifs.index("NotificationBell("):].rstrip()
    if not bell.endswith(","):
        raise RuntimeError("Bodegero NotificationBell has unexpected terminator")
    bell = bell[:-1]  # remove end-of-property comma
    # Original NotificationBell options and callback stay unchanged.
    new_notifs = (
        "        notifications: (desktop && countdown != null) ||\n"
        "                NotificationProvider.maybeOf(context) != null\n"
        "            ? Row(\n"
        "                mainAxisSize: MainAxisSize.min,\n"
        "                children: [\n"
        "                  if (desktop && countdown != null) ...[\n"
        "                    countdown,\n"
        "                    const SizedBox(width: 4),\n"
        "                  ],\n"
        "                  if (NotificationProvider.maybeOf(context) != null)\n"
        "                    " + bell + ",\n"
        "                ],\n"
        "              )\n"
        "            : null,\n"
    )
    h = once(h, old_notifs, new_notifs, "Bodegero notifications header")
    h = once(
        h,
        "        showTabs: desktop,\n      ),\n    );",
        "        showTabs: desktop,\n"
        "          ),\n"
        "          // STORE_LOGOUT_COUNTDOWN_HEADER: Mobile uses a second compact\n"
        "          // header row so the timer cannot crowd the avatar/bell.\n"
        "          if (mobileCountdown)\n"
        "            Container(\n"
        "              height: 34,\n"
        "              width: double.infinity,\n"
        "              alignment: Alignment.centerRight,\n"
        "              padding: const EdgeInsets.only(right: 12),\n"
        "              decoration: const BoxDecoration(\n"
        "                color: Colors.white,\n"
        "                border: Border(bottom: BorderSide(color: _line)),\n"
        "              ),\n"
        "              child: countdown!,\n"
        "            ),\n"
        "        ],\n"
        "      ),\n"
        "    );",
        "Bodegero header footer"
    )
    return once(s, old, h, "replace Bodegero header")


STATUS_REPLACEMENTS = {
    "Open ┬╖ closes": "Open - closes",
    "Closed ┬╖ opens": "Closed - opens",
    "Open · closes": "Open - closes",
    "Closed · opens": "Closed - opens",
    "Open Â· closes": "Open - closes",
    "Closed Â· opens": "Closed - opens",
    "Open – closes": "Open - closes",
    "Closed – opens": "Closed - opens",
    "Open — closes": "Open - closes",
    "Closed — opens": "Closed - opens",
    "Open • closes": "Open - closes",
    "Closed • opens": "Closed - opens",
    "Closed · Maintenance · opens": "Closed - Maintenance - opens",
}


def status_fix(s: str) -> tuple[str, int]:
    changed = 0
    # Longer phrases first to correctly transform closure reasons.
    for old, new in sorted(STATUS_REPLACEMENTS.items(), key=lambda x: -len(x[0])):
        count = s.count(old)
        s = s.replace(old, new)
        changed += count
    # Unknown corrupted separators in a status label should be reviewed.
    for line in s.splitlines():
        if re.search(r"['\"](?:Open|Closed) [^'\"]* (?:closes|opens)", line):
            if not re.search(r"(?:Open|Closed) - ", line):
                raise RuntimeError("Unrecognized store status text; review: " + line.strip()[:200])
    return s, changed


def main() -> int:
    paths = [MAIN, BODEGERO, ADMIN_CLOCK, CLOCK_TEST]
    for path in paths:
        if not path.is_file():
            raise RuntimeError(f"Missing expected file: {path}")
    original = {path: path.read_text(encoding="utf-8-sig") for path in paths}
    staged = original.copy()
    staged[MAIN] = patch_main(staged[MAIN])
    staged[BODEGERO] = patch_bodegero(staged[BODEGERO])
    counts = {}
    for path in (MAIN, ADMIN_CLOCK, CLOCK_TEST):
        staged[path], counts[path] = status_fix(staged[path])
    # Other UI files that format this same exact store status label receive
    # the same ASCII-only fix, without changing other bullets/separators.
    for path in (ROOT / "lib").rglob("*.dart"):
        if path in staged:
            continue
        raw = path.read_text(encoding="utf-8-sig")
        changed, count = status_fix(raw)
        if count:
            original[path] = raw
            staged[path] = changed
            counts[path] = count

    assert "Widget _buildStoreLogoutCountdownChip()" in staged[MAIN]
    assert "storeLogoutCountdown:" in staged[MAIN]
    assert "mobileCountdown" in staged[BODEGERO]
    assert "STORE_LOGOUT_COUNTDOWN_HEADER" in staged[BODEGERO]
    modified = [p for p in staged if staged[p] != original[p]]
    # All checks and replacements are prepared before any write.
    folder = Path(tempfile.mkdtemp(prefix="inventory_plus_store_header_backup_"))
    for path in modified:
        relative = path.relative_to(ROOT)
        target = folder / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(path, target)
    try:
        for path in modified:
            path.write_text(staged[path], encoding="utf-8", newline="")
    except Exception:
        for path in modified:
            backup = folder / path.relative_to(ROOT)
            shutil.copy2(backup, path)
        raise
    print("Store status + forced-logout header patch applied successfully.")
    print(f"Backups: {folder}")
    for path in modified:
        print(f"  Modified: {path.relative_to(ROOT)} (separator replacements: {counts.get(path, 0)})")
    print("\nNo Git commit, Flutter analyzer or tests were run.")
    print("Review with: git diff --check ; git diff --stat ; git diff")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as error:
        print(f"[ERROR] {error}", file=sys.stderr)
        sys.exit(1)

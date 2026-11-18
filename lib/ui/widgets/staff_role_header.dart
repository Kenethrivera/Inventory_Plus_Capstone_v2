import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Presentation-only header shared by staff workspaces.
/// Navigation, availability, permissions, and account actions are owned by
/// the calling page.
class StaffRoleHeader extends StatelessWidget {
  const StaffRoleHeader({
    super.key,
    required this.userName,
    required this.tabs,
    required this.selectedTab,
    required this.onTabSelected,
    required this.onProfile,
    required this.onLogout,
    this.onInventory,
    this.availability,
    this.notifications,
    this.extra,
    this.showTabs = true,
  });

  final String userName;
  final List<String> tabs;
  final int selectedTab;
  final ValueChanged<int> onTabSelected;
  final VoidCallback onProfile;
  final VoidCallback onLogout;
  final VoidCallback? onInventory;
  final Widget? availability;
  final Widget? notifications;
  final Widget? extra;
  final bool showTabs;

  static const _orange = Color(0xFFC83D08);
  static const _ink = Color(0xFF211F1D);
  static const _line = Color(0xFFE8E3DF);
  static const _font = 'Hellix';

  Widget _logo({double size = 40}) => Container(
    width: size,
    height: size,
    alignment: Alignment.center,
    decoration: BoxDecoration(
      color: _orange,
      borderRadius: BorderRadius.circular(11),
    ),
    child: Icon(LucideIcons.package, size: size * 0.51, color: Colors.white),
  );

  Widget _tab(int index, {required bool mobile}) {
    final selected = index == selectedTab;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => onTabSelected(index),
        borderRadius: BorderRadius.circular(9),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          height: mobile ? 35 : 40,
          alignment: Alignment.center,
          padding: EdgeInsets.symmetric(horizontal: mobile ? 5 : 14),
          decoration: BoxDecoration(
            color: selected ? _orange : Colors.transparent,
            borderRadius: BorderRadius.circular(9),
          ),
          child: Text(
            tabs[index],
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontFamily: _font,
              fontSize: mobile ? 11 : 13,
              fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
              color: selected ? Colors.white : _ink,
            ),
          ),
        ),
      ),
    );
  }

  Widget _profileMenu({required bool compact}) {
    final name = userName.trim().isEmpty ? 'Staff' : userName.trim();
    final pieces = name.split(RegExp(r'\s+'));
    final initials = pieces.length > 1
        ? '${pieces.first[0]}${pieces.last[0]}'.toUpperCase()
        : name.substring(0, name.length < 2 ? 1 : 2).toUpperCase();
    return PopupMenuButton<String>(
      tooltip: 'Account menu',
      position: PopupMenuPosition.under,
      color: Colors.white,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: _line),
      ),
      onSelected: (action) {
        if (action == 'profile') {
          onProfile();
        } else if (action == 'inventory') {
          onInventory?.call();
        } else if (action == 'logout') {
          onLogout();
        }
      },
      itemBuilder: (context) => [
        const PopupMenuItem<String>(
          value: 'profile',
          child: Row(
            children: [
              Icon(LucideIcons.userRound, size: 17, color: _orange),
              SizedBox(width: 10),
              Text('Profile'),
            ],
          ),
        ),
        if (onInventory != null)
          const PopupMenuItem<String>(
            value: 'inventory',
            child: Row(
              children: [
                Icon(LucideIcons.package, size: 17, color: _ink),
                SizedBox(width: 10),
                Text('Inventory'),
              ],
            ),
          ),
        const PopupMenuItem<String>(
          value: 'logout',
          child: Row(
            children: [
              Icon(LucideIcons.logOut, size: 17, color: Color(0xFFDC2626)),
              SizedBox(width: 10),
              Text('Log out'),
            ],
          ),
        ),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircleAvatar(
              radius: 17,
              backgroundColor: const Color(0xFFFFF0E7),
              child: Text(
                initials,
                style: const TextStyle(
                  color: _orange,
                  fontFamily: _font,
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            if (!compact) ...[
              const SizedBox(width: 9),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 145),
                child: Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontFamily: _font,
                    fontSize: 12,
                    color: _ink,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final mobile = constraints.maxWidth < 720;
      final veryCompact = constraints.maxWidth < 390;
      final top = Row(
        children: [
          _logo(size: mobile ? 36 : 40),
          if (mobile) ...[
            const SizedBox(width: 9),
            Expanded(
              child: Text(
                'Inventory Plus',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontFamily: _font,
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                  color: _ink,
                ),
              ),
            ),
          ] else ...[
            const SizedBox(width: 18),
            if (showTabs)
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      for (var i = 0; i < tabs.length; i++) ...[
                        if (i > 0) const SizedBox(width: 4),
                        _tab(i, mobile: false),
                      ],
                    ],
                  ),
                ),
              )
            else
              const Spacer(),
          ],
          if (!mobile && extra != null) ...[extra!, const SizedBox(width: 12)],
          if (availability != null) ...[
            if (!veryCompact) const SizedBox(width: 5),
            availability!,
          ],
          if (notifications != null) ...[
            const SizedBox(width: 2),
            notifications!,
          ],
          const SizedBox(width: 5),
          _profileMenu(compact: mobile || constraints.maxWidth < 1070),
        ],
      );
      return Container(
        width: double.infinity,
        decoration: const BoxDecoration(
          color: Colors.white,
          border: Border(bottom: BorderSide(color: _line)),
        ),
        child: Padding(
          padding: EdgeInsets.fromLTRB(mobile ? 12 : 20, 0, mobile ? 8 : 20, 0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(height: mobile ? 62 : 66, child: top),
              if (mobile && showTabs) ...[
                const Divider(height: 1, color: _line),
                SizedBox(
                  height: 46,
                  child: Row(
                    children: [
                      for (var i = 0; i < tabs.length; i++)
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 2),
                            child: _tab(i, mobile: true),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      );
    },
  );
}

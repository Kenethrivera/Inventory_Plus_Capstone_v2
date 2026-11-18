import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Shared responsive staff header: Cashier-style top tabs on desktop,
/// account controls only on mobile (mobile tabs are owned by bottom navigation).
class StaffRoleHeader extends StatelessWidget {
  const StaffRoleHeader({
    super.key,
    required this.userName,
    required this.tabs,
    required this.selectedTab,
    required this.onTabSelected,
    required this.onProfile,
    required this.onLogout,
    this.availability,
    this.notifications,
    this.showTabs = true,
  });

  final String userName;
  final List<String> tabs;
  final int selectedTab;
  final ValueChanged<int> onTabSelected;
  final VoidCallback onProfile;
  final VoidCallback onLogout;
  final Widget? availability;
  final Widget? notifications;
  final bool showTabs;

  static const _orange = Color(0xFFC83D08);
  static const _ink = Color(0xFF211F1D);
  static const _line = Color(0xFFE8E3DF);
  static const _font = 'Hellix';

  Widget _logo(double size) => Container(
    width: size,
    height: size,
    alignment: Alignment.center,
    decoration: BoxDecoration(
      color: _orange,
      borderRadius: BorderRadius.circular(11),
    ),
    child: Icon(LucideIcons.package, size: size * 0.52, color: Colors.white),
  );

  
Widget _tab(int index) {
    final selected = selectedTab == index;

    return InkWell(
      onTap: () => onTabSelected(index),
      borderRadius: BorderRadius.circular(10),
      child: Container(
        height: 40,
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 15),
        decoration: BoxDecoration(
          color: selected ? _orange : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(
          tabs[index],
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: selected ? Colors.white : const Color(0xFF282522),
            fontSize: 14,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
          ),
        ),
      ),
    );
  }


  String get _initials {
    final name = userName.trim();
    if (name.isEmpty) return 'U';
    final words = name.split(RegExp(r'\s+'));
    if (words.length > 1) {
      return '${words.first[0]}${words.last[0]}'.toUpperCase();
    }
    return name.substring(0, name.length < 2 ? 1 : 2).toUpperCase();
  }

  
Widget _avatar({bool mobile = false}) => CircleAvatar(
    radius: mobile ? 17 : 20,
    backgroundColor: const Color(0xFFFFF0E7),
    child: Text(
      _initials,
      style: const TextStyle(
        color: _orange,
        fontFamily: _font,
        fontWeight: FontWeight.w700,
        fontSize: 13,
      ),
    ),
  );


  Widget _mobileAccount() => PopupMenuButton<String>(
    tooltip: 'Account menu',
    position: PopupMenuPosition.under,
    color: Colors.white,
    surfaceTintColor: Colors.transparent,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(12),
      side: const BorderSide(color: _line),
    ),
    onSelected: (value) {
      if (value == 'profile') onProfile();
      if (value == 'logout') onLogout();
    },
    itemBuilder: (context) => const [
      PopupMenuItem<String>(
        value: 'profile',
        child: Row(
          children: [
            Icon(LucideIcons.userRound, size: 17, color: _orange),
            SizedBox(width: 10),
            Text('Profile'),
          ],
        ),
      ),
      PopupMenuItem<String>(
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
      child: _avatar(mobile: true),
    ),
  );

  Widget _desktopAccount({required bool showName}) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      InkWell(
        onTap: onProfile,
        borderRadius: BorderRadius.circular(20),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _avatar(),
            if (showName) ...[
              const SizedBox(width: 12),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 170),
                child: Text(
                  userName.trim().isEmpty ? 'Staff' : userName.trim(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: _ink,
                    fontSize: 14,
                    fontFamily: _font,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
      const SizedBox(width: 14),
      IconButton(
        onPressed: onLogout,
        tooltip: 'Log out',
        icon: const Icon(LucideIcons.logOut, size: 19, color: _ink),
      ),
    ],
  );

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final mobile = constraints.maxWidth < 600;
      final showName = constraints.maxWidth >= 1100;
      return Container(
        height: mobile ? 64 : 66,
        width: double.infinity,
        decoration: const BoxDecoration(
          color: Colors.white,
          border: Border(bottom: BorderSide(color: _line)),
        ),
        padding: EdgeInsets.symmetric(
          horizontal: mobile ? 12 : (showName ? 32 : 16),
        ),
        child: Row(
          children: [
            _logo(mobile ? 34 : 40),
            if (mobile) ...[
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  'Inventory Plus',
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                  style: TextStyle(
                    fontFamily: _font,
                    fontSize: 15,
                    color: _ink,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ] else ...[
              const SizedBox(width: 20),
              Expanded(
                child: showTabs
                    ? SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children: [
                            for (var i = 0; i < tabs.length; i++) ...[
                              if (i > 0) const SizedBox(width: 10),
                              _tab(i),
                            ],
                          ],
                        ),
                      )
                    : const SizedBox.shrink(),
              ),
            ],
            if (availability != null) ...[
              const SizedBox(width: 4),
              availability!,
            ],
            if (notifications != null) ...[
              const SizedBox(width: 2),
              notifications!,
            ],
            SizedBox(width: mobile ? 5 : 14),
            if (mobile)
              _mobileAccount()
            else
              _desktopAccount(showName: showName),
          ],
        ),
      );
    },
  );
}

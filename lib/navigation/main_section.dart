enum MainSection {
  dashboard('dashboard', <String>{'admin'}),
  forecasting('forecasting', <String>{'admin'}),
  pos('pos', <String>{'admin', 'staff', 'cashier'}),
  queue('queue', <String>{'admin', 'helper'}),
  inventory('inventory', <String>{'admin', 'staff', 'cashier', 'helper'}),
  history('history', <String>{'staff', 'cashier', 'helper'}),
  transactions('transactions', <String>{'admin'}),
  storeMap('store-map', <String>{'admin'}),
  systemSettings('system-settings', <String>{'admin'});

  const MainSection(this.slug, this.allowedRoles);

  final String slug;
  final Set<String> allowedRoles;

  String get routePath => '/main/$slug';

  bool allowsRole(String role) => allowedRoles.contains(role.toLowerCase());

  static MainSection? fromPath(String? path) {
    if (path == null || path.isEmpty) return null;
    var normalized = path.trim();
    if (normalized.startsWith('#')) normalized = normalized.substring(1);
    final queryIndex = normalized.indexOf('?');
    if (queryIndex >= 0) normalized = normalized.substring(0, queryIndex);
    normalized = normalized.replaceAll(RegExp(r'/+$'), '');
    if (!normalized.startsWith('/main/')) return null;
    final slug = normalized.substring('/main/'.length);
    for (final section in MainSection.values) {
      if (section.slug == slug) return section;
    }
    return null;
  }

  static List<MainSection> forRole(String role) {
    switch (role.toLowerCase()) {
      case 'admin':
        return const <MainSection>[
          dashboard,
          forecasting,
          pos,
          queue,
          inventory,
          transactions,
          storeMap,
          systemSettings,
        ];
      case 'helper':
        return const <MainSection>[queue, inventory, history];
      case 'staff':
      case 'cashier':
        return const <MainSection>[pos, inventory, history];
      default:
        return const <MainSection>[inventory];
    }
  }

  static MainSection defaultForRole(String role) => forRole(role).first;

  static MainSection resolveForRole(MainSection? requested, String role) {
    final sections = forRole(role);
    return requested != null && sections.contains(requested)
        ? requested
        : sections.first;
  }
}

class AuthenticatedMainRoute {
  const AuthenticatedMainRoute();
}

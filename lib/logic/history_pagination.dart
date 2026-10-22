import 'dart:collection';

const int historyPageSize = 20;
const int historyPageCacheLimit = 32;

enum HistoryDomain {
  adminSales,
  adminActivity,
  cashierOrders,
  cashierRestocks,
  helperWork,
}

class HistoryQueryFamily {
  const HistoryQueryFamily({
    required this.accountId,
    required this.role,
    required this.locationId,
    required this.domain,
    required this.periodMode,
    required this.periodStart,
    required this.periodEndExclusive,
    required this.filter,
    required this.search,
    required this.sort,
    this.pageSize = historyPageSize,
  });

  final String accountId;
  final String role;
  final String locationId;
  final HistoryDomain domain;
  final String periodMode;
  final DateTime periodStart;
  final DateTime periodEndExclusive;
  final String filter;
  final String search;
  final String sort;
  final int pageSize;

  String get normalizedSearch => search.trim().toLowerCase();

  Map<String, dynamic> toRpcParameters(
    int page, {
    required String sessionToken,
  }) => <String, dynamic>{
    'p_session_token': sessionToken,
    'p_domain': domain.name,
    'p_period_start': periodStart.toUtc().toIso8601String(),
    'p_period_end': periodEndExclusive.toUtc().toIso8601String(),
    'p_filter': filter.toLowerCase(),
    'p_search': normalizedSearch,
    'p_page': page,
    'p_page_size': pageSize,
  };

  @override
  bool operator ==(Object other) =>
      other is HistoryQueryFamily &&
      accountId == other.accountId &&
      role.toLowerCase() == other.role.toLowerCase() &&
      locationId == other.locationId &&
      domain == other.domain &&
      periodMode == other.periodMode &&
      periodStart.toUtc() == other.periodStart.toUtc() &&
      periodEndExclusive.toUtc() == other.periodEndExclusive.toUtc() &&
      filter.toLowerCase() == other.filter.toLowerCase() &&
      normalizedSearch == other.normalizedSearch &&
      sort == other.sort &&
      pageSize == other.pageSize;

  @override
  int get hashCode => Object.hash(
    accountId,
    role.toLowerCase(),
    locationId,
    domain,
    periodMode,
    periodStart.toUtc(),
    periodEndExclusive.toUtc(),
    filter.toLowerCase(),
    normalizedSearch,
    sort,
    pageSize,
  );
}

class HistoryPageKey {
  const HistoryPageKey(this.family, this.page);

  final HistoryQueryFamily family;
  final int page;

  @override
  bool operator ==(Object other) =>
      other is HistoryPageKey && family == other.family && page == other.page;

  @override
  int get hashCode => Object.hash(family, page);
}

class HistoryPageResult<T> {
  const HistoryPageResult({
    required this.family,
    required this.page,
    required this.records,
    required this.totalCount,
    required this.metrics,
    required this.loadedAt,
    this.stale = false,
  });

  final HistoryQueryFamily? family;
  final int page;
  final List<T> records;
  final int totalCount;
  final Map<String, num> metrics;
  final DateTime loadedAt;
  final bool stale;

  int totalPagesFor(int pageSize) =>
      totalCount == 0 ? 1 : (totalCount / pageSize).ceil();

  HistoryPageResult<T> copyWith({bool? stale}) => HistoryPageResult<T>(
    family: family,
    page: page,
    records: records,
    totalCount: totalCount,
    metrics: metrics,
    loadedAt: loadedAt,
    stale: stale ?? this.stale,
  );
}

class HistoryPageCache<T> {
  HistoryPageCache({this.maximumEntries = historyPageCacheLimit});

  final int maximumEntries;
  final LinkedHashMap<HistoryPageKey, HistoryPageResult<T>> _entries =
      LinkedHashMap<HistoryPageKey, HistoryPageResult<T>>();

  int get length => _entries.length;

  HistoryPageResult<T>? read(HistoryPageKey key) {
    final value = _entries.remove(key);
    if (value != null) _entries[key] = value;
    return value;
  }

  void write(HistoryPageKey key, HistoryPageResult<T> value) {
    _entries.remove(key);
    _entries[key] = value;
    while (_entries.length > maximumEntries) {
      _entries.remove(_entries.keys.first);
    }
  }

  void markStale({String? locationId, Set<HistoryDomain>? domains}) {
    for (final entry in _entries.entries.toList(growable: false)) {
      final family = entry.key.family;
      if (locationId != null && family.locationId != locationId) continue;
      if (domains != null && !domains.contains(family.domain)) continue;
      _entries[entry.key] = entry.value.copyWith(stale: true);
    }
  }

  void markFamilyStale(HistoryQueryFamily family) {
    for (final entry in _entries.entries.toList(growable: false)) {
      if (entry.key.family == family) {
        _entries[entry.key] = entry.value.copyWith(stale: true);
      }
    }
  }

  void clear() => _entries.clear();
}

enum HistoryInvalidationKind { orderHistory, transactions, scope }

class HistoryInvalidation {
  const HistoryInvalidation({required this.kind, required this.locationId});

  final HistoryInvalidationKind kind;
  final String locationId;

  bool affects(HistoryDomain domain) => switch (kind) {
    HistoryInvalidationKind.scope => true,
    HistoryInvalidationKind.orderHistory =>
      domain == HistoryDomain.adminSales ||
          domain == HistoryDomain.cashierOrders ||
          domain == HistoryDomain.helperWork,
    HistoryInvalidationKind.transactions =>
      domain == HistoryDomain.adminActivity ||
          domain == HistoryDomain.cashierRestocks,
  };
}

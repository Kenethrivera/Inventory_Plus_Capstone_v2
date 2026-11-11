import 'package:flutter_test/flutter_test.dart';
import 'package:inventory_plus/data/inventory.dart';
import 'package:inventory_plus/logic/history_pagination.dart';

void main() {
  HistoryQueryFamily family({String search = '', String location = 'store-a'}) {
    return HistoryQueryFamily(
      accountId: '7',
      role: 'Admin',
      locationId: location,
      domain: HistoryDomain.adminSales,
      periodMode: 'weekly',
      periodStart: DateTime(2026, 10, 19),
      periodEndExclusive: DateTime(2026, 10, 26),
      filter: 'Completed',
      search: search,
      sort: 'event_at_desc_id_desc',
    );
  }

  HistoryPageResult<String> result(HistoryQueryFamily query, int page) =>
      HistoryPageResult<String>(
        family: query,
        page: page,
        records: const ['record'],
        totalCount: 63,
        metrics: const {'orders': 63},
        loadedAt: DateTime(2026, 10, 22),
      );

  test('query identity normalizes case-insensitive trimmed search', () {
    expect(family(search: ' hammer '), family(search: 'HAMMER'));
    expect(
      family(search: 'hammer'),
      isNot(family(search: 'hammer', location: 'store-b')),
    );
  });

  test('RPC parameters authorize with session token, not identity claims', () {
    final params = family().toRpcParameters(2, sessionToken: 'opaque-token');
    expect(params['p_session_token'], 'opaque-token');
    expect(params['p_page'], 2);
    expect(params, isNot(contains('p_account_id')));
    expect(params, isNot(contains('p_role')));
    expect(params, isNot(contains('p_location_id')));
  });

  test('page count never falls below one', () {
    expect(result(family(), 1).totalPagesFor(historyPageSize), 4);
    final empty = HistoryPageResult<String>(
      family: family(),
      page: 1,
      records: const [],
      totalCount: 0,
      metrics: const {},
      loadedAt: DateTime(2026, 10, 22),
    );
    expect(empty.totalPagesFor(historyPageSize), 1);
  });

  test('order history invalidation affects only logical order domains', () {
    const invalidation = HistoryInvalidation(
      kind: HistoryInvalidationKind.orderHistory,
      locationId: 'store-a',
    );

    expect(invalidation.affects(HistoryDomain.adminSales), isTrue);
    expect(invalidation.affects(HistoryDomain.cashierOrders), isTrue);
    expect(invalidation.affects(HistoryDomain.helperWork), isTrue);
    expect(invalidation.affects(HistoryDomain.adminActivity), isFalse);
    expect(invalidation.affects(HistoryDomain.cashierRestocks), isFalse);
  });

  test('order parser uses the server canonical lifecycle event timestamp', () {
    final order = CustomerOrder.fromJson(<String, dynamic>{
      'id': 'order-1',
      'status': 'prepared',
      'created_at': '2026-10-22T04:40:00Z',
      'prepared_at': '2026-10-22T05:05:00Z',
      'event_at': '2026-10-22T05:10:00Z',
      'items': const <dynamic>[],
    });

    expect(order.eventAt.toUtc(), DateTime.utc(2026, 10, 22, 5, 10));
  });

  test('cache is LRU bounded and can stale a query family', () {
    final cache = HistoryPageCache<String>(maximumEntries: 2);
    final query = family();
    final first = HistoryPageKey(query, 1);
    final second = HistoryPageKey(query, 2);
    final third = HistoryPageKey(query, 3);
    cache.write(first, result(query, 1));
    cache.write(second, result(query, 2));
    expect(cache.read(first), isNotNull); // first is now most recently used.
    cache.write(third, result(query, 3));
    expect(cache.read(second), isNull);
    expect(cache.length, 2);

    cache.markFamilyStale(query);
    expect(cache.read(first)?.stale, isTrue);
    expect(cache.read(first)?.records, const ['record']);
    expect(cache.read(third)?.stale, isTrue);
  });

  test(
    'fresh page revisits avoid fetches and stale pages fetch once',
    () async {
      final cache = HistoryPageCache<String>(maximumEntries: 32);
      final query = family();
      var fetchCount = 0;

      Future<HistoryPageResult<String>> load(int page) async {
        final key = HistoryPageKey(query, page);
        final cached = cache.read(key);
        if (cached != null && !cached.stale) return cached;

        fetchCount += 1;
        final fetched = result(query, page);
        cache.write(key, fetched);
        return fetched;
      }

      await load(1);
      expect(fetchCount, 1);
      await load(2);
      expect(fetchCount, 2);

      await load(1);
      await load(2);
      expect(fetchCount, 2);

      cache.markFamilyStale(query);
      await load(2);
      expect(fetchCount, 3);
      await load(2);
      expect(fetchCount, 3);
    },
  );
}

class BodegeroLoadingItem {
  const BodegeroLoadingItem({required this.name, required this.quantity});

  final String name;
  final num quantity;

  factory BodegeroLoadingItem.fromJson(Map<String, dynamic> json) =>
      BodegeroLoadingItem(
        name: json['product_name']?.toString() ?? 'Unknown product',
        quantity: (json['quantity'] as num?) ?? 0,
      );
}

class BodegeroLoadingRecord {
  const BodegeroLoadingRecord({
    required this.orderId,
    required this.truckPlate,
    required this.status,
    required this.capturedAt,
    required this.items,
  });

  final String orderId;
  final String truckPlate;
  final String status;
  final DateTime capturedAt;
  final List<BodegeroLoadingItem> items;

  factory BodegeroLoadingRecord.fromJson(Map<String, dynamic> json) =>
      BodegeroLoadingRecord(
        orderId: json['order_id']?.toString() ?? '',
        truckPlate: json['truck_plate']?.toString() ?? '',
        status: json['status']?.toString() ?? '',
        capturedAt:
            DateTime.tryParse(json['captured_at']?.toString() ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0),
        items: List<BodegeroLoadingItem>.unmodifiable(
          (json['items'] as List<dynamic>? ?? const []).map(
            (item) => BodegeroLoadingItem.fromJson(
              Map<String, dynamic>.from(item as Map),
            ),
          ),
        ),
      );
}

class BodegeroLoadingHistoryPage {
  const BodegeroLoadingHistoryPage({
    required this.records,
    required this.totalCount,
    required this.page,
    required this.pageSize,
  });

  final List<BodegeroLoadingRecord> records;
  final int totalCount;
  final int page;
  final int pageSize;

  int get totalPages => totalCount == 0 ? 1 : (totalCount / pageSize).ceil();

  factory BodegeroLoadingHistoryPage.fromJson(Map<String, dynamic> json) =>
      BodegeroLoadingHistoryPage(
        records: List<BodegeroLoadingRecord>.unmodifiable(
          (json['records'] as List<dynamic>? ?? const []).map(
            (record) => BodegeroLoadingRecord.fromJson(
              Map<String, dynamic>.from(record as Map),
            ),
          ),
        ),
        totalCount: (json['total_count'] as num?)?.toInt() ?? 0,
        page: (json['page'] as num?)?.toInt() ?? 1,
        pageSize: (json['page_size'] as num?)?.toInt() ?? 20,
      );
}

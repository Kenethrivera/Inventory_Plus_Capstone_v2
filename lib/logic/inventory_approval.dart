enum InventoryApprovalType { restock, writeOff, discount }

extension InventoryApprovalTypeValue on InventoryApprovalType {
  String get databaseValue => switch (this) {
    InventoryApprovalType.restock => 'restock',
    InventoryApprovalType.writeOff => 'write_off',
    InventoryApprovalType.discount => 'discount',
  };

  String get label => switch (this) {
    InventoryApprovalType.restock => 'Restock',
    InventoryApprovalType.writeOff => 'Write-off',
    InventoryApprovalType.discount => 'Discount',
  };

  static InventoryApprovalType fromDatabase(String value) => switch (value) {
    'restock' => InventoryApprovalType.restock,
    'write_off' => InventoryApprovalType.writeOff,
    'discount' => InventoryApprovalType.discount,
    _ => throw FormatException('Unknown approval request type: $value'),
  };
}

enum InventoryApprovalStatus { pending, approved, rejected }

extension InventoryApprovalStatusValue on InventoryApprovalStatus {
  String get databaseValue => name;

  String get label => switch (this) {
    InventoryApprovalStatus.pending => 'Pending',
    InventoryApprovalStatus.approved => 'Approved',
    InventoryApprovalStatus.rejected => 'Rejected',
  };

  static InventoryApprovalStatus fromDatabase(String value) =>
      InventoryApprovalStatus.values.firstWhere(
        (status) => status.databaseValue == value,
        orElse: () =>
            throw FormatException('Unknown approval request status: $value'),
      );
}

class InventoryApprovalRequest {
  const InventoryApprovalRequest({
    required this.id,
    required this.locationId,
    required this.type,
    required this.status,
    required this.requestedById,
    required this.requestedByName,
    required this.requestedByRole,
    required this.requestedAt,
    required this.productId,
    required this.productName,
    required this.productSku,
    required this.unit,
    required this.quantity,
    required this.stockAtRequest,
    required this.currentStock,
    this.reason,
    this.note,
    this.reviewedById,
    this.reviewedByName,
    this.reviewedAt,
    this.reviewNote,
    this.transactionId,
    this.proofStoragePath,
    this.proofFileName,
    this.proofMimeType,
    this.discountMode,
    this.discountValue,
    this.discountAmount,
    this.discountEffectivePercentage,
    this.subtotalAmount,
    this.cartFingerprint,
    this.checkoutToken,
    this.usedAt,
    this.usedOrderId,
  });

  final String id;
  final String locationId;
  final InventoryApprovalType type;
  final InventoryApprovalStatus status;
  final String requestedById;
  final String requestedByName;
  final String requestedByRole;
  final DateTime requestedAt;
  final String productId;
  final String productName;
  final String productSku;
  final String unit;
  final double quantity;
  final double stockAtRequest;
  final double currentStock;
  final String? reason;
  final String? note;
  final String? reviewedById;
  final String? reviewedByName;
  final DateTime? reviewedAt;
  final String? reviewNote;
  final String? transactionId;
  final String? proofStoragePath;
  final String? proofFileName;
  final String? proofMimeType;
  final String? discountMode;
  final double? discountValue;
  final double? discountAmount;
  final double? discountEffectivePercentage;
  final double? subtotalAmount;
  final String? cartFingerprint;
  final String? checkoutToken;
  final DateTime? usedAt;
  final String? usedOrderId;

  bool get hasProof => proofStoragePath?.isNotEmpty ?? false;

  bool get isDiscount => type == InventoryApprovalType.discount;

  double get resultingTotal => (subtotalAmount ?? 0) - (discountAmount ?? 0);

  double get resultingStock => type == InventoryApprovalType.restock
      ? currentStock + quantity
      : currentStock - quantity;

  bool get hasStockConflict =>
      type == InventoryApprovalType.writeOff && quantity > currentStock;

  factory InventoryApprovalRequest.fromJson(Map<String, dynamic> json) {
    double number(String key) => (json[key] as num?)?.toDouble() ?? 0;
    DateTime? optionalDate(String key) => json[key] == null
        ? null
        : DateTime.parse(json[key].toString()).toLocal();

    return InventoryApprovalRequest(
      id: json['id'].toString(),
      locationId: json['location_id'].toString(),
      type: InventoryApprovalTypeValue.fromDatabase(
        json['request_type'].toString(),
      ),
      status: InventoryApprovalStatusValue.fromDatabase(
        json['status'].toString(),
      ),
      requestedById: json['requested_by_id'].toString(),
      requestedByName: json['requested_by_name']?.toString() ?? 'Unknown User',
      requestedByRole: json['requested_by_role']?.toString() ?? 'staff',
      requestedAt: DateTime.parse(json['requested_at'].toString()).toLocal(),
      productId: json['product_id']?.toString() ?? '',
      productName: json['product_name']?.toString() ?? '',
      productSku: json['product_sku']?.toString() ?? '',
      unit: json['unit']?.toString() ?? 'pcs',
      quantity: number('requested_quantity'),
      stockAtRequest: number('stock_at_request'),
      currentStock: number('current_stock'),
      reason: json['reason']?.toString(),
      note: json['note']?.toString(),
      reviewedById: json['reviewed_by_id']?.toString(),
      reviewedByName: json['reviewed_by_name']?.toString(),
      reviewedAt: optionalDate('reviewed_at'),
      reviewNote: json['review_note']?.toString(),
      transactionId: json['transaction_id']?.toString(),
      proofStoragePath: json['proof_storage_path']?.toString(),
      proofFileName: json['proof_file_name']?.toString(),
      proofMimeType: json['proof_mime_type']?.toString(),
      discountMode: json['discount_mode']?.toString(),
      discountValue: json['discount_value'] == null
          ? null
          : number('discount_value'),
      discountAmount: json['discount_amount'] == null
          ? null
          : number('discount_amount'),
      discountEffectivePercentage: json['discount_effective_percentage'] == null
          ? null
          : number('discount_effective_percentage'),
      subtotalAmount: json['subtotal_amount'] == null
          ? null
          : number('subtotal_amount'),
      cartFingerprint: json['cart_fingerprint']?.toString(),
      checkoutToken: json['checkout_token']?.toString(),
      usedAt: optionalDate('used_at'),
      usedOrderId: json['used_order_id']?.toString(),
    );
  }
}

class InventoryApprovalPageKey {
  const InventoryApprovalPageKey({
    required this.accountId,
    required this.locationId,
    required this.status,
    required this.page,
    this.pageSize = 20,
  });

  final String accountId;
  final String locationId;
  final InventoryApprovalStatus status;
  final int page;
  final int pageSize;

  @override
  bool operator ==(Object other) =>
      other is InventoryApprovalPageKey &&
      other.accountId == accountId &&
      other.locationId == locationId &&
      other.status == status &&
      other.page == page &&
      other.pageSize == pageSize;

  @override
  int get hashCode =>
      Object.hash(accountId, locationId, status, page, pageSize);
}

class InventoryApprovalPage {
  const InventoryApprovalPage({
    required this.key,
    required this.requests,
    required this.totalCount,
    required this.loadedAt,
    this.stale = false,
  });

  final InventoryApprovalPageKey key;
  final List<InventoryApprovalRequest> requests;
  final int totalCount;
  final DateTime loadedAt;
  final bool stale;

  int get totalPages => totalCount == 0
      ? 1
      : (totalCount / key.pageSize).ceil().clamp(1, 1 << 31);

  InventoryApprovalPage markStale() => InventoryApprovalPage(
    key: key,
    requests: requests,
    totalCount: totalCount,
    loadedAt: loadedAt,
    stale: true,
  );
}

class InventoryApprovalPageCache {
  InventoryApprovalPageCache({this.maximumEntries = 6});

  final int maximumEntries;
  final Map<InventoryApprovalPageKey, InventoryApprovalPage> _entries = {};

  int get length => _entries.length;

  InventoryApprovalPage? read(InventoryApprovalPageKey key) {
    final value = _entries.remove(key);
    if (value != null) _entries[key] = value;
    return value;
  }

  void write(InventoryApprovalPage page) {
    _entries.remove(page.key);
    _entries[page.key] = page;
    while (_entries.length > maximumEntries) {
      _entries.remove(_entries.keys.first);
    }
  }

  void markAllStale() {
    for (final entry in _entries.entries.toList(growable: false)) {
      _entries[entry.key] = entry.value.markStale();
    }
  }

  void clear() => _entries.clear();
}

typedef InventoryApprovalNotificationCallback =
    Future<void> Function(InventoryApprovalRequest request);

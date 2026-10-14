import 'package:flutter/material.dart';

enum ElementType { door, rack, shelf, cashier, wall }

class MapElement {
  final String id;
  final ElementType type;
  Offset position;
  Size size;
  final String label;
  double rotation;

  MapElement({
    required this.id,
    required this.type,
    required this.position,
    this.size = const Size(100, 100),
    this.label = "",
    this.rotation = 0.0,
  });

  MapElement copyWith({
    String? id,
    ElementType? type,
    Offset? position,
    Size? size,
    String? label,
    double? rotation,
  }) {
    return MapElement(
      id: id ?? this.id,
      type: type ?? this.type,
      position: position ?? this.position,
      size: size ?? this.size,
      label: label ?? this.label,
      rotation: rotation ?? this.rotation,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'type': type.index,
    'dx': position.dx,
    'dy': position.dy,
    'width': size.width,
    'height': size.height,
    'label': label,
    'rotation': rotation,
  };  

  factory MapElement.fromJson(Map<String, dynamic> json) => MapElement(
    id: json['id'],
    type: ElementType.values[json['type'] ?? 0],
    position: Offset(
      (json['dx'] ?? 0.0).toDouble(),
      (json['dy'] ?? 0.0).toDouble(),
    ),
    size: Size(
      (json['width'] ?? 100.0).toDouble(),
      (json['height'] ?? 100.0).toDouble(),
    ),
    label: json['label'] ?? "",
    rotation: (json['rotation'] ?? 0.0).toDouble(),
  );
}

class ItemLocation {
  final String aisle;
  final int shelf;
  final String section;

  ItemLocation({
    required this.aisle,
    required this.shelf,
    required this.section,
  });
}

class InventoryItem {
  final String id;
  final String name;
  final String sku;
  final double price;
  double quantity;
  final double maxQuantity; // ADDED MAX QUANTITY
  final String category;
  final String description;
  final String imageUrl;
  final ItemLocation? location;
  final String? locationId;
  final String? manufacturer;
  final String? model;
  final String? productSize;
  final String? shelfLevel;
  final String? binNumber;
  final String unit;

  InventoryItem({
    required this.id,
    required this.name,
    required this.sku,
    required this.price,
    required this.quantity,
    required this.maxQuantity, // ADDED MAX QUANTITY
    required this.category,
    required this.description,
    required this.imageUrl,
    this.location,
    this.locationId,
    this.manufacturer,
    this.model,
    this.productSize,
    this.shelfLevel,
    this.binNumber,
    this.unit = 'pcs',
  });

  factory InventoryItem.fromSupabase(Map<String, dynamic> map) {
    return InventoryItem(
      id: map['id'].toString(),
      sku: map['sku'] ?? '',
      name: map['product_name'] ?? 'Unknown Item',
      category: map['category'] ?? 'General',
      price: (map['product_price'] as num?)?.toDouble() ?? 0.0,
      quantity: (map['product_quantity'] as num?)?.toDouble() ?? 0.0,
      maxQuantity:
          (map['max_quantity'] as num?)?.toDouble() ??
          100.0, // READ FROM DB WITH FALLBACK
      description: map['description'] ?? '',
      imageUrl: map['image_url'] ?? '',
      locationId: map['map_element_id'],
      manufacturer: map['manufacturer'],
      model: map['model'],
      productSize: map['product_size'],
      shelfLevel: map['shelf_level'],
      binNumber: map['bin_number'],
      unit: map['unit'] ?? 'pcs',
    );
  }

  InventoryItem copyWith({
    String? name,
    String? sku,
    double? price,
    double? quantity,
    double? maxQuantity, // ADDED MAX QUANTITY
    String? category,
    String? description,
    String? imageUrl,
    String? locationId,
    String? manufacturer,
    String? model,
    String? productSize,
    String? shelfLevel,
    String? binNumber,
    String? unit,
  }) {
    return InventoryItem(
      id: id,
      name: name ?? this.name,
      sku: sku ?? this.sku,
      price: price ?? this.price,
      quantity: quantity ?? this.quantity,
      maxQuantity: maxQuantity ?? this.maxQuantity, // ADDED MAX QUANTITY
      category: category ?? this.category,
      description: description ?? this.description,
      imageUrl: imageUrl ?? this.imageUrl,
      locationId: locationId ?? this.locationId,
      manufacturer: manufacturer ?? this.manufacturer,
      model: model ?? this.model,
      productSize: productSize ?? this.productSize,
      shelfLevel: shelfLevel ?? this.shelfLevel,
      binNumber: binNumber ?? this.binNumber,
      unit: unit ?? this.unit,
    );
  }
}

class CustomerOrderItem {
  final String productId;
  final String productName;
  final double quantity;

  CustomerOrderItem({
    required this.productId,
    required this.productName,
    required this.quantity,
  });

  Map<String, dynamic> toJson() => {
        'product_id': productId,
        'product_name': productName,
        'quantity': quantity,
      };

  factory CustomerOrderItem.fromJson(Map<String, dynamic> json) =>
      CustomerOrderItem(
        // The fallback ?? checks ensure it can read both your old format and the new format
        productId: json['product_id']?.toString() ?? json['productId']?.toString() ?? '',
        productName: json['product_name']?.toString() ?? json['productName']?.toString() ?? 'Unknown',
        quantity: (json['quantity'] as num?)?.toDouble() ?? 0.0,
      );
}
class CustomerOrder {
  final String id;
  final List<CustomerOrderItem> items;
  final String status;
  final DateTime createdAt;
  final double totalAmount;
  final double discountAmount;

  final String? createdById;
  final String? createdByName;

  final String? assignedHelperId;
  final String? assignedHelperName;
  final DateTime? assignedAt;
  final String? assignedByAdminId;
  final String? assignedByAdminName;

  final String? preparedById;
  final String? preparedByName;
  final DateTime? preparedAt;

  final String? completedById;
  final String? completedByName;
  final DateTime? completedAt;

  final String? cancelledById;
  final String? cancelledByName;
  final DateTime? cancelledAt;

  final String? returnedById;
  final String? returnedByName;
  final DateTime? returnedAt;
  final String? returnReason;

  CustomerOrder({
    required this.id,
    required this.items,
    required this.status,
    required this.createdAt,
    this.totalAmount = 0.0,
    this.discountAmount = 0.0,
    this.createdById,
    this.createdByName,
    this.assignedHelperId,
    this.assignedHelperName,
    this.assignedAt,
    this.assignedByAdminId,
    this.assignedByAdminName,
    this.preparedById,
    this.preparedByName,
    this.preparedAt,
    this.completedById,
    this.completedByName,
    this.completedAt,
    this.cancelledById,
    this.cancelledByName,
    this.cancelledAt,
    this.returnedById,
    this.returnedByName,
    this.returnedAt,
    this.returnReason,
  });

  factory CustomerOrder.fromJson(Map<String, dynamic> json) {
    return CustomerOrder(
      id: json['id'].toString(),
      status: json['status'] ?? 'pending',
      createdAt: _parseDate(json['created_at']) ?? DateTime.now(),
      totalAmount: (json['total_amount'] as num?)?.toDouble() ?? 0.0,
      discountAmount: (json['discount_amount'] as num?)?.toDouble() ?? 0.0,

      createdById: json['created_by_id']?.toString(),
      createdByName: json['created_by_name']?.toString(),

      assignedHelperId: json['assigned_helper_id']?.toString(),
      assignedHelperName: json['assigned_helper_name']?.toString(),
      assignedAt: _parseDate(json['assigned_at']),
      assignedByAdminId: json['assigned_by_admin_id']?.toString(),
      assignedByAdminName: json['assigned_by_admin_name']?.toString(),

      preparedById: json['prepared_by_id']?.toString(),
      preparedByName: json['prepared_by_name']?.toString(),
      preparedAt: _parseDate(json['prepared_at']),

      completedById: json['completed_by_id']?.toString(),
      completedByName: json['completed_by_name']?.toString(),
      completedAt: _parseDate(json['completed_at']),

      cancelledById: json['cancelled_by_id']?.toString(),
      cancelledByName: json['cancelled_by_name']?.toString(),
      cancelledAt: _parseDate(json['cancelled_at']),

      returnedById: json['returned_by_id']?.toString(),
      returnedByName: json['returned_by_name']?.toString(),
      returnedAt: _parseDate(json['returned_at']),
      returnReason: json['return_reason']?.toString(),

      items:
          (json['items'] as List<dynamic>?)
              ?.map(
                (i) => CustomerOrderItem.fromJson(
                  Map<String, dynamic>.from(i as Map),
                ),
              )
              .toList() ??
          [],
    );
  }

  static DateTime? _parseDate(dynamic value) {
    if (value == null) return null;

    try {
      return DateTime.parse(value.toString()).toLocal();
    } catch (_) {
      return null;
    }
  }
}

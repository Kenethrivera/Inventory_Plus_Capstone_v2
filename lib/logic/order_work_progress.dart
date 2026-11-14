import '../data/inventory.dart';

/// Progress for the two assignments carried by one customer order.
class OrderWorkProgress {
  const OrderWorkProgress({
    required this.lightPicked,
    required this.lightTotal,
    required this.heavyScanned,
    required this.heavyTotal,
    required this.loadingVerified,
  });

  factory OrderWorkProgress.fromOrder(CustomerOrder order) {
    final light = order.items.where((item) => !item.requiresLoading).toList();
    final heavy = order.items.where((item) => item.requiresLoading).toList();
    return OrderWorkProgress(
      lightPicked: light.where((item) => item.picked).length,
      lightTotal: light.length,
      heavyScanned: heavy.where((item) => item.heavyVerified).length,
      heavyTotal: heavy.length,
      loadingVerified: order.loadingVerifiedAt != null,
    );
  }

  final int lightPicked;
  final int lightTotal;
  final int heavyScanned;
  final int heavyTotal;
  final bool loadingVerified;

  bool get isMixed => lightTotal > 0 && heavyTotal > 0;
  bool get lightComplete => lightPicked == lightTotal;
  bool get heavyComplete =>
      heavyTotal == 0 || (loadingVerified && heavyScanned == heavyTotal);
  bool get bothComplete => lightComplete && heavyComplete;

  String get helperSummary => '$lightPicked/$lightTotal light items picked';
  String get bodegeroSummary => loadingVerified
      ? 'Heavy loading verified'
      : '$heavyScanned/$heavyTotal heavy QR verified · loading pending';
}

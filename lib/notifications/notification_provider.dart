import 'package:flutter/material.dart';

import 'notification_controller.dart';

class NotificationProvider extends InheritedNotifier<NotificationController> {
  const NotificationProvider({
    super.key,
    required NotificationController controller,
    required Widget child,
  }) : super(notifier: controller, child: child);

  static NotificationController of(BuildContext context) {
    final provider = context
        .dependOnInheritedWidgetOfExactType<NotificationProvider>();

    assert(provider != null, 'NotificationProvider not found in widget tree.');

    return provider!.notifier!;
  }

  static NotificationController? maybeOf(BuildContext context) {
    final provider = context
        .dependOnInheritedWidgetOfExactType<NotificationProvider>();

    return provider?.notifier;
  }
}

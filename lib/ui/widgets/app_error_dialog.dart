import 'package:flutter/material.dart';

import 'app_dialog.dart';

class AppErrorDialog extends StatelessWidget {
  const AppErrorDialog({
    super.key,
    required this.title,
    required this.message,
    this.onRetry,
    this.retryLabel = 'Try Again',
  });

  final String title;
  final String message;
  final VoidCallback? onRetry;
  final String retryLabel;

  @override
  Widget build(BuildContext context) {
    return AppDialog(
      icon: Icons.error_outline,
      color: const Color(0xFFDC2626),
      title: title,
      child: Text(
        message,
        style: const TextStyle(
          color: Color(0xFF475569),
          fontSize: 14,
          height: 1.5,
        ),
      ),
      actions: [
        OutlinedButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
        if (onRetry != null)
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              onRetry!();
            },
            child: Text(retryLabel),
          ),
      ],
    );
  }
}

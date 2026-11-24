import 'dart:async';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

class AppToast {
  AppToast._();
  static OverlayEntry? _current;

  static void success(BuildContext context, String message) =>
      showOn(Overlay.of(context, rootOverlay: true), message);

  static void error(BuildContext context, String message) =>
      showOn(Overlay.of(context, rootOverlay: true), message, isError: true);

  /// One persistent overlay entry for a multi-stage operation.
  static AppToastLoadingHandle loading(BuildContext context, String message) {
    _current?.remove();
    late final AppToastLoadingHandle handle;
    late final OverlayEntry entry;
    entry = OverlayEntry(builder: (_) => _LoadingToastView(message: handle._message));
    handle = AppToastLoadingHandle._(entry, message);
    _current = entry;
    Overlay.of(context, rootOverlay: true).insert(entry);
    return handle;
  }

  /// Use this when the calling widget is about to be disposed (e.g. after delete).
  static void showOn(
    OverlayState overlay,
    String message, {
    bool isError = false,
  }) {
    _current?.remove(); // only one toast at a time
    late final OverlayEntry entry;
    entry = OverlayEntry(
      builder: (_) => _ToastView(
        message: message,
        isError: isError,
        onDismissed: () {
          entry.remove();
          if (identical(_current, entry)) _current = null;
        },
      ),
    );
    _current = entry;
    overlay.insert(entry);
  }
}

class AppToastLoadingHandle {
  AppToastLoadingHandle._(this._entry, this._message);

  final OverlayEntry _entry;
  String _message;
  bool _active = true;

  void update(String message) {
    if (!_active || !identical(AppToast._current, _entry)) return;
    _message = message;
    _entry.markNeedsBuild();
  }

  void dismiss() {
    if (!_active) return;
    _active = false;
    if (identical(AppToast._current, _entry)) {
      _entry.remove();
      AppToast._current = null;
    }
  }
}

class _LoadingToastView extends StatelessWidget {
  const _LoadingToastView({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final mobile = MediaQuery.sizeOf(context).width < 440;
    return Positioned(
      top: MediaQuery.of(context).padding.top + 24,
      right: mobile ? 16 : 24,
      left: mobile ? 16 : null,
      child: IgnorePointer(child: Material(
        color: Colors.transparent,
        child: Align(alignment: Alignment.centerRight,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
              decoration: BoxDecoration(
                color: const Color(0xFFC83D08),
                borderRadius: BorderRadius.circular(8),
                boxShadow: const [BoxShadow(color: Colors.black26,
                  blurRadius: 10, offset: Offset(0, 4))],
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                const SizedBox(width: 20, height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation<Color>(Colors.white))),
                const SizedBox(width: 12),
                Flexible(child: Text(message,
                  style: const TextStyle(color: Colors.white,
                    fontWeight: FontWeight.bold, fontSize: 14))),
              ]),
            ),
          )),
      )),
    );
  }
}

class _ToastView extends StatefulWidget {
  final String message;
  final bool isError;
  final VoidCallback onDismissed;

  const _ToastView({
    required this.message,
    required this.isError,
    required this.onDismissed,
  });

  @override
  State<_ToastView> createState() => _ToastViewState();
}

class _ToastViewState extends State<_ToastView> {
  bool _visible = false;
  Timer? _hideTimer;
  Timer? _removeTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _visible = true);
    });
    _hideTimer = Timer(const Duration(seconds: 5), () {
      if (mounted) setState(() => _visible = false);
    });
    _removeTimer = Timer(
      const Duration(milliseconds: 5300),
      widget.onDismissed,
    );
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _removeTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: MediaQuery.of(context).padding.top + 24,
      right: 24,
      child: IgnorePointer(
        child: Material(
          color: Colors.transparent,
          child: AnimatedOpacity(
            opacity: _visible ? 1 : 0,
            duration: const Duration(milliseconds: 250),
            child: AnimatedSlide(
              offset: _visible ? Offset.zero : const Offset(0.15, 0),
              duration: const Duration(milliseconds: 250),
              curve: Curves.easeOut,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 360),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 14,
                  ),
                  decoration: BoxDecoration(
                    color: widget.isError
                        ? Colors.red.shade600
                        : Colors.green.shade600,
                    borderRadius: BorderRadius.circular(8),
                    boxShadow: const [
                      BoxShadow(
                        color: Colors.black26,
                        blurRadius: 10,
                        offset: Offset(0, 4),
                      ),
                    ],
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        widget.isError
                            ? LucideIcons.alertCircle
                            : LucideIcons.checkCircle2,
                        color: Colors.white,
                        size: 20,
                      ),
                      const SizedBox(width: 12),
                      Flexible(
                        child: Text(
                          widget.message,
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 14,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

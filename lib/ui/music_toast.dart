import 'dart:async';

import 'package:material_ui/material_ui.dart';

final _visibleToasts = Expando<OverlayEntry>();

void showMusicNotice(BuildContext context, String message) {
  if (context.mounted) musicNoticeFor(context)(message);
}

/// 提前保存最外层浮层，弹窗或原页面退出后也能提示操作结果。
ValueChanged<String> musicNoticeFor(BuildContext context) {
  final overlay = Overlay.maybeOf(context, rootOverlay: true);
  return (message) {
    if (overlay == null || !overlay.mounted) return;
    _dismissToast(overlay);

    late final OverlayEntry entry;
    entry = OverlayEntry(
      builder: (context) => _MusicToast(
        message: message,
        onExpired: () {
          if (_visibleToasts[overlay] == entry) _dismissToast(overlay);
        },
      ),
    );
    _visibleToasts[overlay] = entry;
    overlay.insert(entry);
  };
}

void _dismissToast(OverlayState overlay) {
  final entry = _visibleToasts[overlay];
  _visibleToasts[overlay] = null;
  entry
    ?..remove()
    ..dispose();
}

class _MusicToast extends StatefulWidget {
  const _MusicToast({required this.message, required this.onExpired});

  final String message;
  final VoidCallback onExpired;

  @override
  State<_MusicToast> createState() => _MusicToastState();
}

class _MusicToastState extends State<_MusicToast> {
  late final Timer _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer(const Duration(seconds: 3), widget.onExpired);
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return IgnorePointer(
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: 1),
              duration: MediaQuery.disableAnimationsOf(context)
                  ? Duration.zero
                  : const Duration(milliseconds: 160),
              builder: (context, opacity, child) =>
                  Opacity(opacity: opacity, child: child),
              child: Semantics(
                liveRegion: true,
                child: Material(
                  key: const ValueKey('music-toast'),
                  color: colors.inverseSurface,
                  borderRadius: BorderRadius.circular(16),
                  elevation: 6,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 12,
                    ),
                    child: Text(
                      widget.message,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: colors.onInverseSurface,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
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

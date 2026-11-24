import 'package:material_ui/material_ui.dart';

import '../music/song.dart' show resolveCoverUrl;

/// 网络封面。加载失败或没有地址时退回一个图标占位，
/// 避免列表里出现空白的方块。
class Cover extends StatelessWidget {
  const Cover({
    super.key,
    required this.url,
    this.size,
    this.radius = 8,
    this.icon = Icons.music_note_rounded,
  });

  final String url;
  final double? size;
  final double radius;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final image = resolveCoverUrl(url);
    final placeholder = ColoredBox(
      color: theme.colorScheme.surfaceContainerHighest,
      child: Center(
        child: Icon(
          icon,
          size: (size ?? 40) * 0.45,
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: SizedBox(
        width: size,
        height: size,
        child: image.isEmpty
            ? placeholder
            : Image.network(
                image,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => placeholder,
                // 列表滚动时避免图片淡入造成闪烁。
                frameBuilder: (context, child, frame, synchronous) =>
                    frame == null && !synchronous ? placeholder : child,
              ),
      ),
    );
  }
}

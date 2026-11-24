import 'package:material_ui/material_ui.dart';

import '../music/song.dart';
import 'cover.dart';

/// 歌曲列表项。搜索结果、歌单、排行榜都用同一个样子，
/// 只有 [index] 存在时才显示序号（单曲结果没有顺序含义）。
class SongTile extends StatelessWidget {
  const SongTile({
    super.key,
    required this.song,
    this.index,
    this.onTap,
    this.onPlay,
    this.onPause,
    this.onLongPress,
    this.trailing,
    this.selected = false,
    this.loading = false,
  });

  final Song song;
  final int? index;
  final VoidCallback? onTap;
  final VoidCallback? onPlay;
  final VoidCallback? onPause;
  final VoidCallback? onLongPress;
  final Widget? trailing;
  final bool selected;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.labelSmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return ListTile(
      selected: selected,
      selectedTileColor: theme.colorScheme.secondaryContainer,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      leading: _leading(theme),
      title: Text(
        song.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodyLarge,
      ),
      subtitle: Text(
        [
          song.artist,
          if (song.albumName.isNotEmpty) song.albumName,
        ].join(' · '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: muted,
      ),
      onTap: onTap ?? onPlay,
      onLongPress: onLongPress,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (song.isVipOnly && !song.isFree)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: _Badge(text: 'VIP', color: theme.colorScheme.tertiary),
            ),
          if (loading)
            const SizedBox.square(
              dimension: 48,
              child: Center(child: SizedBox.square(
                dimension: 18,
                child: CircularProgressIndicator(strokeWidth: 2, semanticsLabel: '正在加载歌曲'),
              )),
            )
          else if (onPause ?? onPlay case final action?)
            IconButton(
              tooltip: onPause == null ? '播放' : '暂停',
              icon: Icon(onPause == null ? Icons.play_arrow_rounded : Icons.pause_rounded),
              onPressed: action,
            ),
          ?trailing,
        ],
      ),
    );
  }

  Widget _leading(ThemeData theme) => SizedBox(
    width: 48,
    height: 48,
    child: Stack(
      alignment: Alignment.center,
      children: [
        Cover(url: song.coverUrl(150), size: 44, radius: 8),
        if (selected && onPause != null)
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: theme.colorScheme.scrim.withValues(alpha: 0.45),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(
              Icons.graphic_eq_rounded,
              color: theme.colorScheme.primary,
            ),
          ),
      ],
    ),
  );
}

class _Badge extends StatelessWidget {
  const _Badge({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.16),
      borderRadius: BorderRadius.circular(4),
    ),
    child: Text(
      text,
      style: TextStyle(
        fontSize: 10,
        fontWeight: FontWeight.w700,
        color: color,
      ),
    ),
  );
}

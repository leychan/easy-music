import 'package:material_ui/material_ui.dart';

import '../music/song.dart';
import 'cover.dart';

/// 推荐歌单和我的歌单共用行布局，只有可编辑的歌单显示编辑按钮。
class PlaylistListTile extends StatelessWidget {
  const PlaylistListTile({
    super.key,
    required this.playlist,
    required this.onTap,
    this.subtitle,
    this.onEdit,
  });

  final Playlist playlist;
  final VoidCallback onTap;
  final String? subtitle;
  final VoidCallback? onEdit;

  @override
  Widget build(BuildContext context) => ListTile(
    leading: Cover(
      url: playlist.cover,
      size: 52,
      radius: 8,
      icon: Icons.queue_music_rounded,
    ),
    title: Text(playlist.name, maxLines: 1, overflow: TextOverflow.ellipsis),
    subtitle: subtitle == null
        ? null
        : Text(subtitle!, maxLines: 1, overflow: TextOverflow.ellipsis),
    trailing: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (onEdit case final edit?)
          IconButton(
            onPressed: edit,
            tooltip: '编辑歌单',
            icon: const Icon(Icons.edit_outlined),
          ),
        const Icon(Icons.chevron_right_rounded),
      ],
    ),
    onTap: onTap,
  );
}

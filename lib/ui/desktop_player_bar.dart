import 'package:audio_service/audio_service.dart';
import 'package:material_ui/material_ui.dart';

import '../music/music_library.dart';
import '../player/playback.dart';
import '../player/track.dart';
import 'cover.dart';
import 'favorite_button.dart';
import 'player_controls.dart';

enum _PlaybackAction { volume, lyrics }

class DesktopPlayerBar extends StatelessWidget {
  const DesktopPlayerBar({
    super.key,
    required this.player,
    required this.library,
    required this.panel,
    required this.onOpen,
    required this.queueVisible,
    required this.onToggleQueue,
  });
  final Playback player;
  final MusicLibrary library;
  final Color panel;
  final void Function({required bool showLyrics}) onOpen;
  final bool queueVisible;
  final VoidCallback onToggleQueue;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: panel,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 5, 8, 3),
        child: ListenableBuilder(
          listenable: Listenable.merge([player.tracks, player.queuePreparation]),
          builder: (context, _) => StreamBuilder<PlaybackState>(
            stream: player.playbackState,
            initialData: player.playbackState.value,
            builder: (context, snapshot) {
              final state = snapshot.data!;
              final tracks = player.tracks.value;
              final index = state.queueIndex;
              final current = index == null
                  ? null
                  : tracks.elementAtOrNull(index);
              final preview = player.queuePreparation.value?.preview;
              final track = preview == null ? current : null;
              return LayoutBuilder(
                builder: (context, constraints) {
                  final wide = constraints.maxWidth >= 680;
                  final compactActions = constraints.maxWidth < 600;
                  final gap = wide ? 16.0 : 6.0;
                  final identity = _identity(context, track, preview);
                  final controls = Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (wide)
                        IconButton(
                          tooltip:
                              state.shuffleMode == AudioServiceShuffleMode.none
                              ? '开启随机播放'
                              : '关闭随机播放',
                          isSelected:
                              state.shuffleMode != AudioServiceShuffleMode.none,
                          color:
                              state.shuffleMode == AudioServiceShuffleMode.none
                              ? colors.onSurfaceVariant
                              : colors.primary,
                          onPressed: () => runPlayerAction(
                            context,
                            () => player.setShuffleMode(
                              state.shuffleMode == AudioServiceShuffleMode.none
                                  ? AudioServiceShuffleMode.all
                                  : AudioServiceShuffleMode.none,
                            ),
                          ),
                          icon: const Icon(Icons.shuffle_rounded, size: 19),
                        ),
                      PlayerControls(player: player, compact: true),
                    ],
                  );
                  final actions = Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      FavoriteButton.track(library: library, track: track),
                      if (compactActions)
                        PopupMenuButton<_PlaybackAction>(
                          tooltip: '更多播放选项',
                          icon: const Icon(Icons.more_horiz_rounded, size: 20),
                          onSelected: (action) => switch (action) {
                            _PlaybackAction.volume => _openVolume(context),
                            _PlaybackAction.lyrics => onOpen(showLyrics: true),
                          },
                          itemBuilder: (_) => [
                            const PopupMenuItem(
                              value: _PlaybackAction.volume,
                              child: Text('音量'),
                            ),
                            PopupMenuItem(
                              value: _PlaybackAction.lyrics,
                              enabled: track != null,
                              child: const Text('歌词'),
                            ),
                          ],
                        )
                      else ...[
                        IconButton(
                          tooltip: '音量',
                          icon: const Icon(Icons.volume_up_outlined, size: 20),
                          onPressed: () => _openVolume(context),
                        ),
                        IconButton(
                          tooltip: '歌词',
                          icon: const Icon(Icons.lyrics_outlined, size: 20),
                          onPressed: track == null ? null : () => onOpen(showLyrics: true),
                        ),
                      ],
                      IconButton(
                        tooltip: queueVisible ? '关闭播放队列' : '打开播放队列',
                        isSelected: queueVisible,
                        color: queueVisible
                            ? colors.primary
                            : colors.onSurfaceVariant,
                        icon: Badge(
                          isLabelVisible: tracks.isNotEmpty,
                          label: Text(
                            tracks.length > 99 ? '99+' : '${tracks.length}',
                          ),
                          child: const Icon(
                            Icons.queue_music_rounded,
                            size: 20,
                          ),
                        ),
                        onPressed: onToggleQueue,
                      ),
                    ],
                  );
                  final seek = StreamBuilder<MediaItem?>(
                    stream: player.mediaItem,
                    initialData: player.mediaItem.value,
                    builder: (context, snapshot) => SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        trackHeight: 3,
                        padding: wide ? null : const EdgeInsets.symmetric(horizontal: 4),
                      ),
                      child: PlaybackSeekBar(
                        key: ValueKey(current?.id),
                        player: player,
                        duration: snapshot.data?.duration,
                      ),
                    ),
                  );
                  final bar = Row(
                    children: [
                      Expanded(flex: 2, child: identity),
                      SizedBox(width: gap),
                      controls,
                      SizedBox(width: gap),
                      Expanded(flex: 3, child: seek),
                      SizedBox(width: gap),
                      actions,
                    ],
                  );
                  return Column(
                    children: [
                      if (wide)
                        bar
                      else
                        // 收紧窄窗口的按钮间距，给歌名和可拖动进度条留出空间。
                        IconButtonTheme(
                          data: IconButtonThemeData(style: IconButton.styleFrom(
                            fixedSize: const Size(38, 44),
                            minimumSize: const Size(38, 44),
                            padding: EdgeInsets.zero,
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          )),
                          child: bar,
                        ),
                      ValueListenableBuilder(
                        valueListenable: player.message,
                        builder: (context, message, _) => message == null
                            ? const SizedBox.shrink()
                            : Padding(
                                padding: const EdgeInsets.only(bottom: 6),
                                child: Text(
                                  message,
                                  style: TextStyle(color: colors.error),
                                ),
                              ),
                      ),
                    ],
                  );
                },
              );
            },
          ),
        ),
      ),
    );
  }

  void _openVolume(BuildContext context) => showDialog<void>(
    context: context,
    builder: (_) => AlertDialog(
      title: const Text('播放器音量'),
      content: PlaybackVolumeControl(player: player),
    ),
  );

  Widget _identity(BuildContext context, Track? track, MediaItem? preview) {
    final theme = Theme.of(context);
    final artist = preview?.artist ?? track?.artist;
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: track == null ? null : () => onOpen(showLyrics: false),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            Cover(
              url: (preview?.artUri ?? track?.artUri)?.toString() ?? '',
              size: 47,
              radius: 9,
              icon: Icons.album_outlined,
            ),
            const SizedBox(width: 9),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    preview?.title ?? track?.title ?? '尚未选择音乐',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  if (artist != null && artist.isNotEmpty)
                    Text(
                      artist,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

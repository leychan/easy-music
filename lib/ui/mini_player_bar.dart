import 'package:audio_service/audio_service.dart';
import 'package:material_ui/material_ui.dart';

import '../music/music_library.dart';
import '../player/playback.dart';
import '../player/track.dart';
import 'cover.dart';
import 'favorite_button.dart';
import 'glass_surface.dart';
import 'player_controls.dart';

const double _barHeight = 56;
const double _coverSize = 44;
const _radius = BorderRadius.all(Radius.circular(_barHeight / 2));

/// 跨标签常驻的播放条，封面和播放控制各有一块玻璃底座。
class MiniPlayerBar extends StatelessWidget {
  const MiniPlayerBar({
    super.key,
    required this.player,
    required this.library,
    required this.onOpen,
    this.onToggleQueue,
    this.queueVisible = false,
  });

  final Playback player;
  final MusicLibrary library;
  final void Function({required bool showLyrics}) onOpen;
  final VoidCallback? onToggleQueue;
  final bool queueVisible;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([player.tracks, player.queuePreparation]),
    builder: (context, _) => StreamBuilder<PlaybackState>(
      stream: player.playbackState,
      initialData: player.playbackState.value,
      builder: (context, snapshot) {
        final state = snapshot.requireData;
        final index = state.queueIndex;
        final preview = player.queuePreparation.value?.preview;
        final track = preview == null && index != null
            ? player.tracks.value.elementAtOrNull(index)
            : null;
        return Center(
          heightFactor: 1,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: glassBarMaxWidth),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 6),
              child: LayoutBuilder(
                builder: (context, bounds) => Row(
                  children: [
                    Expanded(child: _identity(track, state, preview)),
                    const SizedBox(width: 8),
                    // 极窄时先给圆形封面留位置，再收紧控制区。
                    ConstrainedBox(
                      constraints: BoxConstraints(
                        maxWidth: (bounds.maxWidth - 64).clamp(
                          0.0,
                          double.infinity,
                        ),
                      ),
                      child: _controls(track),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    ),
  );

  Widget _identity(Track? track, PlaybackState state, MediaItem? preview) {
    final title = preview?.title ?? track?.title ?? '尚未选择音乐';
    final artist = preview != null
        ? preview.artist
        : track == null
        ? '从发现或搜索里挑一首'
        : track.artist.isNotEmpty
        ? track.artist
        : track.isLocal
        ? '本地文件'
        : '在线音乐';
    final cover = _SpinningCover(
      key: ValueKey(preview?.id ?? track?.id),
      url: (preview?.artUri ?? track?.artUri)?.toString() ?? '',
      spinning:
          track != null &&
          state.playing &&
          state.processingState == AudioProcessingState.ready,
    );
    return GlassSurface(
      radius: _radius,
      child: Material(
        type: MaterialType.transparency,
        child: Tooltip(
          message: title,
          child: InkWell(
            borderRadius: _radius,
            onTap: track == null ? null : () => onOpen(showLyrics: false),
            child: SizedBox(
              height: _barHeight,
              child: LayoutBuilder(
                builder: (context, bounds) {
                  if (bounds.maxWidth < 100) return Center(child: cover);
                  final theme = Theme.of(context);
                  return Padding(
                    padding: const EdgeInsetsDirectional.fromSTEB(6, 0, 10, 0),
                    child: Row(
                      children: [
                        cover,
                        const SizedBox(width: 8),
                        Expanded(
                          child: MediaQuery.withClampedTextScaling(
                            maxScaleFactor: 1.3,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.bodyMedium?.copyWith(
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                if (artist != null)
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
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _controls(Track? track) => GlassSurface(
    radius: _radius,
    child: Material(
      type: MaterialType.transparency,
      child: SizedBox(
        height: _barHeight,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: IconButtonTheme(
              data: IconButtonThemeData(
                style: IconButton.styleFrom(
                  minimumSize: const Size.square(42),
                  padding: const EdgeInsets.all(8),
                  visualDensity: VisualDensity.standard,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  FavoriteButton.track(library: library, track: track),
                  IconButton(
                    tooltip: '歌词',
                    icon: const Icon(Icons.lyrics_outlined, size: 21),
                    onPressed: track == null
                        ? null
                        : () => onOpen(showLyrics: true),
                  ),
                  PlayerControls(player: player, compact: true),
                  if (onToggleQueue != null)
                    IconButton(
                      tooltip: queueVisible ? '收起队列' : '打开播放队列',
                      isSelected: queueVisible,
                      icon: const Icon(Icons.queue_music_rounded),
                      onPressed: onToggleQueue,
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

class _SpinningCover extends StatefulWidget {
  const _SpinningCover({super.key, required this.url, required this.spinning});

  final String url;
  final bool spinning;

  @override
  State<_SpinningCover> createState() => _SpinningCoverState();
}

class _SpinningCoverState extends State<_SpinningCover>
    with SingleTickerProviderStateMixin {
  late final _turns = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 18),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _updateRotation();
  }

  @override
  void didUpdateWidget(covariant _SpinningCover oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.spinning != widget.spinning) _updateRotation();
  }

  void _updateRotation() {
    final spinning =
        widget.spinning && !MediaQuery.disableAnimationsOf(context);
    // 暂停时保留角度，继续播放后从原处接着转。
    if (spinning && !_turns.isAnimating) _turns.repeat();
    if (!spinning && _turns.isAnimating) _turns.stop();
  }

  @override
  void dispose() {
    _turns.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    child: RotationTransition(
      turns: _turns,
      child: Cover(
        url: widget.url,
        size: _coverSize,
        radius: _coverSize / 2,
        icon: Icons.album_outlined,
      ),
    ),
  );
}

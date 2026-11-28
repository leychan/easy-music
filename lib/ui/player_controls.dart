import 'package:audio_service/audio_service.dart';
import 'package:material_ui/material_ui.dart';

import '../player/playback.dart';
import 'app_dialog.dart';
import 'diffuse_menu.dart';
import 'music_toast.dart';
import 'playback_options.dart' show playbackFadeOptions;

Future<void> runPlayerAction(
  BuildContext context,
  Future<void> Function() action,
) async {
  try {
    await action();
  } catch (_) {
    if (context.mounted) showMusicNotice(context, '无法完成播放操作，请重试。');
  }
}

class PlayerControls extends StatelessWidget {
  const PlayerControls({
    super.key,
    required this.player,
    this.compact = false,
    this.stage = false,
    this.showStageVolume = true,
  });

  final Playback player;

  /// 迷你模式下只保留播放/暂停与切歌按钮，不画进度条，
  /// 否则底部播放条会占掉太多纵向空间。
  final bool compact;
  final bool stage;
  final bool showStageVolume;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final android = Theme.of(context).platform == TargetPlatform.android;
    return ColoredBox(
      color: compact || stage ? Colors.transparent : colors.surfaceContainer,
      child: Padding(
        padding: compact || stage
            ? EdgeInsets.zero
            : const EdgeInsets.fromLTRB(16, 6, 16, 10),
        child: StreamBuilder<PlaybackState>(
          stream: player.playbackState,
          initialData: player.playbackState.value,
          builder: (context, stateSnapshot) {
            final state = stateSnapshot.data!;
            final index = state.queueIndex;
            final playing = state.playing;
            final buffering =
                playing &&
                (state.processingState == AudioProcessingState.idle ||
                    state.processingState == AudioProcessingState.buffering ||
                    state.processingState == AudioProcessingState.loading);

            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (!compact)
                  ValueListenableBuilder(
                    valueListenable: player.message,
                    builder: (context, message, _) => message == null
                        ? const SizedBox.shrink()
                        : Padding(
                            padding: const EdgeInsets.only(bottom: 5),
                            child: Text(
                              message,
                              style: TextStyle(color: colors.error),
                            ),
                          ),
                  ),
                if (!compact)
                  StreamBuilder<MediaItem?>(
                    stream: player.mediaItem,
                    initialData: player.mediaItem.value,
                    builder: (context, snapshot) => PlaybackSeekBar(
                      key: ValueKey(snapshot.data?.id),
                      player: player,
                      duration: snapshot.data?.duration,
                      stage: stage,
                    ),
                  ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: '上一首',
                      iconSize: stage ? 36 : 24,
                      icon: Icon(
                        stage
                            ? Icons.fast_rewind_rounded
                            : Icons.skip_previous_rounded,
                      ),
                      onPressed: !player.hasPrevious
                          ? null
                          : () =>
                                runPlayerAction(context, player.skipToPrevious),
                    ),
                    if (!compact) const SizedBox(width: 12),
                    ValueListenableBuilder(
                      valueListenable: player.queuePreparation,
                      builder: (context, preparation, _) {
                        final preparing = preparation != null;
                        final iconSize = stage ? 50.0 : (compact ? 22.0 : 28.0);
                        return (stage ? IconButton.new : IconButton.filled)(
                          iconSize: iconSize,
                          tooltip: preparing
                              ? '正在准备播放'
                              : (playing ? '暂停' : '播放'),
                          icon: preparing || buffering
                              ? SizedBox.square(
                                  // 转圈时也留足暂停图标的空间，缓冲结束时整排按钮不会跳动。
                                  dimension: iconSize,
                                  child: Center(
                                    child: SizedBox.square(
                                      dimension: 22,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: preparing
                                            ? colors.primary
                                            : (stage
                                                  ? colors.onSurface
                                                  : colors.onPrimary),
                                      ),
                                    ),
                                  ),
                                )
                              : Icon(
                                  playing
                                      ? Icons.pause_rounded
                                      : Icons.play_arrow_rounded,
                                ),
                          onPressed: preparing || index == null
                              ? null
                              : () => runPlayerAction(
                                  context,
                                  playing ? player.pause : player.play,
                                ),
                        );
                      },
                    ),
                    if (!compact) const SizedBox(width: 12),
                    IconButton(
                      tooltip: '下一首',
                      iconSize: stage ? 36 : 24,
                      icon: Icon(
                        stage
                            ? Icons.fast_forward_rounded
                            : Icons.skip_next_rounded,
                      ),
                      onPressed: !player.hasNext
                          ? null
                          : () => runPlayerAction(context, player.skipToNext),
                    ),
                  ],
                ),
                if (stage && showStageVolume)
                  PlaybackVolumeControl(player: player, stage: true),
                if (!compact && !stage)
                  _PlaybackOptions(
                    player: player,
                    android: android,
                    children: [
                      PlaybackModeButton(
                        player: player,
                        mode: state.repeatMode,
                      ),
                      IconButton(
                        tooltip:
                            state.shuffleMode == AudioServiceShuffleMode.none
                            ? '开启随机播放'
                            : '关闭随机播放',
                        isSelected:
                            state.shuffleMode != AudioServiceShuffleMode.none,
                        icon: const Icon(Icons.shuffle_rounded),
                        onPressed: () => runPlayerAction(
                          context,
                          () => player.setShuffleMode(
                            state.shuffleMode == AudioServiceShuffleMode.none
                                ? AudioServiceShuffleMode.all
                                : AudioServiceShuffleMode.none,
                          ),
                        ),
                      ),
                      PlaybackSpeedButton(
                        player: player,
                        speed: state.speed,
                      ),
                      ValueListenableBuilder(
                        valueListenable: player.fadeMilliseconds,
                        builder: (context, current, _) => DiffuseMenuButton<int>(
                          tooltip: '播放淡入淡出',
                          icon: const Icon(Icons.graphic_eq_rounded),
                          onSelected: (value) => runPlayerAction(
                            context,
                            () => player.setFadeMilliseconds(value),
                          ),
                          itemBuilder: (_) => [
                            for (final (value, label) in playbackFadeOptions)
                              DiffuseMenuItem(
                                value: value,
                                checked: current == value,
                                child: Text(label),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// 图标和提示文字反映当前模式，点击直接切换。
class PlaybackModeButton extends StatelessWidget {
  const PlaybackModeButton({super.key, required this.player, required this.mode});

  final Playback player;
  final AudioServiceRepeatMode mode;

  @override
  Widget build(BuildContext context) {
    final (icon, label) = switch (mode) {
      AudioServiceRepeatMode.none => (Icons.playlist_play_rounded, '顺序播放'),
      AudioServiceRepeatMode.all || AudioServiceRepeatMode.group =>
        (Icons.repeat_rounded, '列表循环'),
      AudioServiceRepeatMode.one => (Icons.repeat_one_rounded, '单曲循环'),
    };
    return IconButton(
      tooltip: label,
      icon: Icon(icon),
      onPressed: () => runPlayerAction(context, player.cycleRepeatMode),
    );
  }
}

class PlaybackSpeedButton extends StatelessWidget {
  const PlaybackSpeedButton({super.key, required this.player, required this.speed});

  final Playback player;
  final double speed;

  @override
  Widget build(BuildContext context) => DiffuseMenuButton<double>(
    tooltip: '播放速度',
    onSelected: (value) => runPlayerAction(context, () => player.setSpeed(value)),
    itemBuilder: (context) => [
      for (final value in const [0.5, 0.75, 1.0, 1.25, 1.5, 2.0])
        DiffuseMenuItem(
          value: value,
          checked: speed == value,
          child: Text('$value×'),
        ),
    ],
    child: Padding(
      padding: EdgeInsets.symmetric(
        horizontal: Theme.of(context).platform == TargetPlatform.android ? 6 : 12,
        vertical: 12,
      ),
      child: FittedBox(fit: BoxFit.scaleDown, child: Text('$speed×')),
    ),
  );
}

class _PlaybackOptions extends StatelessWidget {
  const _PlaybackOptions({
    required this.player,
    required this.android,
    required this.children,
  });

  final Playback player;
  final bool android;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final volume = PlaybackVolumeControl(player: player);
    if (!android) {
      return Wrap(
        spacing: 12,
        alignment: WrapAlignment.center,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [...children, volume],
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        const controlWidth = 44.0;
        final inlineVolume =
            constraints.maxWidth >= children.length * controlWidth + 112;
        final width = (constraints.maxWidth / (children.length + 1))
            .clamp(0.0, controlWidth)
            .toDouble();
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final control in children)
              SizedBox(width: width, child: control),
            if (inlineVolume)
              Flexible(child: volume)
            else
              // 窄窗口把滑块收进音量按钮，播放选项仍在同一行。
              SizedBox(
                width: width,
                child: IconButton(
                  tooltip: '音量',
                  icon: const Icon(Icons.volume_up_outlined),
                  onPressed: () => showDialog<void>(
                    context: context,
                    builder: (_) => AppDialog(
                      title: const Text('播放器音量'),
                      content: volume,
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class PlaybackVolumeControl extends StatefulWidget {
  const PlaybackVolumeControl({
    super.key,
    required this.player,
    this.stage = false,
  });

  final Playback player;
  final bool stage;

  @override
  State<PlaybackVolumeControl> createState() => _PlaybackVolumeControlState();
}

class _PlaybackVolumeControlState extends State<PlaybackVolumeControl> {
  double? _preview;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: widget.stage ? null : 170,
    child: StreamBuilder<double>(
      stream: widget.player.volumeStream,
      initialData: widget.player.volume,
      builder: (context, snapshot) {
        final volume = _preview ?? snapshot.data ?? 1.0;
        final slider = Slider(
          value: volume,
          label: _label(volume),
          semanticFormatterCallback: (value) => '播放器音量 ${_label(value)}',
          onChanged: (value) => setState(() => _preview = value),
          onChangeEnd: (value) async {
            // 松开后写入引擎与存储，拖动时只更新读数。
            await runPlayerAction(
              context,
              () => widget.player.setVolume(value),
            );
            if (mounted && _preview == value) setState(() => _preview = null);
          },
        );
        if (widget.stage) {
          final color = Theme.of(context).colorScheme.onSurfaceVariant;
          return Row(
            children: [
              Icon(
                Icons.volume_mute_rounded,
                size: 18,
                color: color,
              ),
              Expanded(child: _StageSlider(child: slider)),
              Icon(
                Icons.volume_up_rounded,
                size: 18,
                color: color,
              ),
            ],
          );
        }
        return Row(
          children: [
            Icon(
              volume == 0 ? Icons.volume_off_rounded : Icons.volume_up_rounded,
            ),
            Expanded(child: slider),
            SizedBox(
              width: 40,
              child: Text(_label(volume), textAlign: TextAlign.end),
            ),
          ],
        );
      },
    ),
  );

  static String _label(double volume) => '${(volume * 100).round()}%';
}

class PlaybackSeekBar extends StatefulWidget {
  const PlaybackSeekBar({
    super.key,
    required this.player,
    required this.duration,
    this.stage = false,
  });

  final Playback player;
  final Duration? duration;
  final bool stage;

  @override
  State<PlaybackSeekBar> createState() => _PlaybackSeekBarState();
}

class _PlaybackSeekBarState extends State<PlaybackSeekBar> {
  double? _dragPosition;

  @override
  Widget build(BuildContext context) {
    final duration = widget.duration;
    final maximum = duration?.inMilliseconds.toDouble() ?? 0;
    final labelStyle = Theme.of(context).textTheme.labelSmall;
    return StreamBuilder<Duration>(
      stream: widget.player.positionStream,
      initialData: widget.player.position,
      builder: (context, snapshot) {
        final position = snapshot.data ?? Duration.zero;
        final value = _dragPosition ?? position.inMilliseconds.toDouble();
        final elapsed = formatPlaybackTime(Duration(milliseconds: value.round()));
        final slider = Slider(
          value: value.clamp(0, maximum),
          max: maximum == 0 ? 1 : maximum,
          label: widget.stage ? elapsed : null,
          semanticFormatterCallback: widget.stage
              ? (value) =>
                    '播放进度 ${formatPlaybackTime(Duration(milliseconds: value.round()))}'
              : null,
          onChanged: maximum == 0
              ? null
              : (value) => setState(() => _dragPosition = value),
          onChangeEnd: (value) async {
            await runPlayerAction(
              context,
              () => widget.player.seek(Duration(milliseconds: value.round())),
            );
            if (mounted) setState(() => _dragPosition = null);
          },
        );
        if (widget.stage) {
          final timeStyle = labelStyle?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          );
          final remaining = Duration(
            milliseconds: (maximum - value).clamp(0, maximum).round(),
          );
          return Column(
            children: [
              _StageSlider(child: slider),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(elapsed, style: timeStyle),
                  Text(
                    maximum == 0 ? '--:--' : '−${formatPlaybackTime(remaining)}',
                    style: timeStyle,
                  ),
                ],
              ),
            ],
          );
        }
        return Row(
          children: [
            Text(elapsed, style: labelStyle),
            Expanded(child: slider),
            Text(
              duration == null ? '--:--' : formatPlaybackTime(duration),
              style: labelStyle,
            ),
          ],
        );
      },
    );
  }
}

String formatPlaybackTime(Duration time) {
  String pad(int value) => value.toString().padLeft(2, '0');
  final seconds = pad(time.inSeconds.remainder(60));
  if (time.inHours == 0) return '${pad(time.inMinutes)}:$seconds';
  return '${time.inHours}:${pad(time.inMinutes.remainder(60))}:$seconds';
}

class _StageSlider extends StatelessWidget {
  const _StageSlider({required this.child});

  final Slider child;

  @override
  Widget build(BuildContext context) {
    final foreground = Theme.of(context).colorScheme.onSurface;
    final subtle = foreground.withValues(alpha: 0.24);
    return SliderTheme(
      data: SliderTheme.of(context).copyWith(
        trackHeight: 5,
        trackShape: const RoundedRectSliderTrackShape(),
        activeTrackColor: foreground,
        inactiveTrackColor: subtle,
        disabledActiveTrackColor: foreground.withValues(alpha: 0.38),
        disabledInactiveTrackColor: subtle,
        thumbColor: foreground,
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 4),
        overlayColor: subtle,
        overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
      ),
      child: child,
    );
  }
}

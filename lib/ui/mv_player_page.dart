import 'dart:async';

import 'package:flutter/services.dart' show DeviceOrientation, LogicalKeyboardKey, SystemChrome, SystemUiOverlayStyle;
import 'package:material_ui/material_ui.dart';

import '../account/kugou/kugou_auth.dart';
import '../music/catalog.dart';
import '../music/music_library.dart';
import '../player/mv_playback.dart';
import '../player/playback.dart';
import 'player_controls.dart' show formatPlaybackTime;

class MvPlayerPage extends StatefulWidget {
  const MvPlayerPage({
    super.key,
    required this.hit,
    required this.library,
    required this.player,
  });

  final CatalogHit hit;
  final MusicLibrary library;
  final Playback player;

  @override
  State<MvPlayerPage> createState() => _MvPlayerPageState();
}

class _MvPlayerPageState extends State<MvPlayerPage> {
  static const _playbackError = '无法播放 MV，请稍后重试。';
  static const _overlayStyle = SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
    statusBarBrightness: Brightness.dark,
    systemNavigationBarColor: Colors.transparent,
    systemNavigationBarIconBrightness: Brightness.light,
    systemNavigationBarContrastEnforced: false,
  );

  MvPlayback? _videoPlayer;
  bool _canTogglePlayback = false;
  Orientation? _orientationOverride;
  String? _error;
  int _attempt = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final attempt = ++_attempt;
    if (_error != null) setState(() => _error = null);
    try {
      final uri = await widget.library.videoAddress(widget.hit.id);
      if (!mounted || attempt != _attempt) return;

      final videoPlayer = MvPlayback(uri, onError: () => _fail(attempt, _playbackError));
      setState(() => _videoPlayer = videoPlayer);
      await videoPlayer.initialize();
      if (!mounted || attempt != _attempt) return;

      // 视频单独播放，暂停当前歌曲并保留原来的队列和进度。
      if (widget.player.playbackState.value.playing) await widget.player.pause();
      if (!mounted || attempt != _attempt) return;
      await videoPlayer.play();
      if (mounted && attempt == _attempt) _canTogglePlayback = true;
    } on KugouFailure catch (error) {
      _fail(attempt, error.message);
    } catch (_) {
      _fail(attempt, _playbackError);
    }
  }

  void _fail(int attempt, String message) {
    if (!mounted || attempt != _attempt) return;
    // 忽略已关闭播放器迟到的错误，重试时重新取得地址并创建播放器。
    ++_attempt;
    _releaseVideo();
    setState(() => _error = message);
  }

  void _releaseVideo() {
    final videoPlayer = _videoPlayer;
    _videoPlayer = null;
    _canTogglePlayback = false;
    if (videoPlayer != null) {
      unawaited(videoPlayer.dispose().catchError((Object error) {
        debugPrint('Could not dispose MV player: ${error.runtimeType}');
      }));
    }
  }

  Future<void> _togglePlayback() async {
    final player = _videoPlayer;
    if (player == null || !_canTogglePlayback) return;
    final attempt = _attempt;
    try {
      await player.togglePlayback();
    } catch (_) {
      _fail(attempt, _playbackError);
    }
  }

  Future<void> _setOrientation(Orientation orientation) async {
    final previous = _orientationOverride;
    setState(() => _orientationOverride = orientation);
    try {
      await SystemChrome.setPreferredOrientations(orientation == Orientation.landscape
          ? const [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]
          : const [DeviceOrientation.portraitUp]);
    } catch (error) {
      if (mounted && _orientationOverride == orientation) {
        setState(() => _orientationOverride = previous);
      }
      debugPrint('Could not rotate MV page: ${error.runtimeType}');
    }
  }

  @override
  void dispose() {
    ++_attempt;
    _releaseVideo();
    if (_orientationOverride != null) {
      // 退出后把转屏交还给系统，MV 的屏幕方向不影响其他页面。
      unawaited(SystemChrome.setPreferredOrientations(const []).catchError((Object error) {
        debugPrint('Could not restore screen orientation: ${error.runtimeType}');
      }));
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final canRotate = theme.platform == TargetPlatform.android;
    final landscape = canRotate && MediaQuery.orientationOf(context) == Orientation.landscape;
    final rotateOnBack = landscape && _orientationOverride == Orientation.landscape;
    final colors = ColorScheme.fromSeed(
      seedColor: theme.colorScheme.primary,
      brightness: Brightness.dark,
      surface: Colors.black,
    );
    // 只为 MV 路由设置沉浸主题，桌面工作区外的侧栏和播放栏沿用应用配色。
    final page = Theme(
      data: theme.copyWith(
        colorScheme: colors,
        textTheme: theme.textTheme.apply(bodyColor: colors.onSurface, displayColor: colors.onSurface),
      ),
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        value: _overlayStyle,
        child: Material(
          color: Colors.black,
          child: CallbackShortcuts(
            bindings: {
              const SingleActivator(LogicalKeyboardKey.escape): () => Navigator.of(context).maybePop(),
              const SingleActivator(LogicalKeyboardKey.space): _togglePlayback,
            },
            child: Focus(
              autofocus: true,
              child: SafeArea(
                child: LayoutBuilder(builder: (context, constraints) {
                  final textTheme = Theme.of(context).textTheme;
                  final portrait = constraints.maxHeight > constraints.maxWidth;
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (!landscape) Padding(
                        padding: const EdgeInsets.fromLTRB(24, 24, 24, 8),
                        child: Column(
                          children: [
                            Text(
                              widget.hit.title,
                              textAlign: TextAlign.center,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w600),
                            ),
                            if (widget.hit.subtitle.isNotEmpty) ...[
                              const SizedBox(height: 5),
                              Text(
                                widget.hit.subtitle,
                                textAlign: TextAlign.center,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: textTheme.bodyMedium?.copyWith(color: colors.onSurfaceVariant),
                              ),
                            ],
                          ],
                        ),
                      ),
                      Expanded(
                        child: Align(
                          alignment: portrait ? const Alignment(0, -0.55) : Alignment.center,
                          child: _buildVideo(canRotate: canRotate, landscape: landscape),
                        ),
                      ),
                      _MvProgress(key: ObjectKey(_videoPlayer), player: _videoPlayer),
                    ],
                  );
                }),
              ),
            ),
          ),
        ),
      ),
    );
    return PopScope<void>(
      canPop: !rotateOnBack,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && rotateOnBack) unawaited(_setOrientation(Orientation.portrait));
      },
      child: page,
    );
  }

  Widget _buildVideo({required bool canRotate, required bool landscape}) {
    final Widget content;
    final videoPlayer = _videoPlayer;
    if (_error case final error?) {
      content = Center(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(error, textAlign: TextAlign.center),
              TextButton(onPressed: _load, child: const Text('重试')),
            ],
          ),
        ),
      );
    } else if (videoPlayer == null) {
      content = const Center(child: CircularProgressIndicator(semanticsLabel: '正在加载 MV'));
    } else {
      content = Semantics(
        button: true,
        label: '播放或暂停 MV',
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _togglePlayback,
          child: videoPlayer.buildVideo(),
        ),
      );
    }
    return AspectRatio(
      aspectRatio: 16 / 9,
      child: Stack(
        fit: StackFit.expand,
        children: [
          content,
          if (canRotate)
            Positioned(
              right: 8,
              top: 8,
              child: IconButton.filled(
                tooltip: landscape ? '切回竖屏' : '横屏播放',
                style: IconButton.styleFrom(backgroundColor: Colors.black54, foregroundColor: Colors.white),
                icon: Icon(landscape ? Icons.fullscreen_exit_rounded : Icons.fullscreen_rounded),
                onPressed: () => _setOrientation(landscape ? Orientation.portrait : Orientation.landscape),
              ),
            ),
        ],
      ),
    );
  }
}

class _MvProgress extends StatefulWidget {
  const _MvProgress({super.key, required this.player});

  final MvPlayback? player;

  @override
  State<_MvProgress> createState() => _MvProgressState();
}

class _MvProgressState extends State<_MvProgress> {
  double? _dragPosition;
  int _seekAttempt = 0;

  Future<void> _seek(double value) async {
    final player = widget.player;
    if (player == null) return;
    final attempt = ++_seekAttempt;
    try {
      await player.seek(Duration(milliseconds: value.round()));
    } catch (error) {
      debugPrint('Could not seek MV: ${error.runtimeType}');
    } finally {
      if (mounted && attempt == _seekAttempt) setState(() => _dragPosition = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final foreground = theme.colorScheme.onSurface;
    final labelStyle = theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    return ValueListenableBuilder<MvTimeline>(
      valueListenable: widget.player?.timeline ?? const AlwaysStoppedAnimation(MvPlayback.emptyTimeline),
      builder: (context, timeline, _) {
        final duration = timeline.duration;
        final maximum = duration.inMilliseconds.toDouble();
        final value = (_dragPosition ?? timeline.position.inMilliseconds.toDouble()).clamp(0.0, maximum).toDouble();
        return Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 26),
          child: Row(
            children: [
              Text(formatPlaybackTime(Duration(milliseconds: value.round())), style: labelStyle),
              Expanded(
                child: SliderTheme(
                  data: theme.sliderTheme.copyWith(
                    trackHeight: 2,
                    trackShape: const RoundedRectSliderTrackShape(),
                    thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 4),
                    overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
                    activeTrackColor: foreground,
                    inactiveTrackColor: foreground.withValues(alpha: 0.30),
                    thumbColor: foreground,
                  ),
                  child: Slider(
                    max: maximum > 0 ? maximum : 1,
                    value: value,
                    semanticFormatterCallback: (value) =>
                        'MV 进度 ${formatPlaybackTime(Duration(milliseconds: value.round()))}',
                    onChanged: maximum > 0 ? (value) => setState(() {
                      // 新拖动应优先于上一条尚未完成的定位命令。
                      ++_seekAttempt;
                      _dragPosition = value;
                    }) : null,
                    onChangeEnd: _seek,
                  ),
                ),
              ),
              Text(formatPlaybackTime(duration), style: labelStyle),
            ],
          ),
        );
      },
    );
  }
}

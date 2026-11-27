import 'dart:convert';
import 'dart:ui' show ImageFilter;

import 'package:audio_service/audio_service.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../music/music_library.dart';
import '../music/song.dart';
import '../player/lyrics.dart';
import '../player/playback.dart';
import '../player/track.dart';
import 'appearance.dart';
import 'artist_page.dart';
import 'favorite_button.dart';
import 'lyrics_display.dart';
import 'music_toast.dart';
import 'playback_options.dart';
import 'player_controls.dart';
import 'workspace_page.dart';

/// 从播放栏或歌曲列表打开同一个播放页面。
Future<void> showNowPlaying(
  BuildContext context, {
  required Playback player,
  required MusicLibrary library,
  bool showLyrics = false,
}) async {
  await Navigator.of(context).push<void>(
    NowPlayingPage.route(
      player: player,
      library: library,
      showLyrics: showLyrics,
    ),
  );
}

/// 桌面嵌入工作区，Android 独立占据整个页面。
class NowPlayingPage extends StatelessWidget {
  const NowPlayingPage({
    super.key,
    required this.player,
    required this.library,
    this.showLyrics = false,
  });

  final Playback player;
  final MusicLibrary library;
  final bool showLyrics;

  static const routeName = '/now-playing';

  static Route<void> route({
    required Playback player,
    required MusicLibrary library,
    bool showLyrics = false,
  }) => MaterialPageRoute<void>(
    settings: const RouteSettings(name: routeName),
    builder: (_) => NowPlayingPage(
      player: player,
      library: library,
      showLyrics: showLyrics,
    ),
  );

  @override
  Widget build(BuildContext context) {
    final inWorkspace = DesktopPageScope.active(context);
    final theme = Theme.of(context);
    final mobile =
        !inWorkspace && theme.platform != TargetPlatform.linux;
    final stage = _NowPlayingStage(
      player: player,
      library: library,
      mobile: mobile,
      showLyrics: showLyrics,
    );
    if (inWorkspace) return stage;
    final page = Scaffold(body: stage);
    if (!mobile) return page;
    final iconBrightness = theme.brightness == Brightness.dark
        ? Brightness.light
        : Brightness.dark;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: iconBrightness,
        systemNavigationBarColor: Colors.transparent,
        systemNavigationBarIconBrightness: iconBrightness,
        systemNavigationBarContrastEnforced: false,
      ),
      child: page,
    );
  }
}

/// 桌面和移动端共用的「正在播放」内容。
class _NowPlayingStage extends StatefulWidget {
  const _NowPlayingStage({
    required this.player,
    required this.library,
    required this.mobile,
    required this.showLyrics,
  });

  final Playback player;
  final MusicLibrary library;
  final bool mobile;
  final bool showLyrics;

  @override
  State<_NowPlayingStage> createState() => _NowPlayingStageState();
}

class _NowPlayingStageState extends State<_NowPlayingStage> {
  bool _pickingLyrics = false;
  bool? _showLyrics;
  Playback get player => widget.player;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.brightness == Brightness.dark
        ? ColorScheme.fromSeed(
            seedColor: const Color(0xFFFA567A),
            brightness: Brightness.dark,
            surface: Appearance.nightSurface,
            onSurface: Colors.white,
            onSurfaceVariant: const Color(0xFFD8CCD8),
          )
        : theme.colorScheme.copyWith(surface: Appearance.daySurface);
    final stageTheme = theme.copyWith(
      colorScheme: colors,
      textTheme: theme.textTheme.apply(
        bodyColor: colors.onSurface,
        displayColor: colors.onSurface,
      ),
      iconTheme: IconThemeData(color: colors.onSurface),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(foregroundColor: colors.onSurface),
      ),
    );
    final buttonBackground = colors.onSurface.withValues(alpha: 0.12);
    return ValueListenableBuilder(
      valueListenable: player.tracks,
      builder: (context, tracks, _) => StreamBuilder<PlaybackState>(
        stream: player.playbackState,
        initialData: player.playbackState.value,
        builder: (context, snapshot) {
          final state = snapshot.data ?? player.playbackState.value;
          final index = state.queueIndex;
          final track = index == null ? null : tracks.elementAtOrNull(index);
          final artist = track?.artist.trim() ?? '';
          final artists = {
            for (final name in artist.split('、').map((name) => name.trim()))
              if (name.isNotEmpty && name != '未知歌手') name,
          }.toList();
          final artwork = resolveCoverUrl(track?.artUri?.toString() ?? '', 480);
          return Theme(
            data: stageTheme,
            child: Material(
              color: colors.surface,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  _StageBackdrop(artwork: artwork),
                  SafeArea(
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final wide = !widget.mobile && constraints.maxWidth >= 660;
                        // 宽屏默认并排显示，手动切换后按用户选的视图显示。
                        final showLyrics =
                            track != null &&
                            (_showLyrics ?? (!wide && widget.showLyrics));
                        void toggleLyrics() =>
                            setState(() => _showLyrics = !showLyrics);
                        void openArtist() => openArtistFromPlayer(
                          context,
                          artists: artists,
                          library: widget.library,
                          player: player,
                        );
                        Widget artistLink(String text, TextStyle? style) => _ArtistLink(
                          text: text,
                          style: style,
                          onTap: artists.isEmpty ? null : openArtist,
                        );
                        return Column(
                          children: [
                            Padding(
                              padding: widget.mobile
                                  ? const EdgeInsets.fromLTRB(16, 4, 16, 4)
                                  : const EdgeInsets.fromLTRB(12, 4, 12, 0),
                              child: Row(
                                children: [
                                  IconButton(
                                    tooltip: '返回播放器',
                                    icon: const BackButtonIcon(),
                                    style: widget.mobile
                                        ? IconButton.styleFrom(
                                            backgroundColor: buttonBackground,
                                          )
                                        : null,
                                    onPressed: () =>
                                        Navigator.of(context).maybePop(),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: LayoutBuilder(
                                      builder: (context, heading) => Row(
                                        children: [
                                          Flexible(
                                            child: artistLink(
                                              track?.title ?? '尚未选择音乐',
                                              stageTheme
                                                  .textTheme
                                                  .titleLarge
                                                  ?.copyWith(
                                                    fontWeight: FontWeight.w800,
                                                  ),
                                            ),
                                          ),
                                          if (artist.isNotEmpty)
                                            Padding(
                                              padding:
                                                  const EdgeInsetsDirectional.only(
                                                    start: 8,
                                                  ),
                                              child: ConstrainedBox(
                                                constraints: BoxConstraints(
                                                  maxWidth:
                                                      heading.maxWidth / 3,
                                                ),
                                                child: artistLink(
                                                  artist,
                                                  stageTheme
                                                      .textTheme
                                                      .titleMedium
                                                      ?.copyWith(
                                                        color: colors
                                                            .onSurfaceVariant,
                                                      ),
                                                ),
                                              ),
                                            ),
                                        ],
                                      ),
                                    ),
                                  ),
                                  SleepTimerButton(player: player),
                                ],
                              ),
                            ),
                            Expanded(
                              child: _NowPlaying(
                                track: track,
                                artwork: artwork,
                                playing: state.playing,
                                player: player,
                                onPickLyrics: _pickLyrics,
                                onLoadOnlineLyrics: _loadOnlineLyrics,
                                onToggleLyrics: toggleLyrics,
                                mobile: widget.mobile,
                                wide: wide,
                                showLyrics: showLyrics,
                              ),
                            ),
                            // 播放选项合并到固定的底栏，滚动歌词时也能操作。
                            Padding(
                              padding: const EdgeInsets.only(bottom: 4),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  IconButton(
                                    tooltip: showLyrics
                                        ? '显示封面'
                                        : (widget.mobile ? '展开歌词' : '显示歌词'),
                                    isSelected: showLyrics,
                                    icon: const Icon(Icons.lyrics_outlined),
                                    selectedIcon: Icon(
                                      Icons.lyrics_rounded,
                                      color: colors.primary,
                                    ),
                                    style: widget.mobile && showLyrics
                                        ? IconButton.styleFrom(
                                            backgroundColor: buttonBackground,
                                          )
                                        : null,
                                    onPressed: track == null ? null : toggleLyrics,
                                  ),
                                  PlaybackModeButton(
                                    player: player,
                                    mode: state.repeatMode,
                                  ),
                                  PlaybackSpeedButton(
                                    player: player,
                                    speed: state.speed,
                                  ),
                                  Flexible(
                                    child: QualityButton(
                                      player: player,
                                      library: widget.library,
                                      track: track,
                                    ),
                                  ),
                                  FavoriteButton.track(
                                    library: widget.library,
                                    track: track,
                                  ),
                                ],
                              ),
                            ),
                          ],
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Future<void> _pickLyrics(Track track) async {
    if (_pickingLyrics) return;
    _pickingLyrics = true;
    try {
      final file = await FilePicker.pickFile(
        dialogTitle: '选择歌词文件',
        // 部分 Android 文档提供方没有为 .lrc 注册 MIME 类型。
      );
      if (file == null) return;
      final extension = file.extension?.toLowerCase();
      if (!const ['lrc', 'krc', 'yrc'].contains(extension) ||
          ((await file.length()) ?? 0) > 1024 * 1024) {
        throw const FormatException('请选择不超过 1 MB 的 LRC、KRC 或 YRC 文件。');
      }
      final bytes = await file.readAsBytes();
      final input =
          (extension == 'krc' ? decodeKrc(bytes) : null) ??
          utf8.decode(bytes, allowMalformed: true);
      if (parseLyrics(input).isEmpty) {
        throw const FormatException('文件中没有带时间标签的歌词。');
      }
      await player.setLyrics(track, input);
    } on FormatException catch (error) {
      _showMessage(error.message);
    } catch (_) {
      _showMessage('无法读取所选文件，请检查文件是否可访问。');
    } finally {
      _pickingLyrics = false;
    }
  }

  /// 从队列条目恢复歌词查询所需的信息，重启后也能补取歌词。
  Future<void> _loadOnlineLyrics(Track track) async {
    final hash = track.lyricHash;
    if (hash == null) return;
    final song = Song(hash: hash, title: track.title, duration: track.duration);
    try {
      final versions = await widget.library.lyricVersions(song);
      if (!mounted) return;
      if (versions.isEmpty) {
        _showMessage('没有找到这首歌的歌词。');
        return;
      }
      final version = versions.length == 1
          ? versions.first
          : await showModalBottomSheet<LyricVersion>(
              context: context,
              showDragHandle: true,
              builder: (context) => SafeArea(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    const ListTile(title: Text('选择歌词版本')),
                    for (final (index, item) in versions.indexed)
                      ListTile(
                        title: Text(
                          item.title.isEmpty ? track.title : item.title,
                        ),
                        subtitle: Text(
                          [
                            if (index == 0) '推荐',
                            if (item.author.isNotEmpty) item.author,
                            if (item.duration > 0) '${item.duration ~/ 1000} 秒',
                          ].join(' · '),
                        ),
                        onTap: () => Navigator.pop(context, item),
                      ),
                  ],
                ),
              ),
            );
      if (version == null || !mounted) return;
      final text = await widget.library.downloadLyrics(version);
      if (!mounted) return;
      if (text == null) {
        _showMessage('没有找到这首歌的歌词。');
        return;
      }
      await player.setLyrics(track, text);
      if (mounted) _showMessage('歌词已更新。');
    } catch (_) {
      _showMessage('无法获取在线歌词，请稍后重试。');
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;
    showMusicNotice(context, message);
  }
}

class _ArtistLink extends StatelessWidget {
  const _ArtistLink({required this.text, required this.style, required this.onTap});

  final String text;
  final TextStyle? style;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final label = Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: style);
    if (onTap == null) return label;
    return Tooltip(
      message: '查看歌手',
      excludeFromSemantics: true,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              widthFactor: 1,
              child: label,
            ),
          ),
        ),
      ),
    );
  }
}

enum _LyricAction { file, online }

class _NowPlaying extends StatefulWidget {
  const _NowPlaying({
    required this.track,
    required this.artwork,
    required this.playing,
    required this.player,
    required this.onPickLyrics,
    required this.onLoadOnlineLyrics,
    required this.onToggleLyrics,
    required this.mobile,
    required this.wide,
    required this.showLyrics,
  });

  final Track? track;
  final String artwork;
  final bool playing;
  final Playback player;
  final ValueChanged<Track> onPickLyrics;
  final ValueChanged<Track> onLoadOnlineLyrics;
  final VoidCallback onToggleLyrics;
  final bool mobile;
  final bool wide;
  final bool showLyrics;

  @override
  State<_NowPlaying> createState() => _NowPlayingState();
}

class _NowPlayingState extends State<_NowPlaying> {
  late List<LyricLine> _lyrics = parseLyrics(widget.track?.lyrics ?? '');

  @override
  void didUpdateWidget(covariant _NowPlaying oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.track?.lyrics != widget.track?.lyrics) {
      _lyrics = parseLyrics(widget.track?.lyrics ?? '');
    }
  }

  @override
  Widget build(BuildContext context) {
    final track = widget.track;
    final wide = widget.wide;
    final mobile = widget.mobile;
    final showLyrics = widget.showLyrics && track != null;
    return LayoutBuilder(
      builder: (context, constraints) {
        final horizontal = wide ? 36.0 : (mobile ? 24.0 : 22.0);
        final height = constraints.maxHeight;
        final available = constraints.maxWidth - horizontal * 2;
        final panelWidth =
            (wide && !showLyrics ? (available - 44) * 0.44 : available).clamp(
              0.0,
              wide && showLyrics ? 680.0 : 420.0,
            );
        final artworkSize = panelWidth.clamp(
          0.0,
          (height - 268).clamp(148.0, 420.0),
        );
        final controls = PlayerControls(
          player: widget.player,
          stage: true,
          showStageVolume: !mobile,
        );
        Widget artwork(double size) {
          final cover = _Artwork(
            url: widget.artwork,
            size: size,
            onTap: track == null ? null : widget.onToggleLyrics,
          );
          return Center(
            child: mobile
                ? cover
                : AnimatedScale(
                    scale: widget.playing ? 1 : 0.94,
                    duration: MediaQuery.disableAnimationsOf(context)
                        ? Duration.zero
                        : const Duration(milliseconds: 260),
                    curve: Curves.easeOutCubic,
                    child: cover,
                  ),
          );
        }
        if (mobile) {
          // 封面按安全区内的页面宽度计算，歌词和控件继续使用各自的留白。
          final coverSize = constraints.maxWidth * 0.8;
          final panelPadding = EdgeInsets.symmetric(
            horizontal: (constraints.maxWidth - panelWidth) / 2,
          );
          final panel = Padding(
            padding: const EdgeInsets.only(top: 4, bottom: 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (!showLyrics) ...[
                  artwork(coverSize),
                  const SizedBox(height: 8),
                ],
                Expanded(
                  child: track == null
                      ? const SizedBox.shrink()
                      : Padding(padding: panelPadding, child: _lyricPanel(track)),
                ),
                Padding(padding: panelPadding, child: controls),
              ],
            ),
          );
          // 矮屏和大字号通过滚动保留封面的尺寸，以及歌词和控件需要的高度。
          final minContentHeight = MediaQuery.textScalerOf(context).scale(24) > 32
              ? 320.0
              : 240.0;
          final minHeight = minContentHeight + (showLyrics ? 0.0 : coverSize + 8);
          return height < minHeight
              ? SingleChildScrollView(
                  primary: false,
                  child: SizedBox(height: minHeight, child: panel),
                )
              : panel;
        }
        final playerPanel = SizedBox(
          width: panelWidth,
          child: SingleChildScrollView(
            primary: false,
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (showLyrics)
                  SizedBox(
                    height: (height - 270).clamp(150.0, 540.0),
                    child: _lyricPanel(track),
                  )
                else
                  artwork(artworkSize),
                const SizedBox(height: 16),
                controls,
              ],
            ),
          ),
        );
        return Padding(
          padding: EdgeInsets.symmetric(horizontal: horizontal),
          child: wide && track != null && !showLyrics
              ? Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Center(child: playerPanel),
                    const SizedBox(width: 44),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        child: _lyricPanel(track),
                      ),
                    ),
                  ],
                )
              : Center(child: playerPanel),
        );
      },
    );
  }

  Widget _lyricPanel(Track track) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    // 展开时轻点歌词回到封面，长按和右键仍打开歌词选项。
    onTap: widget.showLyrics ? widget.onToggleLyrics : null,
    onLongPress: () => _showLyricActions(track),
    onSecondaryTap: () => _showLyricActions(track),
    child: _lyrics.isEmpty
        ? Center(
            child: Text(
              '还没有歌词',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          )
        : Padding(
            padding: const EdgeInsets.only(top: 8),
            child: SyncedLyrics(
              key: ValueKey(track.id),
              player: widget.player,
              lines: _lyrics,
              stage: true,
            ),
          ),
  );

  Future<void> _showLyricActions(Track track) async {
    final action = await showModalBottomSheet<_LyricAction>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(
              title: Text(_lyrics.isEmpty ? '导入歌词' : '更换歌词'),
              onTap: () => Navigator.pop(context, _LyricAction.file),
            ),
            if (track.lyricHash != null)
              ListTile(
                title: const Text('在线歌词版本'),
                onTap: () => Navigator.pop(context, _LyricAction.online),
              ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    switch (action) {
      case _LyricAction.file:
        widget.onPickLyrics(track);
      case _LyricAction.online:
        widget.onLoadOnlineLyrics(track);
      case null:
        break;
    }
  }
}

class _StageBackdrop extends StatelessWidget {
  const _StageBackdrop({required this.artwork});

  final String artwork;

  @override
  Widget build(BuildContext context) {
    final light = Theme.of(context).brightness == Brightness.light;
    return RepaintBoundary(
      child: ClipRect(
        child: Stack(
          fit: StackFit.expand,
          children: [
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: light
                      ? const [
                          Color(0xFFF0D7C8),
                          Color(0xFFF6E8DB),
                          Appearance.daySurface,
                        ]
                      : const [
                          Color(0xFF68404F),
                          Color(0xFF352340),
                          Color(0xFF14141E),
                        ],
                ),
              ),
            ),
            if (artwork.isNotEmpty)
              ImageFiltered(
                imageFilter: ImageFilter.blur(sigmaX: 48, sigmaY: 48),
                child: Image.network(
                  artwork,
                  fit: BoxFit.cover,
                  excludeFromSemantics: true,
                  errorBuilder: (_, _, _) => const SizedBox.shrink(),
                ),
              ),
            // 用同色遮罩压住封面明暗变化，歌词仍然清晰可读。
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: light
                      ? [
                          const Color(0xD9F8EADF),
                          Appearance.daySurface.withValues(alpha: 0.95),
                        ]
                      : const [Color(0xA0181020), Color(0xE614141E)],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Artwork extends StatelessWidget {
  const _Artwork({required this.url, required this.size, required this.onTap});

  final String url;
  final double size;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final placeholder = DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFAF5573), Color(0xFF452742)],
        ),
      ),
      child: Center(
        child: Icon(
          Icons.music_note_rounded,
          color: Colors.white70,
          size: size * 0.31,
        ),
      ),
    );
    final image = url.isEmpty
        ? placeholder
        : Image.network(
            url,
            fit: BoxFit.cover,
            excludeFromSemantics: true,
            errorBuilder: (_, _, _) => placeholder,
            frameBuilder: (_, child, frame, synchronous) =>
                frame == null && !synchronous ? placeholder : child,
          );
    // 横向和纵向各淡出一层，保留清晰的封面中心，让四周融入舞台背景。
    Widget fadeEdges(Alignment begin, Alignment end, Widget child) => ShaderMask(
      blendMode: BlendMode.dstIn,
      shaderCallback: (bounds) => LinearGradient(
        begin: begin,
        end: end,
        colors: const [
          Colors.transparent,
          Colors.white,
          Colors.white,
          Colors.transparent,
        ],
        stops: const [0, 0.13, 0.87, 1],
      ).createShader(bounds),
      child: child,
    );
    final cover = RepaintBoundary(
      child: fadeEdges(
        Alignment.topCenter,
        Alignment.bottomCenter,
        fadeEdges(Alignment.centerLeft, Alignment.centerRight, image),
      ),
    );
    return SizedBox(
      key: const ValueKey('now-playing-artwork'),
      width: size,
      height: size,
      child: onTap == null
          ? cover
          : Tooltip(
              message: '点击封面展开歌词',
              child: InkWell(onTap: onTap, child: cover),
            ),
    );
  }
}

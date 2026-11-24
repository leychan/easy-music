import 'dart:async';
import 'dart:io' show Platform;

import 'package:android_file_picker/android_file_picker.dart';
import 'package:audio_service/audio_service.dart';
import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../account/account.dart';
import '../account/kugou/kugou_auth.dart';
import '../music/music_library.dart';
import '../music/song.dart';
import '../player/lyrics.dart';
import '../player/playback.dart';
import '../player/session_store.dart';
import '../player/track.dart';
import 'appearance.dart';
import 'cover.dart';
import 'desktop_workspace.dart';
import 'discover_page.dart';
import 'external_actions.dart';
import 'glass_tabs.dart';
import 'mini_player_bar.dart';
import 'music_toast.dart';
import 'my_page.dart';
import 'now_playing.dart';
import 'player_controls.dart';
import 'search_page.dart';
import 'workspace_page.dart';

enum _DesktopAction { mini, lyrics }

class PlayerPage extends StatefulWidget {
  const PlayerPage({super.key, required this.player, this.appearance, this.account, this.sessionStore});

  final Playback player;
  final Appearance? appearance;
  final SessionStore? sessionStore;
  @visibleForTesting
  final Account? account;

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> with WidgetsBindingObserver {
  late final _account = widget.account ?? Account();
  late final _library = MusicLibrary(_account, store: widget.sessionStore);
  // 桌面切换标签会重建路由，用同一个存储保留发现页的滚动位置。
  final _discoverScroll = PageStorageBucket();
  final _section = ValueNotifier(AppSection.discover);
  final _desktopSearch = ValueNotifier<DesktopSearchRequest?>(null);
  bool _pickingFile = false;
  bool _checkedPlaybackNotifications = false;
  bool _mini = false;
  bool _desktopLyrics = false;
  StreamSubscription<Duration>? _desktopPosition;
  late final StreamSubscription<PlaybackState> _metadataEvents;
  StreamSubscription<String?>? _notificationTracks;
  (String, int, int)? _metadataTrack;
  String? _desktopLyricsSource;
  String? _desktopLine;
  List<LyricLine> _desktopLines = const [];

  Playback get player => widget.player;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _account.addListener(_accountChanged);
    unawaited(_account.checkDailyVip());
    _metadataEvents = player.playbackState.listen((_) => _loadTrackDetails());
    if (Platform.isAndroid) {
      player.isNotificationFavorite = (track) {
        final song = Song.fromTrack(track);
        return song != null && _library.isFavorite(song);
      };
      player.onToggleNotificationFavorite = _toggleNotificationFavorite;
      _library.addListener(player.refreshNotificationFavorite);
      // 后台切歌也会加载收藏，通知与页面里的红心共用同一份状态。
      _notificationTracks = player.mediaItem.map((item) => item?.id).distinct().listen((id) {
        if (id?.startsWith('kg:') == true) unawaited(_library.loadFavorites());
      });
      player.refreshNotificationFavorite();
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _notifyStartupIssues();
      _checkPlaybackNotifications();
    });
  }

  Future<void> _toggleNotificationFavorite(Track track) async {
    final song = Song.fromTrack(track);
    if (song == null || _library.favoriteBusy(song)) return;
    try {
      await _library.toggleFavorite(song);
    } on KugouFailure catch (error) {
      await showPlaybackNotificationNotice(error.message);
    } catch (_) {
      await showPlaybackNotificationNotice('收藏操作失败，请稍后重试。');
    }
  }

  void _accountChanged() {
    _loadTrackDetails();
    unawaited(_account.checkDailyVip());
  }

  /// 等首帧挂载后再显示启动提示。
  void _notifyStartupIssues() {
    final warning = _account.storageWarning;
    if (warning != null) _showMessage(warning);
  }

  void _checkPlaybackNotifications() {
    // 控件随首屏显示，权限申请也要等应用进入前台。
    if (!Platform.isAndroid || _checkedPlaybackNotifications ||
        WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
      return;
    }
    _checkedPlaybackNotifications = true;
    unawaited(_requestPlaybackNotifications());
  }

  Future<void> _requestPlaybackNotifications() async {
    try {
      if (await managePlaybackNotifications(automatic: true) && mounted) {
        player.refreshMediaNotification();
      }
    } on Exception catch (error) {
      debugPrint('Cannot request playback notification permission: ${error.runtimeType}');
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (Platform.isAndroid) {
        player.refreshMediaNotification();
        _checkPlaybackNotifications();
      }
      player.checkSleepTimer();
      unawaited(_account.checkDailyVip());
    }
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.hidden) {
      player.saveProgress();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_metadataEvents.cancel());
    if (_notificationTracks != null) {
      unawaited(_notificationTracks?.cancel());
      _library.removeListener(player.refreshNotificationFavorite);
      player.isNotificationFavorite = null;
      player.onToggleNotificationFavorite = null;
      player.refreshNotificationFavorite();
    }
    _account.removeListener(_accountChanged);
    _library.dispose();
    if (widget.account == null) _account.dispose();
    _section.dispose();
    _desktopSearch.dispose();
    unawaited(_desktopPosition?.cancel());
    if (_desktopLyrics) player.tracks.removeListener(_updateDesktopLyrics);
    super.dispose();
  }

  Future<void> _pickAudio() => _withFilePicker(() async {
    final files = await FilePicker.pickFiles(
      dialogTitle: '添加本地音乐',
      type: FileType.audio,
      // Android 保存文档的读取授权，播放器可直接打开原文件。
      androidOptions: const FilePickerAndroidOptions(
        safOptions: AndroidSAFOptions(
          grant: AndroidSAFGrant.lifetime,
          copyToCache: false,
        ),
      ),
    );
    final knownSources = player.tracks.value
        .map((track) => track.source)
        .toSet();
    await player.addTracks([
      for (final file in files)
        if (knownSources.add(file.uri))
          Track(
            id: const Uuid().v4(),
            title: p.basenameWithoutExtension(file.name),
            source: file.uri,
          ),
    ]);
  });

  Future<void> _withFilePicker(Future<void> Function() pick) async {
    if (_pickingFile) return;
    _pickingFile = true;
    try {
      await pick();
    } on FormatException catch (error) {
      _showMessage(error.message);
    } catch (_) {
      _showMessage('无法读取所选文件，请检查文件是否可访问。');
    } finally {
      _pickingFile = false;
    }
  }

  Future<void> _addLink() async {
    final track = await showDialog<Track>(
      context: context,
      builder: (context) => const _LinkDialog(),
    );
    if (track == null || !mounted) return;
    if (player.tracks.value.any((other) => other.source == track.source)) {
      _showMessage('这个链接已在播放队列中。');
      return;
    }
    try {
      await player.addTracks([track]);
    } catch (_) {
      _showMessage('无法添加音频链接。');
    }
  }

  /// 播放和恢复队列时后台补齐当前歌曲，进度变化不重复发请求。
  void _loadTrackDetails() {
    final track = player.tracks.value.elementAtOrNull(player.index);
    if (track == null || track.lyricHash == null || _account.client == null) {
      _metadataTrack = null;
      return;
    }
    final key = (track.id, track.albumAudioId, track.albumId);
    if (_metadataTrack == key) return;
    _metadataTrack = key;
    if (track.artUri == null) unawaited(_loadTrackCover(track));
    if (track.lyrics?.trim().isNotEmpty != true) {
      unawaited(_loadTrackLyrics(track, player.mediaItem.value?.duration));
    }
  }

  Future<void> _loadTrackCover(Track track) async {
    try {
      final cover = await _library.trackCover(track);
      if (mounted && cover != null) await player.setArtwork(track, cover);
    } on Exception {
      // 封面加载失败时保留占位图，播放照常进行。
    }
  }

  Future<void> _loadTrackLyrics(Track track, Duration? duration) async {
    try {
      final text = await _library.trackLyrics(
        track, duration: track.duration > Duration.zero ? track.duration : duration,
      );
      if (mounted && text != null) {
        await player.setLyrics(track, text, onlyIfMissing: true);
      }
    } on Exception {
      // 自动加载失败后仍可手动选择歌词版本。
    }
  }

  Future<void> _remove(Track track) async {
    try {
      await player.remove(track);
    } catch (_) {
      _showMessage('无法完成移除操作。');
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;
    showMusicNotice(context, message);
  }

  Future<void> _showNowPlaying({bool showLyrics = false}) => showNowPlaying(
    context, player: player, library: _library, showLyrics: showLyrics,
  );

  Future<void> _setMini(bool enabled) async {
    try {
      await setMiniWindow(enabled);
      if (mounted) setState(() => _mini = enabled);
    } catch (_) {
      _showMessage('无法切换迷你播放器。');
    }
  }

  Future<void> _toggleDesktopLyrics() async {
    final visible = !_desktopLyrics;
    try {
      await setDesktopLyricsVisible(visible);
      if (!mounted) return;
      setState(() => _desktopLyrics = visible);
      if (visible) {
        player.tracks.addListener(_updateDesktopLyrics);
        _desktopPosition = player.positionStream.listen((_) => _updateDesktopLyrics());
        _desktopLine = null;
        _updateDesktopLyrics();
      } else {
        player.tracks.removeListener(_updateDesktopLyrics);
        await _desktopPosition?.cancel();
        _desktopPosition = null;
      }
    } catch (_) {
      _showMessage('无法切换桌面歌词。');
    }
  }

  void _updateDesktopLyrics() {
    final track = player.tracks.value.elementAtOrNull(player.index);
    final source = track?.lyrics;
    if (_desktopLyricsSource != source) {
      _desktopLyricsSource = source;
      _desktopLines = parseLyrics(source ?? '');
    }
    final line = _desktopLines.elementAtOrNull(activeLyricIndex(_desktopLines, player.position));
    final text = [
      line?.text ?? track?.title ?? 'Easy Music',
      if (line?.translation case final translation? when translation.isNotEmpty)
        translation,
    ].join('\n');
    if (text == _desktopLine) return;
    _desktopLine = text;
    unawaited(setDesktopLyricText(text).catchError((Object _) {}));
  }

  @override
  Widget build(BuildContext context) {
    if (_mini) {
      return Scaffold(
        appBar: AppBar(
          toolbarHeight: 36,
          actions: [
            IconButton(
              tooltip: '恢复主窗口',
              icon: const Icon(Icons.open_in_full_rounded, size: 18),
              onPressed: () => _setMini(false),
            ),
          ],
        ),
        body: Align(
          alignment: Alignment.topCenter,
          child: MiniPlayerBar(
            player: player,
            library: _library,
            onOpen: ({required showLyrics}) async {
              await _setMini(false);
              if (mounted && !_mini) await _showNowPlaying(showLyrics: showLyrics);
            },
          ),
        ),
      );
    }
    final window = MediaQuery.sizeOf(context);
    if (Theme.of(context).platform == TargetPlatform.linux &&
        window.width >= 640 && window.height >= 400) {
      return ValueListenableBuilder(
        valueListenable: _section,
        builder: (context, section, _) => DesktopWorkspace(
          account: _account,
          library: _library,
          player: player,
          section: section,
          discover: _buildSection(
            AppSection.discover, desktop: true, active: section == AppSection.discover,
          ),
          content: section == AppSection.discover ? null : _buildSection(section, desktop: true),
          queue: _queuePanel(),
          sidebarActions: [_addMusicMenu(), if (Platform.isLinux) _desktopMenu()],
          onSelect: (section) => _section.value = section,
          onSearch: (keyword) {
            _desktopSearch.value = (keyword: keyword, revision: (_desktopSearch.value?.revision ?? 0) + 1);
            _section.value = AppSection.search;
          },
        ),
      );
    }
    return _buildBody(MiniPlayerBar(
      player: player,
      library: _library,
      onOpen: _showNowPlaying,
    ));
  }

  Widget _addMusicMenu() => PopupMenuButton<String>(
    tooltip: '添加音乐',
    icon: const Icon(Icons.add_rounded),
    onSelected: (value) => value == 'local' ? _pickAudio() : _addLink(),
    itemBuilder: (_) => const [
      PopupMenuItem(
        value: 'local',
        child: ListTile(
          leading: Icon(Icons.library_music_outlined),
          title: Text('本地音乐'),
          contentPadding: EdgeInsets.zero,
        ),
      ),
      PopupMenuItem(
        value: 'link',
        child: ListTile(
          leading: Icon(Icons.add_link_rounded),
          title: Text('音频链接'),
          contentPadding: EdgeInsets.zero,
        ),
      ),
    ],
  );

  Widget _desktopMenu() => PopupMenuButton<_DesktopAction>(
    tooltip: '桌面播放',
    onSelected: (action) => switch (action) {
      _DesktopAction.mini => _setMini(true),
      _DesktopAction.lyrics => _toggleDesktopLyrics(),
    },
    itemBuilder: (_) => [
      _desktopMenuItem(
        _DesktopAction.mini, Icons.picture_in_picture_alt_outlined, '迷你播放器',
      ),
      _desktopMenuItem(
        _DesktopAction.lyrics, Icons.lyrics_outlined, '桌面歌词',
        checked: _desktopLyrics,
      ),
    ],
  );

  PopupMenuItem<_DesktopAction> _desktopMenuItem(
    _DesktopAction action, IconData icon, String label, {bool? checked}
  ) => PopupMenuItem(
    value: action,
    child: Semantics(
      checked: checked,
      child: Row(
        children: [
          Icon(icon, size: 20),
          const SizedBox(width: 12),
          Expanded(child: Text(label)),
          const SizedBox(width: 12),
          // 两项都留出勾选位置，切换桌面歌词时菜单宽度保持一致。
          SizedBox(
            width: 18,
            child: checked == true ? const Icon(Icons.check_rounded, size: 18) : null,
          ),
        ],
      ),
    ),
  );

  Widget _queuePanel() => _QueuePanel(
    player: player,
    onSelect: player.skipToQueueItem,
    onRemove: _remove,
    onAddAudio: _pickAudio,
    onAddLink: _addLink,
  );

  Widget _buildBody(Widget playerBar) => ValueListenableBuilder(
    valueListenable: _section,
    builder: (context, section, _) => LayoutBuilder(
      builder: (context, constraints) {
        Widget discover(bool active) => _buildSection(AppSection.discover, active: active);
        final content = section == AppSection.discover ? null : _buildSection(section);
        // 宽屏：左侧队列常驻，右侧内容区切页。
        if (constraints.maxWidth - MediaQuery.paddingOf(context).horizontal >= 980) {
          return Scaffold(
            body: SafeArea(
              child: Column(
                  children: [
                    Expanded(
                      child: Row(
                        children: [
                          SizedBox(width: 320, child: _queuePanel()),
                          VerticalDivider(
                            width: 1,
                            color: Theme.of(context).colorScheme.outlineVariant,
                          ),
                          Expanded(
                            child: Column(
                              children: [
                                _SectionBar(
                                  value: _section,
                                  onChanged: (value) => _section.value = value,
                                  inline: true,
                                ),
                                Expanded(child: _MobileSection(discover: discover, content: content)),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    playerBar,
                  ],
              ),
            ),
          );
        }
        // 窄屏：底部导航切换队列与各内容页。
        return _QueueAwareScaffold(
          section: section,
          onChanged: (value) => _section.value = value,
          queue: _queuePanel(),
          discover: discover,
          content: content,
          playerBar: playerBar,
        );
      },
    ),
  );

  Widget _buildSection(AppSection section, {bool desktop = false, bool active = true}) => switch (section) {
    AppSection.discover => ListenableBuilder(
      listenable: _account,
      // 账号层初始化前没有可用客户端，先等待恢复，再发首次发现请求。
      builder: (context, _) => _account.loading
          ? const Center(child: CircularProgressIndicator())
          : PageStorage(
              bucket: _discoverScroll,
              child: DiscoverPage(
                library: _library,
                player: player,
                userid: _account.session?.userid,
                desktop: Theme.of(context).platform == TargetPlatform.linux,
                active: active,
              ),
            ),
    ),
    AppSection.search => SearchPage(
      key: ValueKey(desktop),
      library: _library,
      player: player,
      desktopSearch: desktop ? _desktopSearch : null,
    ),
    AppSection.mine => MyPage(
      account: _account,
      library: _library,
      player: player,
      appearance: widget.appearance,
    ),
  };
}

/// 切换标签时保留发现页的数据和滚动位置，其他页面按需构建。
class _MobileSection extends StatelessWidget {
  const _MobileSection({required this.discover, required this.content});

  final Widget Function(bool active) discover;
  final Widget? content;

  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.expand,
    children: [
      Visibility(visible: content == null, maintainState: true, child: discover(content == null)),
      ?content,
    ],
  );
}

/// 窄屏内容延伸到悬浮栏下，Scaffold 将底栏实测高度传给各页。
class _QueueAwareScaffold extends StatefulWidget {
  const _QueueAwareScaffold({
    required this.section,
    required this.onChanged,
    required this.queue,
    required this.discover,
    required this.content,
    required this.playerBar,
  });

  final AppSection section;
  final ValueChanged<AppSection> onChanged;
  final Widget queue;
  final Widget Function(bool active) discover;
  final Widget? content;
  final Widget playerBar;

  @override
  State<_QueueAwareScaffold> createState() => _QueueAwareScaffoldState();
}

class _QueueAwareScaffoldState extends State<_QueueAwareScaffold> {
  bool _showQueue = false;

  @override
  Widget build(BuildContext context) => Scaffold(
    extendBody: true,
    body: SafeArea(
      bottom: false,
      child: _MobileSection(
        discover: widget.discover,
        content: _showQueue ? widget.queue : widget.content,
      ),
    ),
    bottomNavigationBar: SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          widget.playerBar,
          GlassNavigationBar(
            selectedIndex: _showQueue ? 3 : widget.section.index,
            onDestinationSelected: (index) {
              if (index == 3) {
                setState(() => _showQueue = true);
                return;
              }
              setState(() => _showQueue = false);
              widget.onChanged(AppSection.values[index]);
            },
            destinations: const [
              NavigationDestination(
                icon: Icon(Icons.explore_outlined),
                selectedIcon: Icon(Icons.explore_rounded),
                label: '发现',
              ),
              NavigationDestination(
                icon: Icon(Icons.search_rounded),
                label: '搜索',
              ),
              NavigationDestination(
                icon: Icon(Icons.person_outline_rounded),
                selectedIcon: Icon(Icons.person_rounded),
                label: '我的',
              ),
              NavigationDestination(
                icon: Icon(Icons.queue_music_rounded),
                label: '队列',
              ),
            ],
          ),
        ],
      ),
    ),
  );
}

/// 宽屏时的横向标签栏。
class _SectionBar extends StatelessWidget {
  const _SectionBar({
    required this.value,
    required this.onChanged,
    this.inline = false,
  });

  final ValueNotifier<AppSection> value;
  final ValueChanged<AppSection> onChanged;
  final bool inline;

  static const _labels = {
    AppSection.discover: '发现',
    AppSection.search: '搜索',
    AppSection.mine: '我的',
  };

  @override
  Widget build(BuildContext context) {
    if (!inline) return const SizedBox.shrink();
    return ValueListenableBuilder(
      valueListenable: value,
      builder: (context, current, _) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
        child: Row(
          children: [
            for (final section in AppSection.values) ...[
              _TabButton(
                label: _labels[section]!,
                selected: section == current,
                onTap: () => onChanged(section),
              ),
              const SizedBox(width: 8),
            ],
          ],
        ),
      ),
    );
  }
}

class _TabButton extends StatelessWidget {
  const _TabButton({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    const radius = BorderRadius.all(Radius.circular(10));
    return GlassTabSelection(
      selected: selected,
      radius: radius,
      child: TextButton(
        onPressed: onTap,
        style: TextButton.styleFrom(
          foregroundColor: selected ? colors.onPrimaryContainer : null,
          shape: const RoundedRectangleBorder(borderRadius: radius),
        ),
        child: Text(label),
      ),
    );
  }
}

class _LinkDialog extends StatefulWidget {
  const _LinkDialog();

  @override
  State<_LinkDialog> createState() => _LinkDialogState();
}

class _LinkDialogState extends State<_LinkDialog> {
  final _url = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  void _submit() {
    try {
      final track = Track.online(const Uuid().v4(), _url.text);
      Navigator.pop(context, track);
    } on FormatException catch (error) {
      setState(() => _error = error.message);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('添加音频链接'),
    content: TextField(
      controller: _url,
      autofocus: true,
      keyboardType: TextInputType.url,
      textInputAction: TextInputAction.done,
      autocorrect: false,
      decoration: InputDecoration(labelText: 'HTTPS 音频直链', errorText: _error),
      onSubmitted: (_) => _submit(),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(onPressed: _submit, child: const Text('添加')),
    ],
  );
}

class _QueuePanel extends StatelessWidget {
  const _QueuePanel({
    required this.player,
    required this.onSelect,
    required this.onRemove,
    required this.onAddAudio,
    required this.onAddLink,
  });

  final Playback player;
  final Future<void> Function(int) onSelect;
  final Future<void> Function(Track) onRemove;
  final VoidCallback onAddAudio;
  final VoidCallback onAddLink;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ValueListenableBuilder(
      valueListenable: player.tracks,
      builder: (context, tracks, _) => StreamBuilder<PlaybackState>(
        stream: player.playbackState,
        initialData: player.playbackState.value,
        builder: (context, snapshot) {
          final current = snapshot.data?.queueIndex;
          if (tracks.isEmpty) {
            return Padding(
              padding: pageScrollPadding(context, EdgeInsets.zero),
              child: EmptyHint(
                icon: Icons.queue_music_rounded,
                title: '播放队列为空',
                message: '去「发现」播一首，或添加本地音乐。',
                action: FilledButton.tonalIcon(
                  onPressed: onAddAudio,
                  icon: const Icon(Icons.add_rounded),
                  label: const Text('添加本地音乐'),
                ),
              ),
            );
          }
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '播放队列',
                        style: theme.textTheme.titleMedium,
                      ),
                    ),
                    Text('${tracks.length} 首', style: theme.textTheme.labelMedium),
                    IconButton(
                      tooltip: '清空队列',
                      icon: const Icon(Icons.playlist_remove_rounded),
                      onPressed: () => runPlayerAction(context, player.clearQueue),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: Scrollbar(
                  child: ReorderableListView.builder(
                    buildDefaultDragHandles: false,
                    padding: pageScrollPadding(context, const EdgeInsets.fromLTRB(10, 0, 10, 12)),
                    itemCount: tracks.length,
                    onReorderItem: (from, to) => runPlayerAction(
                      context,
                      () => player.moveTrack(tracks[from].id, tracks[to].id),
                    ),
                    itemBuilder: (context, index) {
                      final track = tracks[index];
                      // ListTile 的底色画在 Material 上，让它随歌曲行一起被列表裁剪。
                      return Material(
                        key: ValueKey(track.id),
                        type: MaterialType.transparency,
                        child: ListTile(
                          selected: index == current,
                          selectedTileColor: theme.colorScheme.secondaryContainer,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 2,
                          ),
                          leading: Cover(
                            url: track.artUri?.toString() ?? '',
                            size: 44,
                            radius: 8,
                            icon: track.isLocal
                                ? Icons.music_note_rounded
                                : Icons.link_rounded,
                          ),
                          title: Text(
                            track.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            track.artist.isEmpty
                                ? (track.isLocal ? '本地文件' : track.source.host)
                                : track.artist,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          onTap: () => runPlayerAction(
                            context,
                            () => onSelect(index),
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                tooltip: '从队列移除',
                                icon: const Icon(Icons.close_rounded),
                                onPressed: () => onRemove(track),
                              ),
                              if (tracks.length > 1)
                                ReorderableDragStartListener(
                                  index: index,
                                  child: const Tooltip(
                                    message: '拖动排序',
                                    child: SizedBox.square(
                                      dimension: 40,
                                      child: Icon(Icons.drag_handle_rounded),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

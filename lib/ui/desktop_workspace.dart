import 'package:material_ui/material_ui.dart';

import '../account/account.dart';
import '../account/account_page.dart';
import '../music/music_library.dart';
import '../music/song.dart';
import '../player/playback.dart';
import 'cover.dart';
import 'discover_page.dart';
import 'glass_tabs.dart';
import 'history_page.dart';
import 'my_page.dart';
import 'now_playing.dart';
import 'personal_music_page.dart';
import 'desktop_player_bar.dart';
import 'workspace_page.dart';

enum AppSection { discover, search, mine }

enum _SidebarPage { account, fm, ranks, liked, cloud, history, recommended, playlists }

class DesktopWorkspace extends StatefulWidget {
  const DesktopWorkspace({
    super.key,
    required this.account,
    required this.library,
    required this.player,
    required this.section,
    required this.discover,
    required this.search,
    required this.content,
    required this.queue,
    required this.sidebarActions,
    required this.onSelect,
    required this.onSearch,
  });

  final Account account;
  final MusicLibrary library;
  final Playback player;
  final AppSection section;
  final Widget discover;
  final Widget? search;
  final Widget? content;
  final Widget queue;
  final List<Widget> sidebarActions;
  final ValueChanged<AppSection> onSelect;
  final ValueChanged<String> onSearch;

  @override
  State<DesktopWorkspace> createState() => _DesktopWorkspaceState();
}

class _DesktopWorkspaceState extends State<DesktopWorkspace> {
  final _search = TextEditingController();
  final _searchFocus = FocusNode();
  final _contentNavigator = GlobalKey<NavigatorState>();
  late final _contentObserver = _ContentObserver(_updatePlayerBar);
  ({Object destination, MaterialPage<void> page})? _sidebarPage;
  bool _collapsed = false;
  bool _queueVisible = false;
  bool _nowPlayingActive = false;
  int _playlistsAttempt = 0;
  int _submittedSearches = 0;
  int? _userid;
  String? _token;
  List<Playlist> _playlists = const [];

  @override
  void initState() {
    super.initState();
    widget.account.addListener(_accountChanged);
    _accountChanged();
  }

  @override
  void dispose() {
    widget.account.removeListener(_accountChanged);
    _search.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  void _accountChanged() {
    final session = widget.account.session;
    if (_userid == session?.userid && _token == session?.token) return;
    _userid = session?.userid;
    _token = session?.token;
    setState(() {
      _playlists = const [];
    });
    _loadPlaylists();
  }

  Future<void> _loadPlaylists() async {
    final attempt = ++_playlistsAttempt;
    if (_userid == null) return;
    try {
      final items = await widget.library.myPlaylists();
      if (!mounted || attempt != _playlistsAttempt) return;
      setState(() => _playlists = items);
    } catch (_) {
      // 「我的歌单」页可以显示加载错误并提供重试。
    }
  }

  void _submit(String text) {
    final keyword = text.trim();
    if (keyword.isEmpty) return;
    _submittedSearches++;
    _search.text = keyword;
    _searchFocus.unfocus();
    _selectSection(AppSection.search);
    widget.onSearch(keyword);
  }

  void _selectSearch() {
    _selectSection(AppSection.search);
    // 等搜索页可见后再聚焦，隐藏时输入框不会接收键盘事件。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.section == AppSection.search && _sidebarPage == null) {
        _searchFocus.requestFocus();
      }
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _returnToSelectedPage() {
    final page = _sidebarPage?.page;
    _contentNavigator.currentState?.popUntil((route) =>
      route.isFirst || identical(route.settings, page),
    );
  }

  void _selectSection(AppSection section) {
    _returnToSelectedPage();
    if (_sidebarPage != null || _queueVisible) {
      setState(() {
        _sidebarPage = null;
        _queueVisible = false;
      });
    }
    widget.onSelect(section);
  }

  void _open(Object destination, Widget content) {
    _returnToSelectedPage();
    if (_sidebarPage?.destination == destination && !_queueVisible) return;
    setState(() {
      if (_sidebarPage?.destination != destination) {
        _sidebarPage = (
          destination: destination,
          page: MaterialPage<void>(key: UniqueKey(), child: content),
        );
      }
      _queueVisible = false;
    });
  }

  /// 二级页也使用右侧导航，侧栏和播放栏不随内容一起切走。
  Widget _content() => NavigatorPopHandler<Object?>(
    onPopWithResult: (result) => _contentNavigator.currentState?.pop(result),
    child: DesktopPageScope(
      child: Navigator(
        key: _contentNavigator,
        observers: [_contentObserver],
        pages: [
          MaterialPage<void>(
            // 侧栏切换时保留发现和搜索，搜索栏与结果一起隐藏。
            child: Stack(
              fit: StackFit.expand,
              children: [
                Visibility(
                  visible: widget.section == AppSection.discover,
                  maintainState: true,
                  child: widget.discover,
                ),
                if (widget.search case final search?)
                  Visibility(
                    visible: widget.section == AppSection.search,
                    maintainState: true,
                    child: WorkspacePage(
                      title: const Text('搜索音乐'),
                      body: Column(
                        children: [
                          Builder(builder: _searchBar),
                          Expanded(child: search),
                        ],
                      ),
                    ),
                  ),
                ?widget.content,
              ],
            ),
          ),
          if (_sidebarPage case final selected?) selected.page,
        ],
        onDidRemovePage: (page) {
          if (mounted && identical(page, _sidebarPage?.page)) {
            setState(() => _sidebarPage = null);
          }
        },
      ),
    ),
  );

  void _openAccount() => _open(_SidebarPage.account, AccountPage(account: widget.account));

  void _openMyPlaylists() => _open(
    _SidebarPage.playlists,
    MyPlaylistsPage(account: widget.account, library: widget.library, player: widget.player),
  );

  void _openNowPlaying({required bool showLyrics}) {
    if (_contentObserver.showingNowPlaying) return;
    _contentNavigator.currentState?.push<void>(
      NowPlayingPage.route(
        player: widget.player, library: widget.library, showLyrics: showLyrics,
      ),
    );
  }

  void _updatePlayerBar() {
    // Navigator 也会在布局期间更新顶层路由，等当前帧绘制完再调整播放栏。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final playingPage = _contentObserver.showingNowPlaying;
      if (!mounted || _nowPlayingActive == playingPage) return;
      setState(() {
        _nowPlayingActive = playingPage;
        if (playingPage) _queueVisible = false;
      });
    });
  }

  void _openLikedPlaylist(Playlist playlist) {
    _open(
      _SidebarPage.liked,
      SongListPage(
        title: playlist.name,
        subtitle: playlist.songCount > 0 ? '${playlist.songCount} 首' : null,
        cover: playlist.cover,
        description: playlist.description,
        playlist: playlist,
        loader: () => widget.library.playlistSongs(playlist),
        library: widget.library,
        player: widget.player,
      ),
    );
  }

  void _openFm() => _open(
    _SidebarPage.fm,
    SongListPage(
      title: '私人 FM',
      loader: widget.library.startupFmSongs,
      loadMore: widget.library.appendStartupFmSongs,
      privateFm: true,
      library: widget.library,
      player: widget.player,
    ),
  );

  void _liked() {
    final liked = widget.library.likedPlaylist(_playlists);
    if (liked != null) {
      _openLikedPlaylist(liked);
    } else if (_userid == null) {
      _openAccount();
    } else {
      _openMyPlaylists();
    }
  }

  void _cloud() {
    if (_userid == null) {
      _openAccount();
    } else {
      _open(
        _SidebarPage.cloud,
        PersonalMusicPage(
          library: widget.library,
          player: widget.player,
          cloud: true,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final light = colors.brightness == Brightness.light;
    final canvas = Color.lerp(
      colors.surface,
      colors.primaryContainer,
      light ? 0.3 : 0.15,
    )!;
    final panel = Color.lerp(
      colors.surface,
      colors.surfaceContainerLowest,
      0.46,
    )!;
    return Scaffold(
      body: SafeArea(
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [canvas, colors.surfaceContainerLow, colors.surface],
            ),
          ),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final compact = constraints.maxWidth < 880 || _collapsed;
              return Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    SizedBox(
                      width: compact ? 56 : 204,
                      child: _sidebar(
                        context,
                        compact,
                        constraints.maxWidth >= 880,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        children: [
                          Expanded(
                            child: Material(
                              color: panel.withValues(
                                alpha: light ? 0.84 : 0.78,
                              ),
                              borderRadius: BorderRadius.circular(18),
                              clipBehavior: Clip.antiAlias,
                              child: LayoutBuilder(
                                builder: (context, workspace) => Stack(
                                  fit: StackFit.expand,
                                  children: [
                                    _content(),
                                    if (_queueVisible) ...[
                                      ModalBarrier(
                                        color: colors.scrim.withValues(alpha: 0.18),
                                        dismissible: true,
                                        semanticsLabel: '关闭播放队列',
                                        onDismiss: () => setState(() => _queueVisible = false),
                                      ),
                                      Positioned(
                                        top: 8,
                                        bottom: 8,
                                        right: 8,
                                        width: workspace.maxWidth > 356
                                            ? 340
                                            : workspace.maxWidth - 16,
                                        child: _queuePanel(context),
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                            ),
                          ),
                          if (!_nowPlayingActive) ...[
                            const SizedBox(height: 10),
                            DesktopPlayerBar(
                              player: widget.player,
                              library: widget.library,
                              panel: panel,
                              onOpen: _openNowPlaying,
                              queueVisible: _queueVisible,
                              onToggleQueue: () =>
                                  setState(() => _queueVisible = !_queueVisible),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _searchBar(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          Expanded(
            child: Align(
              alignment: Alignment.centerLeft,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 350),
                child: RawAutocomplete<String>(
                  textEditingController: _search,
                  focusNode: _searchFocus,
                  onSelected: _submit,
                  optionsBuilder: (value) async {
                    final text = value.text.trim();
                    if (text.isEmpty) return const <String>[];
                    await Future<void>.delayed(
                      const Duration(milliseconds: 250),
                    );
                    if (!mounted ||
                        _search.text.trim() != text ||
                        !_searchFocus.hasFocus) {
                      return const <String>[];
                    }
                    try {
                      return (await widget.library.suggest(text)).take(7);
                    } catch (_) {
                      return const <String>[];
                    }
                  },
                  fieldViewBuilder:
                      (context, controller, focusNode, submitOption) =>
                          TextField(
                            controller: controller,
                            focusNode: focusNode,
                            textInputAction: TextInputAction.search,
                            onSubmitted: (value) {
                      final before = _submittedSearches;
                              submitOption();
                              // 有高亮联想项时交给 Autocomplete，否则提交输入的原词。
                      if (_submittedSearches == before) _submit(value);
                            },
                            decoration: InputDecoration(
                              hintText: '搜索歌曲、歌手、专辑',
                              prefixIcon: IconButton(
                                tooltip: '提交搜索',
                                icon: const Icon(
                                  Icons.search_rounded,
                                  size: 20,
                                ),
                                onPressed: () => _submit(controller.text),
                              ),
                              filled: true,
                              fillColor: colors.surfaceContainerHighest
                                  .withValues(alpha: 0.60),
                              isDense: true,
                              constraints: const BoxConstraints(minHeight: 38),
                              contentPadding: const EdgeInsets.symmetric(
                                vertical: 10,
                              ),
                              prefixIconConstraints: const BoxConstraints(
                                minWidth: 40,
                              ),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(10),
                                borderSide: BorderSide.none,
                              ),
                            ),
                          ),
                  optionsViewBuilder: (context, onSelected, words) => Align(
                    alignment: Alignment.topLeft,
                    child: Material(
                      elevation: 6,
                      borderRadius: BorderRadius.circular(12),
                      clipBehavior: Clip.antiAlias,
                      child: SizedBox(
                        width: 252,
                        child: ListView(
                          shrinkWrap: true,
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          children: [
                            for (final (index, word) in words.indexed)
                              ListTile(
                                dense: true,
                                selected:
                                    AutocompleteHighlightedOption.of(context) ==
                                    index,
                                title: Text(
                                  word,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                onTap: () => onSelected(word),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _sidebar(BuildContext context, bool compact, bool canExpand) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListenableBuilder(
          listenable: widget.account,
          builder: (context, _) {
            final session = widget.account.session;
            return _SidebarItem(
              compact: compact,
              label: session?.nickname ?? '登录酷狗',
              subtitle: session == null
                  ? null
                  : (session.vipType > 0 ? '酷狗 VIP' : '酷狗账号'),
              leading: Cover(
                url: session?.avatar ?? '',
                size: 34,
                radius: 17,
                icon: Icons.person_outline_rounded,
              ),
              trailing: const Icon(Icons.expand_more_rounded, size: 17),
              filled: true,
              selected: _sidebarPage?.destination == _SidebarPage.account,
              onTap: _openAccount,
            );
          },
        ),
        const SizedBox(height: 14),
        Expanded(
          child: ListView(
            padding: EdgeInsets.zero,
            children: [
              _quickNavigation(context, compact),
              const SizedBox(height: 12),
              for (final (icon, title, active, callback) in [
                (Icons.favorite_border_rounded, '我喜欢', _sidebarPage?.destination == _SidebarPage.liked, _liked),
                (Icons.cloud_outlined, '音乐云盘', _sidebarPage?.destination == _SidebarPage.cloud, _cloud),
                (
                  Icons.history_rounded,
                  '最近播放',
                  _sidebarPage?.destination == _SidebarPage.history,
                  () => _open(
                    _SidebarPage.history,
                    HistoryPage(player: widget.player, library: widget.library),
                  ),
                ),
                (
                  Icons.library_music_outlined,
                  '推荐歌单',
                  _sidebarPage?.destination == _SidebarPage.recommended,
                  () => _open(
                    _SidebarPage.recommended,
                    RecommendedPlaylistsPage(
                      library: widget.library,
                      player: widget.player,
                    ),
                  ),
                ),
                (
                  Icons.person_outline_rounded,
                  '我的',
                  _sidebarPage == null && widget.section == AppSection.mine,
                  () => _selectSection(AppSection.mine),
                ),
                (
                  Icons.playlist_play_rounded,
                  '我的歌单',
                  _sidebarPage?.destination == _SidebarPage.playlists,
                  _openMyPlaylists,
                ),
              ])
                _SidebarItem(
                  compact: compact,
                  label: title,
                  icon: icon,
                  onTap: callback,
                  selected: active,
                ),
            ],
          ),
        ),
        const SizedBox(height: 6),
        Wrap(
          alignment: compact ? WrapAlignment.center : WrapAlignment.start,
          children: [
            if (canExpand)
              IconButton(
                tooltip: compact ? '展开侧栏' : '收起侧栏',
                icon: Icon(
                  compact
                      ? Icons.chevron_right_rounded
                      : Icons.chevron_left_rounded,
                ),
                onPressed: () => setState(() => _collapsed = !_collapsed),
              ),
            ...widget.sidebarActions,
          ],
        ),
      ],
    );
  }

  Widget _quickNavigation(BuildContext context, bool compact) {
    final colors = Theme.of(context).colorScheme;
    return GridView.count(
      crossAxisCount: compact ? 1 : 2,
      mainAxisExtent: compact ? 40 : 47,
      mainAxisSpacing: 6,
      crossAxisSpacing: 6,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      children: [
        for (final (icon, title, active, callback) in [
          (
            Icons.explore_outlined,
            '发现',
            _sidebarPage == null && widget.section == AppSection.discover,
            () => _selectSection(AppSection.discover),
          ),
          (
            Icons.search_rounded,
            '搜索',
            _sidebarPage == null && widget.section == AppSection.search,
            _selectSearch,
          ),
          (
            Icons.radio_rounded,
            '私人 FM',
            _sidebarPage?.destination == _SidebarPage.fm,
            _openFm,
          ),
          (
            Icons.bar_chart_rounded,
            '排行榜',
            _sidebarPage?.destination == _SidebarPage.ranks,
            () => _open(
              _SidebarPage.ranks,
              RankingsPage(library: widget.library, player: widget.player),
            ),
          ),
        ])
          GlassTabSelection(
            selected: active,
            radius: const BorderRadius.all(Radius.circular(11)),
            backgroundColor: colors.surfaceContainerHighest.withValues(alpha: 0.52),
            child: Tooltip(
              message: title,
              child: Material(
                type: MaterialType.transparency,
                borderRadius: BorderRadius.circular(11),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: callback,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        icon,
                        size: 19,
                        color: active
                            ? colors.onPrimaryContainer
                            : colors.onSurfaceVariant,
                      ),
                      if (!compact) ...[
                        const SizedBox(width: 6),
                        Text(
                          title,
                          style: Theme.of(context).textTheme.labelMedium
                              ?.copyWith(
                                color: active
                                    ? colors.onPrimaryContainer
                                    : colors.onSurfaceVariant,
                              ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _queuePanel(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      elevation: 8,
      color: colors.surfaceContainerLow,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          Align(
            alignment: Alignment.centerRight,
            child: IconButton(
              tooltip: '收起队列',
              icon: const Icon(Icons.close_rounded, size: 20),
              onPressed: () => setState(() => _queueVisible = false),
            ),
          ),
          Expanded(child: widget.queue),
        ],
      ),
    );
  }
}

class _ContentObserver extends NavigatorObserver {
  _ContentObserver(this.onPageChanged);

  final VoidCallback onPageChanged;
  bool showingNowPlaying = false;

  @override
  void didChangeTop(Route<dynamic> topRoute, Route<dynamic>? previousTopRoute) {
    // 歌词版本选择等弹窗仍属于当前页，播放栏继续沿用当前页的显示状态。
    if (topRoute is! PageRoute) return;
    showingNowPlaying = topRoute.settings.name == NowPlayingPage.routeName;
    onPageChanged();
  }
}

class _SidebarItem extends StatelessWidget {
  const _SidebarItem({
    required this.compact,
    required this.label,
    required this.onTap,
    this.subtitle,
    this.icon,
    this.leading,
    this.trailing,
    this.selected = false,
    this.filled = false,
  });

  final bool compact;
  final String label;
  final String? subtitle;
  final IconData? icon;
  final Widget? leading;
  final Widget? trailing;
  final bool selected;
  final bool filled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final foreground = selected ? colors.onPrimaryContainer : colors.onSurface;
    const radius = BorderRadius.all(Radius.circular(10));
    return Padding(
      padding: const EdgeInsets.only(bottom: 3),
      child: GlassTabSelection(
        selected: selected,
        radius: radius,
        backgroundColor: filled
            ? colors.surfaceContainerHighest.withValues(alpha: 0.64)
            : Colors.transparent,
        child: Tooltip(
          message: compact ? label : '',
          child: Material(
            type: MaterialType.transparency,
            borderRadius: radius,
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: onTap,
              child: Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: compact ? 0 : 9,
                  vertical: filled ? 10 : 8,
                ),
                child: Row(
                  mainAxisAlignment: compact
                      ? MainAxisAlignment.center
                      : MainAxisAlignment.start,
                  children: [
                    leading ?? Icon(icon, size: 19, color: foreground),
                    if (!compact) ...[
                      const SizedBox(width: 9),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: foreground,
                                fontWeight: filled || selected
                                    ? FontWeight.w600
                                    : null,
                              ),
                            ),
                            if (subtitle != null)
                              Text(
                                subtitle!,
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: colors.onSurfaceVariant,
                                ),
                              ),
                          ],
                        ),
                      ),
                      ?trailing,
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

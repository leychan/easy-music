import 'dart:async';
import 'dart:ui' show PointerDeviceKind;

import 'package:material_ui/material_ui.dart';

import '../account/kugou/kugou_auth.dart';
import '../music/catalog.dart';
import '../music/kugou_music_api.dart';
import '../music/music_library.dart';
import '../music/song.dart';
import '../player/playback.dart';
import 'app_background.dart';
import 'catalog_pages.dart';
import 'cover.dart';
import 'favorite_button.dart';
import 'music_toast.dart';
import 'now_playing.dart';
import 'player_controls.dart' show runPlayerAction;
import 'search_page.dart';
import 'playlist_actions.dart';
import 'playlist_list_tile.dart';
import 'song_tile.dart';
import 'workspace_page.dart';

/// 发现页：私人 FM、每日推荐和推荐歌单。
class DiscoverPage extends StatefulWidget {
  const DiscoverPage({
    super.key,
    required this.library,
    required this.player,
    required this.userid,
    this.desktop = false,
    this.active = true,
  });

  final MusicLibrary library;
  final Playback player;
  final int? userid;
  bool get signedIn => userid != null;
  final bool desktop;
  final bool active;

  @override
  State<DiscoverPage> createState() => _DiscoverPageState();
}

class _DiscoverPageState extends State<DiscoverPage> {
  List<Song>? _fm;
  List<Song>? _daily;
  List<Playlist>? _playlists;
  Future<void>? _refreshingDaily;
  bool _loadingMoreFm = false;
  String? _fmError;
  String? _moreFmError;
  String? _dailyError;
  String? _playlistError;
  bool _startedRecommendations = false;
  bool _loadingFm = false;
  bool _loadingPlaylists = false;
  bool _openingSong = false;
  int _loadAttempt = 0;

  @override
  void initState() {
    super.initState();
    _restore();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _loadWhenVisible();
  }

  @override
  void didUpdateWidget(covariant DiscoverPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.userid != oldWidget.userid || widget.library != oldWidget.library) {
      _loadAttempt++;
      _refreshingDaily = null;
      _startedRecommendations = false;
      _loadingFm = _loadingPlaylists = _loadingMoreFm = false;
      _fmError = _moreFmError = _dailyError = _playlistError = null;
      _restore();
    }
    _loadWhenVisible();
  }

  void _restore() {
    final cache = widget.library.discoverCache;
    final owner = widget.userid;
    _fm = owner == null ? null : cache.readFm(owner);
    _daily = cache.readDaily(owner);
    _playlists = cache.readPlaylists(owner);
  }

  void _loadWhenVisible() {
    // 仅在首次打开或更换账号后自动加载，切回发现时继续显示原有结果。
    if (_startedRecommendations) return;
    final visible = widget.active && (!widget.desktop || (ModalRoute.isCurrentOf(context) ?? true));
    if (!visible) return;
    _loadRecommendations();
    unawaited(_refreshDaily());
  }

  void _loadRecommendations() {
    _startedRecommendations = true;
    _loadingFm = widget.signedIn;
    _loadingPlaylists = true;
    final attempt = _loadAttempt;
    final library = widget.library;
    bool isCurrent() => attempt == _loadAttempt;

    // 由音乐库记录冷启动的请求，切换标签后重建页面时只接回同一批结果。
    if (_loadingFm) {
      unawaited(_loadSection(
        library.discoverFmSongs,
        '加载私人 FM 失败。', (items, error) {
          _fm = items ?? _fm;
          _fmError = error;
          _loadingFm = false;
        }, isCurrent: isCurrent,
      ));
    }
    unawaited(_loadSection(
      library.discoverPlaylists,
      '加载推荐歌单失败。', (items, error) {
        _playlists = items ?? _playlists;
        _playlistError = error;
        _loadingPlaylists = false;
      }, isCurrent: isCurrent,
    ));
  }

  Future<void> _refreshDaily() {
    if (_refreshingDaily case final pending?) return pending;
    final attempt = _loadAttempt;
    final owner = widget.userid;
    final library = widget.library;
    bool isCurrent() => attempt == _loadAttempt;

    // 每日推荐独立刷新，避免打断正在进行的私人 FM 分页。
    final pending = _loadSection(
      library.dailyRecommend,
      '加载每日推荐失败，请稍后重试。', (items, error) {
        if (items != null) {
          _daily = items;
          library.discoverCache.saveDaily(owner, items);
        }
        _dailyError = error;
        _refreshingDaily = null;
      }, isCurrent: isCurrent,
    );
    setState(() {
      _refreshingDaily = pending;
    });
    return pending;
  }

  bool _onFmScroll(ScrollNotification notification) {
    // 从左边缘弹回来也会产生正向位移，忽略这段回弹，避免误触发预取。
    if (_loadingFm || _loadingMoreFm || widget.library.startupFmExhausted || _moreFmError != null ||
        notification.depth != 0 || notification.metrics.axis != Axis.horizontal ||
        notification.metrics.extentAfter > 144 ||
        notification.metrics.pixels <= notification.metrics.minScrollExtent) {
      return false;
    }
    final delta = switch (notification) {
      ScrollUpdateNotification(:final scrollDelta) => scrollDelta ?? 0,
      OverscrollNotification(:final overscroll) => overscroll,
      _ => 0,
    };
    // 向列表末尾滑动时预取，等当前滚动通知分发完再更新界面。
    if (delta > 0) scheduleMicrotask(_loadMoreFm);
    return false;
  }

  Future<void> _loadMoreFm() async {
    // 打开竖向列表后，发现页剩余的惯性滚动不再发起分页。
    if (!mounted || !widget.signedIn || (_fm?.isEmpty ?? true) ||
        _loadingFm || _loadingMoreFm || widget.library.startupFmExhausted ||
        ModalRoute.isCurrentOf(context) == false) {
      return;
    }
    final owner = widget.userid;
    final attempt = _loadAttempt;
    setState(() {
      _loadingMoreFm = true;
      _moreFmError = null;
    });
    await _loadSection(
      widget.library.appendStartupFmSongs,
      '加载更多私人 FM 失败，请稍后重试。',
      (items, error) {
        if (items != null) _fm = items;
        _moreFmError = error;
        _loadingMoreFm = false;
      },
      isCurrent: () => attempt == _loadAttempt && widget.userid == owner,
    );
  }

  Widget? _fmFooter() {
    if (_loadingMoreFm) {
      return const Center(
        child: CircularProgressIndicator(semanticsLabel: '正在加载私人 FM'),
      );
    }
    if (_moreFmError case final error?) {
      return Center(
        child: Tooltip(
          message: error,
          child: TextButton(onPressed: _loadMoreFm, child: const Text('重试')),
        ),
      );
    }
    return null;
  }

  Future<void> _loadSection<T>(
    Future<T> Function() fetch,
    String fallback,
    void Function(T?, String?) publish, {
    bool Function()? isCurrent,
  }) async {
    T? items;
    String? error;
    try {
      items = await fetch();
    } on KugouFailure catch (failure) {
      error = failure.message;
    } on Object {
      error = fallback;
    }
    if (mounted && (isCurrent?.call() ?? true)) setState(() => publish(items, error));
  }

  Widget _sectionNotice({
    required bool loading, required String? error, required String emptyText,
    VoidCallback? onRetry,
  }) {
    if (loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 20),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (error != null && onRetry != null) return _ErrorView(message: error, onRetry: onRetry);
    return _Hint(error ?? emptyText);
  }

  Future<void> _playSong(Song song) async {
    if (_openingSong) return;
    _openingSong = true;
    try {
      await playSongFromList(
        context,
        trackId: song.id,
        player: widget.player,
        library: widget.library,
        play: () => widget.library.playSong(song, widget.player, resumeCurrent: true),
      );
    } finally {
      _openingSong = false;
    }
  }

  Future<void> _playAll(List<Song> songs, {required bool privateFm}) async {
    final outcome = await widget.library.playAll(songs, widget.player, privateFm: privateFm);
    if (!mounted) return;
    final notice = outcome.notice;
    if (notice != null) showMusicNotice(context, notice);
  }

  bool _showFeedHearts(BuildContext context) => switch (Theme.of(context).platform) {
    TargetPlatform.android || TargetPlatform.iOS => false,
    _ => true,
  };

  void _openFeed(String title, List<Song> songs, {required bool privateFm}) {
    final library = widget.library;
    final attempt = _loadAttempt;
    final showHearts = _showFeedHearts(context);

    Future<List<Song>> appendFm() async {
      final updated = await library.appendStartupFmSongs();
      // 返回发现页时，即使竖向列表的请求还没完成，横向卡片也会收到结果。
      if (mounted && attempt == _loadAttempt) {
        setState(() {
          _fm = updated;
          _moreFmError = null;
        });
      }
      return updated;
    }

    Navigator.of(context).push<void>(MaterialPageRoute(
      builder: (_) => SongListPage(
        title: title,
        loader: privateFm ? library.startupFmSongs : () async => songs,
        loadMore: privateFm ? appendFm : null,
        privateFm: privateFm,
        showFavoriteButton: showHearts,
        player: widget.player,
        library: library,
      ),
    ));
  }

  Widget _songSection(
    BuildContext context, {
    required String title,
    required List<Song> songs,
    required bool loading,
    required String? error,
    required String emptyText,
    bool privateFm = false,
    VoidCallback? onRetry,
    Widget? footer,
  }) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      MusicSectionHeader(
        title: title,
        onPlayAll: songs.isEmpty
            ? null
            : () => _playAll(songs, privateFm: privateFm),
        onViewAll: songs.isEmpty ? null : () => _openFeed(title, songs, privateFm: privateFm),
      ),
      if (songs.isEmpty)
        _sectionNotice(loading: loading, error: error, emptyText: emptyText, onRetry: onRetry)
      else
        _DiscoverCarousel(
          count: songs.length + (footer == null ? 0 : 1),
          desktop: widget.desktop,
          itemBuilder: (context, index, size) {
            if (index == songs.length && footer != null) {
              // 给尾项与封面相同的高度，让加载图标和重试按钮对齐封面中心。
              return SizedBox.square(dimension: size, child: footer);
            }
            final song = songs[index];
            return _DiscoverCard(
              cover: song.coverUrl(240),
              title: song.title,
              size: size,
              overlay: _showFeedHearts(context)
                  ? FavoriteButton(song: song, library: widget.library, compact: true)
                  : null,
              onTap: () => _playSong(song),
            );
          },
          storageKey: PageStorageKey(title),
          onScroll: privateFm ? _onFmScroll : null,
        ),
    ],
  );

  Widget _recommendedSection(BuildContext context, List<Playlist> playlists) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      MusicSectionHeader(
        title: '推荐歌单',
        onViewAll: () => Navigator.of(context).push<void>(MaterialPageRoute(
          builder: (_) => RecommendedPlaylistsPage(
            library: widget.library, player: widget.player,
          ),
        )),
      ),
      if (playlists.isEmpty)
        _sectionNotice(
          loading: _loadingPlaylists && _playlists == null,
          error: _playlists == null ? _playlistError : null, emptyText: '暂时没有推荐歌单。',
        )
      else
        _RecommendedPlaylistRow(
          playlists: playlists, library: widget.library, player: widget.player,
          desktop: widget.desktop,
        ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final workspace = DesktopPageScope.active(context);
    // 进度条悬浮在列表上方，出现和消失都不会挤动卡片。
    return Stack(
      fit: StackFit.expand,
      children: [
        RefreshIndicator(onRefresh: _refreshDaily, child: _buildFeed(context, workspace)),
        if (_refreshingDaily != null || _loadingFm || _loadingPlaylists)
          const Positioned(
            top: 0, left: 0, right: 0,
            child: IgnorePointer(
              child: LinearProgressIndicator(minHeight: 2, semanticsLabel: '正在刷新发现'),
            ),
          ),
      ],
    );
  }

  Widget _buildFeed(BuildContext context, bool workspace) => ListView(
    key: const PageStorageKey('discover-feed'),
    physics: const AlwaysScrollableScrollPhysics(),
    padding: pageScrollPadding(
      context,
      workspace
          ? const EdgeInsets.fromLTRB(24, 22, 24, 28)
          : const EdgeInsets.fromLTRB(20, 16, 20, 24),
    ),
    children: [
      if (workspace) ...[
        WorkspaceHeading(
          title: const Text('发现音乐'),
          actions: [
            IconButton(
              tooltip: '刷新每日推荐',
              icon: const Icon(Icons.refresh_rounded),
              onPressed: _refreshingDaily != null ? null : _refreshDaily,
            ),
          ],
        ),
        const SizedBox(height: 20),
      ],
      _songSection(
        context,
        title: '私人 FM',
        songs: _fm ?? const [],
        loading: _loadingFm && _fm == null,
        error: _fm == null ? _fmError : null,
        emptyText: widget.signedIn ? '暂时没有私人 FM 推荐。' : '登录酷狗后可查看私人 FM 推荐。',
        privateFm: true,
        footer: _fmFooter(),
      ),
      const SizedBox(height: 18),
      _songSection(
        context,
        title: '每日推荐',
        songs: _daily ?? const [],
        loading: _refreshingDaily != null && _daily == null,
        error: _daily == null ? _dailyError : null,
        emptyText: '暂时没有推荐内容。',
        onRetry: _refreshDaily,
      ),
      const SizedBox(height: 18),
      _recommendedSection(context, _playlists ?? const []),
    ],
  );
}

typedef _DiscoverItemBuilder = Widget Function(BuildContext context, int index, double size);

/// 使用真实滚动距离计算卡片位置，触摸、鼠标和触控板共用同一套展开效果。
class _DiscoverCarousel extends StatefulWidget {
  const _DiscoverCarousel({
    required this.count, required this.itemBuilder, required this.storageKey,
    required this.desktop, this.onScroll,
  });

  final int count;
  final _DiscoverItemBuilder itemBuilder;
  final Key storageKey;
  final bool desktop;
  final bool Function(ScrollNotification)? onScroll;

  @override
  State<_DiscoverCarousel> createState() => _DiscoverCarouselState();
}

class _DiscoverCarouselState extends State<_DiscoverCarousel> {
  static const _peek = 18.0;
  static const _maxStackDepth = 3;
  static const _maxCardSize = 148.0;
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final behavior = ScrollConfiguration.of(context);
    final scaler = MediaQuery.textScalerOf(context);
    return LayoutBuilder(builder: (context, constraints) {
      const gap = 12.0;
      final width = constraints.maxWidth;
      final size = ((width - 2 * gap - 2 * _peek) / 3).clamp(48.0, _maxCardSize);
      final stride = size + gap;
      final height = size + 16 + (scaler.scale(16) + scaler.scale(12)) * 1.2;
      final flatWidth = widget.count * stride - gap;
      // 卡片到达最大尺寸后，用多出来的空间平铺更多卡片。
      var flatSlots = 3;
      if (widget.desktop || size == _maxCardSize) {
        flatSlots = flatWidth <= width ? widget.count
            : ((width + gap - 2 * _peek) / stride).floor().clamp(1, widget.count);
      }
      final scrollSlots = (widget.count - flatSlots).clamp(0, widget.count);
      // 宽屏上也能一直滑到最后一张完全展开。
      final contentWidth = (width + scrollSlots * stride)
          .clamp(flatWidth, double.infinity);
      // 滚动帧只更新可见卡片的位置与深度，封面和按钮等内容在窗口内复用。
      final cards = <int, Widget>{};
      return SizedBox(
        height: height,
        child: ScrollConfiguration(
          behavior: behavior.copyWith(dragDevices: {...behavior.dragDevices, PointerDeviceKind.mouse}),
          child: NotificationListener<ScrollNotification>(
            onNotification: widget.onScroll,
            child: SingleChildScrollView(
              key: widget.storageKey,
              controller: _scroll,
              physics: _DiscoverScrollPhysics(
                parent: widget.onScroll == null ? null : const AlwaysScrollableScrollPhysics(),
              ),
              scrollDirection: Axis.horizontal,
              child: SizedBox(
                width: contentWidth,
                height: height,
                child: AnimatedBuilder(
                  animation: _scroll,
                  builder: (context, _) {
                    // 窗口放大时，布局可能还没更新滚动上限，先按新宽度校正卡片位置。
                    final offset = _scroll.hasClients
                        ? _scroll.offset.clamp(0.0, contentWidth - width) : 0.0;
                    return _cards(context, cards, size, stride, flatSlots, offset);
                  },
                ),
              ),
            ),
          ),
        ),
      );
    });
  }

  Widget _cards(BuildContext context, Map<int, Widget> cards, double size, double stride,
      int flatSlots, double offset) {
    if (widget.count == 0) return const SizedBox.shrink();
    final first = (offset / stride).floor().clamp(0, widget.count - 1);
    final last = (first + flatSlots + _maxStackDepth - 1).clamp(first, widget.count - 1);
    final stackStart = (flatSlots - 1) * stride;
    cards.removeWhere((index, _) => index < first || index > last);
    return Stack(children: [
      // 新入窗口的封面在最深处与上一张重合，随滑动露出，不会突然跳进画面。
      for (var index = last; index >= first; index--)
        _card(index, offset, size, stride, stackStart,
          cards.putIfAbsent(index, () => widget.itemBuilder(context, index, size)),
        ),
    ]);
  }

  Widget _card(int index, double offset, double size, double stride, double stackStart, Widget child) {
    final naturalLeft = index * stride - offset;
    final distance = naturalLeft - stackStart;
    final depth = (distance / stride).clamp(0.0, _maxStackDepth.toDouble());
    final stacked = depth > 0.04;
    // 顶部卡片在摊平前逐步恢复原尺寸，靠近堆叠末端时逐步停止缩小。
    final shape = depth <= 1 ? _softenEdge(depth) : _maxStackDepth - _softenEdge(_maxStackDepth - depth);
    return Positioned(
      key: ValueKey(index),
      left: index * stride,
      top: 0,
      width: size,
      child: Transform.translate(
        offset: Offset(
          depth == 0 ? 0 : _stackedOffset(depth, stride) - distance,
          shape * 4,
        ),
        child: Transform.scale(
          alignment: Alignment.topLeft,
          scale: 1 - 0.065 * shape,
          child: ExcludeSemantics(
            excluding: stacked,
            child: IgnorePointer(
              ignoring: stacked,
              child: _DiscoverDepth(value: depth, child: child),
            ),
          ),
        ),
      ),
    );
  }

  double _stackedOffset(double depth, double stride) {
    if (depth >= 1) return _peek * (_maxStackDepth - _softenEdge(_maxStackDepth - depth));

    // 在接近平铺的最后一小段，速度逐渐追上滚动速度。第一层的露边仍是 peek。
    const blend = 24.0;
    const adjustment = blend / 3;
    final rate = _peek / stride;
    final distance = depth * stride;
    final remaining = 1 - (distance / blend).clamp(0.0, 1.0);
    final recover = ((distance - blend) / (stride - blend)).clamp(0.0, 1.0);
    final release = 1 - remaining * remaining * remaining;
    final settle = recover * recover * (3 - 2 * recover);
    return rate * distance + (1 - rate) * adjustment * (release - settle);
  }

  double _softenEdge(double depth) {
    const blend = 0.35;
    if (depth >= blend) return depth;
    final progress = depth / blend;
    return blend * progress * progress * (2 - progress);
  }
}

class _DiscoverScrollPhysics extends BouncingScrollPhysics {
  const _DiscoverScrollPhysics({super.parent})
      : super(decelerationRate: ScrollDecelerationRate.fast);

  @override
  _DiscoverScrollPhysics applyTo(ScrollPhysics? ancestor) =>
      _DiscoverScrollPhysics(parent: buildParent(ancestor));

  // 已进入拖动状态时，慢滑松手也能产生一点惯性。
  @override
  double get minFlingVelocity => 40;

  @override
  double get minFlingDistance => 4;

  // 让传入两端弹簧的最大速度一致。
  @override
  double get maxFlingVelocity => BouncingScrollSimulation.maxSpringTransferVelocity;

  @override
  double applyPhysicsToUserOffset(ScrollMetrics position, double offset) {
    if (position.outOfRange) return super.applyPhysicsToUserOffset(position, offset);

    // 第一次越过边缘就减小拖动幅度，避免快速横滑时一下子拉开太多。
    final inBounds = offset.clamp(
      position.pixels - position.maxScrollExtent,
      position.pixels - position.minScrollExtent,
    );
    return inBounds + (offset - inBounds) * frictionFactor(0);
  }

  @override
  Simulation? createBallisticSimulation(ScrollMetrics position, double velocity) {
    final speed = velocity.clamp(-maxFlingVelocity, maxFlingVelocity);
    if (position.outOfRange) return super.createBallisticSimulation(position, speed);

    final tolerance = toleranceFor(position);
    if (speed.abs() < tolerance.velocity) return null;

    // 列表沿松手方向慢慢减速，滑过任一端时交给同一套弹簧收回。
    return BouncingScrollSimulation(
      spring: spring,
      position: position.pixels,
      velocity: speed,
      leadingExtent: position.minScrollExtent,
      trailingExtent: position.maxScrollExtent,
      tolerance: tolerance,
      constantDeceleration: 360,
    );
  }
}

/// 只有封面边框、标题和按钮的透明度依赖滚动深度。
class _DiscoverDepth extends InheritedWidget {
  const _DiscoverDepth({required this.value, required super.child});

  final double value;

  static double of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_DiscoverDepth>()!.value;

  @override
  bool updateShouldNotify(_DiscoverDepth oldWidget) => value != oldWidget.value;
}

/// 歌曲和歌单共用封面尺寸，收藏按钮只属于歌曲。
class _DiscoverCard extends StatelessWidget {
  const _DiscoverCard({
    required this.cover, required this.title, required this.onTap,
    required this.size, this.subtitle, this.overlay,
  });

  final String cover;
  final String title;
  final String? subtitle;
  final Widget? overlay;
  final VoidCallback onTap;
  final double size;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final caption = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodyMedium),
        if (subtitle case final subtitle?)
          Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
      ],
    );
    return SizedBox(
      width: size,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Stack(
              children: [
                RepaintBoundary(child: Cover(url: cover, size: size, radius: 12)),
                Positioned.fill(
                  child: Builder(builder: (context) {
                    final opacity = (_DiscoverDepth.of(context) * 3).clamp(0.0, 1.0);
                    if (opacity == 0) return const SizedBox.shrink();
                    return DecoratedBox(decoration: BoxDecoration(
                      border: Border.all(color: theme.colorScheme.surface.withValues(alpha: opacity)),
                      borderRadius: BorderRadius.circular(12),
                    ));
                  }),
                ),
                if (overlay case final overlay?)
                  Positioned(
                    right: 4, bottom: 4,
                    child: _DiscoverFade(
                      range: 0.25,
                      child: Material(
                        color: theme.colorScheme.surface,
                        shape: const CircleBorder(),
                        child: overlay,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            _DiscoverFade(range: 1, child: caption),
          ],
        ),
      ),
    );
  }
}

class _DiscoverFade extends StatelessWidget {
  const _DiscoverFade({required this.range, required this.child});

  final double range;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final progress = (1 - _DiscoverDepth.of(context) / range).clamp(0.0, 1.0);
    if (progress == 0) return const SizedBox.shrink();
    // 透明度在两端缓进缓出，过程中复用同一份文字或按钮。
    final opacity = Curves.easeInOut.transform(progress);
    return Opacity(opacity: opacity, child: child);
  }
}

/// 发现页的推荐歌单预览。
class _RecommendedPlaylistRow extends StatelessWidget {
  const _RecommendedPlaylistRow({
    required this.playlists,
    required this.library,
    required this.player,
    required this.desktop,
  });

  final List<Playlist> playlists;
  final MusicLibrary library;
  final Playback player;
  final bool desktop;

  @override
  Widget build(BuildContext context) => _DiscoverCarousel(
    storageKey: const PageStorageKey('recommended-playlists'),
    count: playlists.length,
    desktop: desktop,
    itemBuilder: (context, index, size) {
      final playlist = playlists[index];
      return _DiscoverCard(
        cover: playlist.cover,
        title: playlist.name,
        subtitle: playlist.creator.isNotEmpty ? playlist.creator : null,
        size: size,
        onTap: () => _openRecommendedPlaylist(context, playlist, library, player),
      );
    },
  );
}

void _openRecommendedPlaylist(BuildContext context, Playlist playlist, MusicLibrary library, Playback player) {
  openCatalogHit(context, CatalogHit(
    id: playlist.id,
    title: playlist.name,
    cover: playlist.cover,
    subtitle: playlist.creator,
    description: playlist.description,
    playlist: playlist,
  ), SearchType.playlist, library, player);
}

/// 通用的歌曲列表页：歌单、排行榜、搜索结果都能用它打开。
class SongListPage extends StatefulWidget {
  const SongListPage({
    super.key,
    required this.title,
    this.loader,
    required this.player,
    required this.library,
    this.subtitle,
    this.cover = '',
    this.description = '',
    this.playlist,
    this.reloadOnFavoriteChange = false,
    this.showFavoriteButton = true,
    this.loadMore,
    this.pageLoader,
    this.privateFm = false,
    this.headerBuilder,
    this.onOpenPlayer,
  }) : assert(loader != null || pageLoader != null),
       assert(pageLoader == null || (loader == null && loadMore == null));

  final String title;
  final String? subtitle;
  final String cover;
  final String description;
  final Playlist? playlist;
  final bool reloadOnFavoriteChange;
  final bool showFavoriteButton;
  final bool privateFm;
  final Future<List<Song>> Function()? loader;
  /// 返回追加后的完整列表，保留已经加载的歌曲和滚动位置。
  final Future<List<Song>> Function()? loadMore;
  final Future<CatalogSearchResult<List<Song>>> Function(int page)? pageLoader;
  /// 自带导航和播放入口的页头，与歌曲列表一起滚动。
  final Widget Function(BuildContext context, VoidCallback? playAll, bool playAllBusy)? headerBuilder;
  final VoidCallback? onOpenPlayer;
  final Playback player;
  final MusicLibrary library;

  @override
  State<SongListPage> createState() => _SongListPageState();
}

class _SongListPageState extends State<SongListPage> {
  List<Song> _songs = const [];
  bool _loading = true;
  String? _error;
  bool _startingPlayback = false;
  String? _pendingSongId;
  int _loadAttempt = 0;
  bool _loadingMore = false;
  bool _hasMore = true;
  bool _moreFailed = false;
  int _nextPage = 2;
  late final ScrollController? _paginationScroll = widget.loadMore == null && widget.pageLoader == null
      ? null
      : (ScrollController()..addListener(_prefetch));

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _paginationScroll?.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final attempt = ++_loadAttempt;
    setState(() {
      _loading = true;
      _error = null;
      _loadingMore = false;
      _hasMore = true;
      _moreFailed = false;
      _nextPage = 2;
    });
    try {
      final loadPage = widget.pageLoader;
      final first = loadPage == null ? null : await loadPage(1);
      final songs = first == null ? await widget.loader!() : _appendUniqueSongs(const [], first.hits);
      if (!mounted || attempt != _loadAttempt) return;
      setState(() {
        _songs = songs;
        _hasMore = first?.hasMore ?? widget.loadMore != null;
        _loading = false;
        if (songs.isEmpty) _error = '这个列表里还没有歌曲。';
      });
      _prefetchAfterLayout();
      unawaited(_completeSongCovers(songs, attempt));
    } on KugouFailure catch (error) {
      if (!mounted || attempt != _loadAttempt) return;
      setState(() {
        _loading = false;
        _error = error.message;
      });
    } on Object {
      if (!mounted || attempt != _loadAttempt) return;
      setState(() {
        _loading = false;
        _error = '加载失败，请稍后重试。';
      });
    }
  }

  Future<void> _completeSongCovers(List<Song> songs, int attempt) async {
    // 先展示歌曲；封面只更新到发起查询时的那一版列表。
    try {
      final completed = await widget.library.completeCovers(songs);
      if (mounted && attempt == _loadAttempt && identical(_songs, songs) &&
          !identical(completed, songs)) {
        setState(() => _songs = completed);
      }
    } on Exception {
      // 单独的封面请求失败时继续显示歌曲。
    }
  }

  void _prefetchAfterLayout() {
    if (_paginationScroll != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _prefetch();
      });
    }
  }

  void _prefetch() {
    final scroll = _paginationScroll;
    if (scroll == null || !scroll.hasClients || !scroll.position.hasContentDimensions ||
        scroll.position.extentAfter > 160 || _moreFailed) {
      return;
    }
    scheduleMicrotask(() {
      if (mounted) unawaited(_loadNextPage());
    });
  }

  Future<void> _loadNextPage() async {
    final load = widget.loadMore;
    final loadPage = widget.pageLoader;
    if ((load == null && loadPage == null) || _loading || _loadingMore || !_hasMore || _songs.isEmpty) return;
    final attempt = _loadAttempt;
    setState(() {
      _loadingMore = true;
      _moreFailed = false;
    });
    try {
      final page = loadPage == null ? null : await loadPage(_nextPage);
      final songs = page == null ? await load!() : _appendUniqueSongs(_songs, page.hits);
      if (!mounted || attempt != _loadAttempt) return;
      // 分页返回完整列表，旧条目可能仍用未补图的快照。
      final covers = {
        for (final song in _songs)
          if (song.coverUrl().isNotEmpty) song.id: song.albumImage,
      };
      final updated = [
        for (final song in songs)
          if (covers[song.id] case final cover? when song.coverUrl().isEmpty)
            song.withCover(cover)
          else
            song,
      ];
      setState(() {
        // 同一页重复返回时停止，避免滑到底后反复请求。
        _hasMore = (page?.hasMore ?? true) && updated.length > _songs.length;
        _nextPage++;
        _songs = updated;
        _loadingMore = false;
      });
      if (_hasMore) _prefetchAfterLayout();
      unawaited(_completeSongCovers(updated, attempt));
    } catch (_) {
      if (!mounted || attempt != _loadAttempt) return;
      setState(() {
        _loadingMore = false;
        _moreFailed = true;
      });
    }
  }

  List<Song> _appendUniqueSongs(List<Song> existing, List<Song> incoming) {
    final ids = existing.map((song) => song.id).toSet();
    return [...existing, for (final song in incoming) if (ids.add(song.id)) song];
  }

  Future<void> _play(Song song) async {
    if (_startingPlayback) return;
    final playback = widget.player.trackPlayback;
    if (playback.trackId == song.id && playback.playing) {
      await _openNowPlaying();
      return;
    }
    // 队列里已经暂停的歌曲从原进度继续，首次点播才重新取地址。
    final resume = widget.player.canResumeTrack(song.id);
    await _startPlayback(
      resume ? _resumeCurrent : () => widget.library.playSong(song, widget.player),
      songId: song.id,
    );
  }

  Future<PlaybackOutcome> _resumeCurrent() async {
    await widget.player.play();
    final message = widget.player.message.value;
    return message == null ? const PlaybackOutcome.started() : PlaybackOutcome.failed(message);
  }

  Future<void> _playAll() => _startPlayback(
    () => widget.library.playAll(_songs, widget.player, privateFm: widget.privateFm),
  );

  Future<void> _startPlayback(
    Future<PlaybackOutcome> Function() start, {
    String? songId,
  }) async {
    if (_startingPlayback) return;
    setState(() {
      _startingPlayback = true;
      _pendingSongId = songId;
    });
    PlaybackOutcome outcome;
    try {
      outcome = await start();
    } on Exception {
      outcome = const PlaybackOutcome.failed('无法完成播放操作，请重试。');
    } finally {
      if (mounted) {
        setState(() {
          _startingPlayback = false;
          _pendingSongId = null;
        });
      }
    }
    if (!mounted || ModalRoute.of(context)?.isCurrent == false) return;
    final notice = outcome.notice;
    if (notice != null) showMusicNotice(context, notice);
    if (outcome.ok) await _openNowPlaying();
  }

  Future<void> _openNowPlaying() async {
    if (ModalRoute.of(context)?.isCurrent == false) return;
    if (widget.onOpenPlayer case final open?) {
      open();
      return;
    }
    await showNowPlaying(context, player: widget.player, library: widget.library);
  }

  @override
  Widget build(BuildContext context) {
    final body = SafeArea(
      top: false,
      child: StreamBuilder<TrackPlayback>(
        stream: widget.player.trackPlaybackStream,
        initialData: widget.player.trackPlayback,
        builder: (context, snapshot) => _buildBody(snapshot.requireData),
      ),
    );
    if (widget.headerBuilder != null) {
      return DesktopPageScope.active(context)
          ? Material(type: MaterialType.transparency, child: body)
          : AppBackground(child: Scaffold(backgroundColor: Colors.transparent, body: body));
    }
    return WorkspacePage(
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis),
          if (widget.subtitle case final subtitle?)
            Text(subtitle, style: Theme.of(context).textTheme.labelSmall),
        ],
      ),
      actions: [
        if (widget.playlist case final playlist? when canSharePlaylist(playlist))
          IconButton(
            tooltip: '分享歌单',
            icon: const Icon(Icons.share_outlined),
            onPressed: () => sharePlaylist(context, playlist),
          ),
        if (_songs.isNotEmpty)
          IconButton(
            tooltip: '播放全部',
            icon: const Icon(Icons.play_circle_outline_rounded),
            onPressed: _startingPlayback ? null : _playAll,
          ),
        const SizedBox(width: 4),
      ],
      body: body,
    );
  }

  Widget _buildBody(TrackPlayback playback) {
    final status = _loading
        ? const Center(child: CircularProgressIndicator())
        : switch (_error) {
            final error? => _ErrorView(message: error, onRetry: _load),
            _ => null,
          };
    final headerBuilder = widget.headerBuilder;
    if (headerBuilder == null && status != null) return status;
    final hasHeader = headerBuilder != null || widget.cover.isNotEmpty || widget.description.isNotEmpty;
    final playAll = status == null && _songs.isNotEmpty ? _playAll : null;
    final insets = DesktopPageScope.bodyPadding(context, const EdgeInsets.fromLTRB(10, 4, 10, 16));
    final hasFooter = status == null && (_loadingMore || _moreFailed);
    // 收藏列表里的红心变化会改变列表内容，需要重新读取。
    final reloadFavorites = widget.reloadOnFavoriteChange || widget.playlist?.isDefault == true;
    return Scrollbar(
      controller: _paginationScroll,
      child: ListView.builder(
        controller: _paginationScroll,
        padding: headerBuilder == null ? insets : EdgeInsets.only(bottom: insets.bottom),
        itemCount: (status == null ? _songs.length : 1) +
            (hasHeader ? 1 : 0) + (hasFooter ? 1 : 0),
        itemBuilder: (context, index) {
          if (hasHeader && index == 0) {
            if (headerBuilder != null) return headerBuilder(context, playAll, _startingPlayback);
            return Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                children: [
                  if (widget.cover.isNotEmpty)
                    Cover(url: widget.cover.replaceAll('{size}', '400'), size: 130),
                  if (widget.description.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(widget.description, textAlign: TextAlign.center),
                    ),
                ],
              ),
            );
          }
          if (status != null) {
            return Padding(padding: const EdgeInsets.symmetric(vertical: 32), child: status);
          }
          final slot = index - (hasHeader ? 1 : 0);
          if (slot == _songs.length) {
            return Padding(
              padding: const EdgeInsets.all(16),
              child: Center(child: _moreFailed
                  ? TextButton(onPressed: _loadNextPage, child: const Text('重试加载更多'))
                  : const CircularProgressIndicator(semanticsLabel: '正在加载更多歌曲')),
            );
          }
          final song = _songs[slot];
          final selected = song.id == playback.trackId;
          final playing = selected && playback.playing;
          void details() => openCatalogHit(
            context, CatalogHit.track(song), SearchType.song, widget.library, widget.player,
          );
          final tile = SongTile(
            song: song,
            index: slot + 1,
            selected: selected,
            loading: _pendingSongId == song.id,
            onTap: () => _play(song),
            onPlay: () => _play(song),
            onPause: playing ? () => runPlayerAction(context, () => widget.player.pauseTrack(song.id)) : null,
            onLongPress: details,
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (widget.showFavoriteButton)
                  FavoriteButton(
                    song: song, library: widget.library, compact: true,
                    onChanged: reloadFavorites ? _load : null,
                  ),
                SongMenu(
                  song: song, library: widget.library, player: widget.player, onDetails: details,
                  playlist: widget.playlist,
                  onChanged: widget.playlist != null || reloadFavorites ? _load : null,
                ),
              ],
            ),
          );
          return headerBuilder == null
              ? tile
              : Padding(padding: insets.copyWith(top: 0, bottom: 0), child: tile);
        },
      ),
    );
  }
}

/// 排行榜移到桌面侧栏，从入口打开时再单独加载。
class RankingsPage extends StatefulWidget {
  const RankingsPage({super.key, required this.library, required this.player});

  final MusicLibrary library;
  final Playback player;

  @override
  State<RankingsPage> createState() => _RankingsPageState();
}

class _RankingsPageState extends State<RankingsPage> {
  late Future<List<Playlist>> _ranks = widget.library.ranks();

  @override
  Widget build(BuildContext context) => WorkspacePage(
    title: const Text('排行榜'),
    body: FutureBuilder<List<Playlist>>(
      future: _ranks,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return _ErrorView(
            message: '加载排行榜失败，请稍后重试。',
            onRetry: () => setState(() => _ranks = widget.library.ranks()),
          );
        }
        final ranks = snapshot.data ?? const <Playlist>[];
        if (ranks.isEmpty) return const Center(child: Text('暂时拿不到排行榜。'));
        return GridView.builder(
          padding: DesktopPageScope.bodyPadding(context, const EdgeInsets.all(20)),
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 166,
            childAspectRatio: 0.73,
            crossAxisSpacing: 10,
            mainAxisSpacing: 10,
          ),
          itemCount: ranks.length,
          itemBuilder: (context, index) {
            final rank = ranks[index];
            return PlaylistCard(
              playlist: rank,
              onTap: () => Navigator.of(context).push<void>(MaterialPageRoute(
                builder: (_) => SongListPage(
                  title: rank.name,
                  loader: () => widget.library.rankSongs(rank.globalCollectionId),
                  player: widget.player,
                  library: widget.library,
                ),
              )),
            );
          },
        );
      },
    ),
  );
}

class RecommendedPlaylistsPage extends StatefulWidget {
  const RecommendedPlaylistsPage({super.key, required this.library, required this.player});
  final MusicLibrary library;
  final Playback player;

  @override
  State<RecommendedPlaylistsPage> createState() => _RecommendedPlaylistsPageState();
}

class _RecommendedPlaylistsPageState extends State<RecommendedPlaylistsPage> {
  int _category = 0;
  late Future<List<Playlist>> _lists = widget.library.recommendedPlaylists();

  void _select(int category) => setState(() {
    _category = category;
    _lists = widget.library.recommendedPlaylists(category: category);
  });

  @override
  Widget build(BuildContext context) => WorkspacePage(
    title: const Text('推荐歌单'),
    body: SafeArea(
      child: Column(
        children: [
          Wrap(
            spacing: 8,
            children: [
              for (final (category, label) in [(0, '推荐'), (11292, 'Hi-Res')])
                ChoiceChip(
                  label: Text(label), selected: _category == category,
                  onSelected: (selected) { if (selected) _select(category); },
                ),
            ],
          ),
          const SizedBox(height: 12),
          Expanded(
            child: FutureBuilder<List<Playlist>>(
              future: _lists,
              builder: (context, snapshot) {
                if (snapshot.connectionState != ConnectionState.done) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (snapshot.hasError) {
                  return const Center(child: Text('推荐加载失败。'));
                }
                final items = snapshot.data ?? const [];
                if (items.isEmpty) return const Center(child: Text('暂时没有推荐歌单。'));
                return ListView.builder(
                  key: ValueKey(_category),
                  padding: DesktopPageScope.bodyPadding(context, const EdgeInsets.fromLTRB(16, 0, 16, 20)),
                  itemCount: items.length,
                  itemBuilder: (context, index) {
                    final playlist = items[index];
                    return PlaylistListTile(
                      playlist: playlist,
                      subtitle: playlist.creator.isEmpty ? null : playlist.creator,
                      onTap: () => _openRecommendedPlaylist(context, playlist, widget.library, widget.player),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    ),
  );
}

class _Hint extends StatelessWidget {
  const _Hint(this.message);

  final String message;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 24),
    child: Text(
      message,
      textAlign: TextAlign.center,
      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    ),
  );
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.cloud_off_rounded,
            size: 44,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          const SizedBox(height: 12),
          Text(message, textAlign: TextAlign.center),
          const SizedBox(height: 16),
          FilledButton.tonal(onPressed: onRetry, child: const Text('重试')),
        ],
      ),
    ),
  );
}

/// 供外部复用：把「库」暴露给需要按音质取地址的地方。
typedef SongUrlResolver = Future<SongUrl?> Function(Song song);

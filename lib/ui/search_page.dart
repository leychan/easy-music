import 'dart:async';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:material_ui/material_ui.dart';

import '../account/kugou/kugou_auth.dart';
import '../music/catalog.dart';
import '../music/music_library.dart';
import '../music/song.dart';
import '../player/playback.dart';
import 'cover.dart';
import 'favorite_button.dart';
import 'catalog_pages.dart';
import 'music_toast.dart';
import 'playlist_actions.dart';
import 'player_controls.dart' show runPlayerAction;
import 'song_tile.dart';
import 'workspace_page.dart';

typedef DesktopSearchRequest = ({String keyword, int revision});

const _overviewLimit = 3;
const _songOverviewLimit = 5;

typedef _ResultPage = ({
  Map<SearchType, List<CatalogHit>> hits,
  bool hasMore,
  bool fallback,
  String? warning,
});

/// 搜索页：输入关键字、看联想词、出结果列表。
///
/// 酷狗的搜索接口对未登录用户也开放，所以这里不强制登录；只是未登录时
/// 排在前面的 VIP 歌曲大多拿不到播放地址，界面上会标注出来。
class SearchPage extends StatefulWidget {
  const SearchPage({
    super.key,
    required this.library,
    required this.player,
    this.desktopSearch,
  });

  final MusicLibrary library;
  final Playback player;
  final ValueListenable<DesktopSearchRequest?>? desktopSearch;

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  final _input = TextEditingController();
  final _focus = FocusNode();
  final _resultsScroll = ScrollController(keepScrollOffset: false);

  /// 已经提交的关键字。与输入框内容分开，避免边打字边请求。
  String _keyword = '';
  List<String> _suggestions = const [];
  final _resultGroups = <MapEntry<SearchType, List<CatalogHit>>>[];
  final _seenHits = <(SearchType, String)>{};
  SearchType? _type;
  int _page = 1;
  bool _hasMore = false;
  bool _overviewFallback = false;
  int _searchAttempt = 0;
  bool _searching = false;
  bool _loadingMore = false;
  bool _playingAll = false;
  String? _error;
  String? _moreError;

  /// 联想词请求的序号，用于丢弃过期响应。
  int _suggestAttempt = 0;
  Timer? _suggestDebounce;

  @override
  void initState() {
    super.initState();
    _input.addListener(_onInputChanged);
    _resultsScroll.addListener(_prefetch);
    widget.desktopSearch?.addListener(_readDesktopSearch);
    if (widget.desktopSearch?.value != null) {
      // 从其他页面提交时，这个页面会在下一帧挂载。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _searchAttempt == 0) _readDesktopSearch();
      });
    }
  }

  void _readDesktopSearch() {
    if (widget.desktopSearch?.value case final request?) _search(request.keyword);
  }

  @override
  void dispose() {
    _suggestDebounce?.cancel();
    widget.desktopSearch?.removeListener(_readDesktopSearch);
    _resultsScroll.dispose();
    _input.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// 输入停顿 250ms 才发联想请求：酷狗这个接口对高频调用很敏感。
  void _onInputChanged() {
    final text = _input.text.trim();
    _suggestDebounce?.cancel();
    if (text.isEmpty) {
      setState(() => _suggestions = const []);
      return;
    }
    _suggestDebounce = Timer(const Duration(milliseconds: 250), () async {
      final attempt = ++_suggestAttempt;
      try {
        final tips = await widget.library.suggest(text);
        if (!mounted || attempt != _suggestAttempt) return;
        setState(() => _suggestions = tips.take(8).toList());
      } on Object {
        // 联想词失败不该打扰用户，静默忽略。
      }
    });
  }

  Future<void> _search(String keyword) async {
    final trimmed = keyword.trim();
    if (trimmed.isEmpty) return;
    final attempt = ++_searchAttempt;
    final type = _type;
    ++_suggestAttempt;
    _suggestDebounce?.cancel();
    _focus.unfocus();
    setState(() {
      _keyword = trimmed;
      _searching = true;
      _loadingMore = false;
      _resultGroups.clear();
      _seenHits.clear();
      _page = 1;
      _hasMore = false;
      _error = _moreError = null;
      _suggestions = const [];
    });
    if (_resultsScroll.hasClients) _resultsScroll.jumpTo(0);
    try {
      final result = await _loadResults(trimmed, type, 1, null);
      if (!mounted || attempt != _searchAttempt) return;
      setState(() {
        _appendResults(result.hits);
        _hasMore = result.hasMore;
        _overviewFallback = result.fallback;
        _searching = false;
        _error = result.warning;
        if (_resultGroups.isEmpty && !_hasMore && _error == null) {
          _error = '没有找到与「$trimmed」相关的${type?.label ?? '结果'}。';
        }
      });
      _prefetchAfterLayout();
    } on Object catch (error) {
      if (!mounted || attempt != _searchAttempt) return;
      setState(() {
        _searching = false;
        _error = error is KugouFailure ? error.message : '搜索失败，请稍后重试。';
      });
    }
  }

  void _prefetchAfterLayout() {
    if (!_hasMore) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _prefetch();
    });
  }

  void _prefetch() {
    if (!_hasMore || _loadingMore || _moreError != null || !_resultsScroll.hasClients) return;
    final position = _resultsScroll.position;
    if (!position.hasContentDimensions || position.extentAfter > 120) return;
    // 列表还不到一屏时也自动补页，在滚动通知结束后更新界面。
    scheduleMicrotask(_loadNextPage);
  }

  Future<void> _loadNextPage() async {
    if (!mounted || _searching || _loadingMore || !_hasMore) return;
    final attempt = _searchAttempt;
    final page = _page + 1;
    setState(() {
      _loadingMore = true;
      _moreError = null;
    });
    try {
      final result = await _loadResults(_keyword, _type, page, _overviewFallback);
      if (!mounted || attempt != _searchAttempt) return;
      setState(() {
        _loadingMore = false;
        if (_appendResults(result.hits)) {
          _page = page;
          _hasMore = result.hasMore;
        } else if (result.warning != null) {
          _moreError = result.warning;
        } else {
          // 接口可能高估总数或重复返回同一页，避免自动请求一直循环。
          _hasMore = false;
          if (_resultGroups.isEmpty) _error = '没有找到与「$_keyword」相关的结果。';
        }
      });
      if (_moreError == null) _prefetchAfterLayout();
    } on Object catch (error) {
      if (!mounted || attempt != _searchAttempt) return;
      setState(() {
        _loadingMore = false;
        _moreError = error is KugouFailure ? error.message : '加载更多搜索结果失败，请稍后重试。';
      });
    }
  }

  bool _appendResults(Map<SearchType, List<CatalogHit>> results) {
    var appended = false;
    for (final MapEntry(key: type, value: hits) in results.entries) {
      final newHits = hits.where((hit) => _seenHits.add((type, hit.id))).toList();
      if (newHits.isEmpty) continue;
      if (_type != null && _resultGroups.isNotEmpty) {
        _resultGroups.single.value.addAll(newHits);
      } else {
        // 综合搜索把新一批的分类分组接在末尾，保留前面各组的位置。
        _resultGroups.add(MapEntry(type, newHits));
      }
      appended = true;
    }
    return appended;
  }

  Future<_ResultPage> _loadResults(String keyword, SearchType? type, int page, bool? fallback) async {
    if (type != null) {
      final result = await widget.library.searchCatalogPage(keyword, type, page: page);
      return (
        hits: {if (result.hits.isNotEmpty) type: result.hits},
        hasMore: result.hasMore,
        fallback: false,
        warning: null,
      );
    }
    if (fallback != true) {
      try {
        final result = await widget.library.searchComplex(keyword, page: page);
        return (hits: result.hits, hasMore: result.hasMore, fallback: false, warning: null);
      } on KugouFailure {
        // 访客可能无法使用综合接口。同一次搜索的后续页面沿用首屏的数据来源。
        if (fallback == false) rethrow;
      }
    }
    final batches = await Future.wait([
      for (final type in SearchType.values) _searchCategory(keyword, type, page),
    ]);
    final failures = batches.where((batch) => batch.error != null).toList();
    if (failures.length == SearchType.values.length) {
      throw const KugouFailure('搜索失败，请稍后重试。');
    }
    final labels = failures.map((batch) => batch.type.label).join('、');
    return (
      hits: {
        for (final (:type, :result, error: _) in batches)
          if (result.hits.isNotEmpty) type: result.hits,
      },
      hasMore: batches.any((batch) => batch.result.hasMore),
      fallback: true,
      warning: failures.isEmpty ? null : '$labels搜索失败，请稍后重试。',
    );
  }

  Future<({SearchType type, CatalogSearchResult<List<CatalogHit>> result, String? error})> _searchCategory(
    String keyword,
    SearchType type,
    int page,
  ) async {
    try {
      final result = await widget.library.searchCatalogPage(keyword, type, page: page);
      return (type: type, result: result, error: null);
    } on Object catch (error) {
      return (
        type: type,
        result: (hits: const <CatalogHit>[], hasMore: false),
        error: error is KugouFailure ? error.message : '搜索失败，请稍后重试。',
      );
    }
  }

  void _selectType(SearchType? type) {
    if (type == _type) return;
    setState(() => _type = type);
    if (_keyword.isNotEmpty) _search(_keyword);
  }

  Future<void> _play(Song song) async {
    final outcome = await widget.library.playSong(song, widget.player, resumeCurrent: true);
    if (!mounted) return;
    final notice = outcome.notice;
    if (notice != null) showMusicNotice(context, notice);
  }

  Future<void> _playAll(List<Song> songs) async {
    if (_playingAll) return;
    setState(() => _playingAll = true);
    try {
      final outcome = await widget.library.playAll(songs, widget.player);
      if (outcome.notice case final notice? when mounted) {
        showMusicNotice(context, notice);
      }
    } finally {
      if (mounted) setState(() => _playingAll = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final behavior = ScrollConfiguration.of(context);
    return Column(
      children: [
        if (widget.desktopSearch == null) Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
          child: TextField(
            controller: _input,
            focusNode: _focus,
            textInputAction: TextInputAction.search,
            onSubmitted: _search,
            decoration: InputDecoration(
              hintText: _type == null ? '搜索歌曲、歌手、专辑' : '搜索${_type!.label}',
              prefixIcon: const Icon(Icons.search_rounded),
              suffixIcon: _input.text.isEmpty
                  ? null
                  : IconButton(
                      tooltip: '清空',
                      icon: const Icon(Icons.close_rounded),
                      onPressed: () => _input.clear(),
                    ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
              ),
              isDense: true,
            ),
          ),
        ),
        Padding(
          padding: DesktopPageScope.bodyPadding(context, const EdgeInsets.symmetric(horizontal: 20)),
          child: Align(
            alignment: Alignment.centerLeft,
            child: ScrollConfiguration(
              behavior: behavior.copyWith(dragDevices: {...behavior.dragDevices, PointerDeviceKind.mouse}),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  spacing: 8,
                  children: [
                    for (final type in [null, ...SearchType.values])
                      ChoiceChip(
                        label: Text(type?.label ?? '综合'),
                        selected: _type == type,
                        onSelected: (selected) {
                          if (selected) _selectType(type);
                        },
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
        if (_suggestions.isNotEmpty && _keyword != _input.text.trim())
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  for (final tip in _suggestions)
                    ActionChip(
                      label: Text(tip),
                      onPressed: () {
                        _input.text = tip;
                        _search(tip);
                      },
                    ),
                ],
              ),
            ),
          ),
        if (_searching)
          const Padding(
            padding: EdgeInsets.all(24),
            child: CircularProgressIndicator(),
          )
        else if (_error case final error? when _resultGroups.isEmpty && !_hasMore)
          Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              error,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          )
        else if (_resultGroups.isEmpty && !_hasMore)
          Expanded(child: _EmptySearchHint(onPick: _search))
        else
          Expanded(child: StreamBuilder<TrackPlayback>(
            stream: widget.player.trackPlaybackStream,
            initialData: widget.player.trackPlayback,
            builder: (context, snapshot) => _buildResults(context, snapshot.requireData),
          )),
      ],
    );
  }

  Widget _buildResults(BuildContext context, TrackPlayback playback) {
    final overview = _type == null;
    // 歌词搜索可能命中同一首歌，按首次出现的顺序入队。
    final seen = <String>{};
    final songs = [
      for (final group in _resultGroups)
        for (final hit in group.value)
          if (hit.song case final song? when seen.add(song.id)) song,
    ];
    var playGroup = _resultGroups.indexWhere((group) => group.key == SearchType.song);
    if (playGroup == -1 && songs.isNotEmpty) {
      playGroup = _resultGroups.indexWhere((group) => group.value.any((hit) => hit.song != null));
    }
    final sections = <Widget>[
      if (_error case final error?)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
            child: Text(error, style: Theme.of(context).textTheme.bodySmall),
          ),
        ),
    ];
    for (final (index, MapEntry(key: type, value: hits)) in _resultGroups.indexed) {
      final limit = type == SearchType.song ? _songOverviewLimit : _overviewLimit;
      final truncated = overview && hits.length > limit;
      final showPlayAll = index == playGroup && songs.isNotEmpty;
      final useArrowHeader = overview && (type == SearchType.playlist || type == SearchType.video);
      sections.addAll([
        if (type == SearchType.song || showPlayAll || useArrowHeader)
          SliverToBoxAdapter(
            child: Padding(
              padding: DesktopPageScope.bodyPadding(context, const EdgeInsets.symmetric(horizontal: 10)),
              child: MusicSectionHeader(
                title: type.label,
                onPlayAll: showPlayAll ? () => _playAll(songs) : null,
                playAllBusy: _playingAll,
                onViewAll: overview && (type == SearchType.song || truncated) ? () => _selectType(type) : null,
                viewAllTooltip: '查看全部${type.label}',
              ),
            ),
          )
        else if (overview)
          SliverToBoxAdapter(
            child: ListTile(
              title: Text(type.label, style: Theme.of(context).textTheme.titleMedium),
              trailing: truncated
                  ? TextButton(
                      onPressed: () => _selectType(type),
                      child: Text('更多${type.label}'),
                    )
                  : null,
            ),
          ),
        SliverList.builder(
          itemCount: truncated ? limit : hits.length,
          itemBuilder: (context, index) => _resultTile(context, type, hits[index], index, playback),
        ),
      ]);
    }
    if (_loadingMore || _moreError != null) {
      sections.add(SliverToBoxAdapter(child: _buildLoadMoreStatus()));
    }
    return Scrollbar(
      controller: _resultsScroll,
      child: CustomScrollView(
        controller: _resultsScroll,
        slivers: [
          SliverPadding(
            padding: pageScrollPadding(
              context,
              DesktopPageScope.bodyPadding(context, const EdgeInsets.fromLTRB(10, 4, 10, 16)),
            ),
            sliver: SliverMainAxisGroup(slivers: sections),
          ),
        ],
      ),
    );
  }

  Widget _buildLoadMoreStatus() => Padding(
    padding: const EdgeInsets.symmetric(vertical: 12),
    child: Center(
      child: switch (_moreError) {
        final error? => Column(
          children: [
            Text(error, textAlign: TextAlign.center),
            TextButton(onPressed: _loadNextPage, child: const Text('重试加载更多')),
          ],
        ),
        null => const SizedBox.square(
          dimension: 24,
          child: CircularProgressIndicator(strokeWidth: 2, semanticsLabel: '正在加载更多结果'),
        ),
      },
    ),
  );

  Widget _resultTile(BuildContext context, SearchType type, CatalogHit hit, int index, TrackPlayback playback) {
    final song = hit.song;
    void open() => openCatalogHit(
      context, hit, type, widget.library, widget.player,
    );
    if (song == null || type == SearchType.lyric) {
      return ListTile(
        leading: Cover(url: hit.cover.replaceAll('{size}', '150'), size: 44),
        title: Text(hit.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(
          hit.description.isNotEmpty && type == SearchType.lyric
              ? hit.description : hit.subtitle,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: const Icon(Icons.chevron_right_rounded),
        onTap: open,
      );
    }
    final selected = song.id == playback.trackId;
    return SongTile(
      song: song,
      index: index + 1,
      selected: selected,
      onPlay: () => _play(song),
      onPause: selected && playback.playing
          ? () => runPlayerAction(context, () => widget.player.pauseTrack(song.id))
          : null,
      onLongPress: open,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          FavoriteButton(song: song, library: widget.library, compact: true),
          SongMenu(song: song, library: widget.library, player: widget.player, onDetails: open),
        ],
      ),
    );
  }
}

class _EmptySearchHint extends StatelessWidget {
  const _EmptySearchHint({required this.onPick});

  final ValueChanged<String> onPick;

  static const _hot = ['周杰伦', '晴天', '夜的第七章', '陈奕迅', '五月天'];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: SingleChildScrollView(
        padding: pageScrollPadding(context, const EdgeInsets.all(24)),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.travel_explore_rounded,
              size: 48,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(height: 12),
            Text('搜索酷狗曲库', style: theme.textTheme.titleLarge),
            const SizedBox(height: 6),
            Text(
              '试试这些',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              alignment: WrapAlignment.center,
              children: [
                for (final word in _hot)
                  OutlinedButton(
                    onPressed: () => onPick(word),
                    child: Text(word),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 排行榜使用的歌单卡片。
class PlaylistCard extends StatelessWidget {
  const PlaylistCard({
    super.key,
    required this.playlist,
    required this.onTap,
  });

  final Playlist playlist;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AspectRatio(
              aspectRatio: 1,
              child: Cover(
                url: playlist.cover, radius: 12, icon: Icons.queue_music_rounded,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              playlist.name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium,
            ),
            if (playlist.songCount > 0)
              Text(
                '${playlist.songCount} 首',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

import 'dart:async';

import 'package:flutter/foundation.dart' show ValueListenable;
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
import 'song_tile.dart';
import 'workspace_page.dart';

typedef DesktopSearchRequest = ({String keyword, int revision});

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

  /// 已经提交的关键字。与输入框内容分开，避免边打字边请求。
  String _keyword = '';
  List<String> _suggestions = const [];
  List<CatalogHit> _results = const [];
  SearchType _type = SearchType.song;
  int _searchAttempt = 0;
  bool _searching = false;
  String? _error;

  /// 联想词请求的序号，用于丢弃过期响应。
  int _suggestAttempt = 0;
  Timer? _suggestDebounce;

  @override
  void initState() {
    super.initState();
    _input.addListener(_onInputChanged);
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
      _results = const [];
      _error = null;
      _suggestions = const [];
    });
    try {
      final results = await widget.library.searchCatalog(trimmed, type);
      if (!mounted || attempt != _searchAttempt) return;
      setState(() {
        _results = results;
        _searching = false;
        if (results.isEmpty) _error = '没有找到与「$trimmed」相关的${type.label}。';
      });
    } on KugouFailure catch (error) {
      if (!mounted || attempt != _searchAttempt) return;
      setState(() {
        _searching = false;
        _error = error.message;
      });
    } on Object {
      if (!mounted || attempt != _searchAttempt) return;
      setState(() {
        _searching = false;
        _error = '搜索失败，请稍后重试。';
      });
    }
  }

  Future<void> _play(Song song) async {
    final outcome = await widget.library.playSong(song, widget.player);
    if (!mounted) return;
    final notice = outcome.notice;
    if (notice != null) showMusicNotice(context, notice);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
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
              hintText: '搜索${_type.label}',
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
            child: Wrap(
              spacing: 8,
              children: [
                for (final type in SearchType.values)
                  ChoiceChip(
                    label: Text(type.label),
                    selected: _type == type,
                    onSelected: (selected) {
                      if (!selected || type == _type) return;
                      setState(() => _type = type);
                      if (_keyword.isNotEmpty) _search(_keyword);
                    },
                  ),
              ],
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
        else if (_error case final error? when _results.isEmpty)
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
        else if (_results.isEmpty)
          Expanded(child: _EmptySearchHint(onPick: _search))
        else
          Expanded(
            child: Scrollbar(
              child: ListView.builder(
                padding: pageScrollPadding(
                  context,
                  DesktopPageScope.bodyPadding(context, const EdgeInsets.fromLTRB(10, 4, 10, 16)),
                ),
                itemCount: _results.length,
                itemBuilder: (context, index) {
                  final hit = _results[index];
                  final song = hit.song;
                  void open() => openCatalogHit(
                    context, hit, _type, widget.library, widget.player,
                  );
                  if (song == null || _type == SearchType.lyric) {
                    return ListTile(
                      leading: Cover(url: hit.cover.replaceAll('{size}', '150'), size: 44),
                      title: Text(hit.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text(
                        hit.description.isNotEmpty && _type == SearchType.lyric
                            ? hit.description : hit.subtitle,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: open,
                    );
                  }
                  return SongTile(
                    song: song,
                    index: index + 1,
                    onTap: () => _play(song),
                    onPlay: () => _play(song),
                    onLongPress: open,
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        FavoriteButton(song: song, library: widget.library, compact: true),
                        SongMenu(song: song, library: widget.library, onDetails: open),
                      ],
                    ),
                  );
                },
              ),
            ),
          ),
      ],
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

/// 歌单卡片，供推荐页与「我的」页复用。
class PlaylistCard extends StatelessWidget {
  const PlaylistCard({
    super.key,
    required this.playlist,
    required this.onTap,
    this.onEdit,
  });

  final Playlist playlist;
  final VoidCallback onTap;
  final VoidCallback? onEdit;

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
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Cover(
                    url: playlist.cover, radius: 12, icon: Icons.queue_music_rounded,
                  ),
                  if (onEdit case final edit?)
                    Positioned(
                      right: 4, top: 4,
                      child: IconButton.filledTonal(
                        onPressed: edit,
                        tooltip: '编辑歌单',
                        icon: const Icon(Icons.edit_outlined, size: 18),
                      ),
                    ),
                ],
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

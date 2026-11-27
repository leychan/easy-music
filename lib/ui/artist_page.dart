import 'dart:async';
import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/services.dart' show SystemUiOverlayStyle;
import 'package:material_ui/material_ui.dart';

import '../account/kugou/kugou_auth.dart';
import '../music/catalog.dart';
import '../music/music_library.dart';
import '../music/song.dart';
import '../player/playback.dart';
import 'discover_page.dart';
import 'workspace_page.dart';

Future<void> openArtistFromPlayer(
  BuildContext context, {
  required List<String> artists,
  required MusicLibrary library,
  required Playback player,
}) async {
  if (artists.isEmpty) return;
  final name = artists.length == 1
      ? artists.single
      : await showModalBottomSheet<String>(
          context: context,
          showDragHandle: true,
          builder: (sheetContext) => SafeArea(
            child: ListView(
              shrinkWrap: true,
              children: [
                const ListTile(title: Text('选择歌手')),
                for (final artist in artists)
                  ListTile(
                    title: Text(artist),
                    onTap: () => Navigator.of(sheetContext).pop(artist),
                  ),
              ],
            ),
          ),
        );
  if (name == null || !context.mounted) return;
  await Navigator.of(context).push<void>(
    MaterialPageRoute(
      builder: (_) => ArtistPage(
        name: name,
        library: library,
        player: player,
        returnToPlayer: true,
      ),
    ),
  );
}

class ArtistPage extends StatefulWidget {
  const ArtistPage({
    super.key,
    required this.name,
    required this.library,
    required this.player,
    this.artist,
    this.returnToPlayer = false,
  });

  final String name;
  final MusicLibrary library;
  final Playback player;
  final CatalogHit? artist;
  final bool returnToPlayer;

  @override
  State<ArtistPage> createState() => _ArtistPageState();
}

class _ArtistPageState extends State<ArtistPage> {
  CatalogHit? _artist;
  Future<List<String>>? _portraits;

  @override
  void initState() {
    super.initState();
    if (widget.artist case final artist?) _setArtist(artist);
  }

  void _setArtist(CatalogHit artist) {
    _artist = artist;
    _portraits = widget.library.artistImages(artist.id);
  }

  Future<CatalogSearchResult<List<Song>>> _loadSongs(int page) async {
    var artist = _artist;
    if (artist == null) {
      // 旧的播放队列只保存了歌手名，按名字精确匹配，避免打开相似名称的歌手。
      final result = await widget.library.searchCatalogPage(
        widget.name,
        SearchType.artist,
        page: 1,
      );
      final name = widget.name.toLowerCase();
      artist = result.hits
          .where((hit) => hit.title.toLowerCase() == name)
          .firstOrNull;
      if (artist == null) throw const KugouFailure('未找到这位歌手的资料。');
      if (!mounted) return (hits: const <Song>[], hasMore: false);
      final matched = artist;
      setState(() => _setArtist(matched));
    }
    return widget.library.artistTracksPage(artist.id, page: page);
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final systemStyle =
        (dark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark)
            .copyWith(
              statusBarColor: Colors.transparent,
              systemStatusBarContrastEnforced: false,
              systemNavigationBarColor: Colors.transparent,
              systemNavigationBarIconBrightness: dark
                  ? Brightness.light
                  : Brightness.dark,
              systemNavigationBarContrastEnforced: false,
            );
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: systemStyle,
      child: SongListPage(
        title: widget.name,
        pageLoader: _loadSongs,
        player: widget.player,
        library: widget.library,
        // 从播放页进来时，点播后回到原页面，避免一层层堆叠播放页。
        onOpenPlayer: widget.returnToPlayer
            ? () => Navigator.of(context).pop()
            : null,
        headerBuilder: (context, playAll, playAllBusy) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            FutureBuilder<List<String>>(
              future: _portraits,
              builder: (context, snapshot) => _ArtistPortrait(
                name: _artist?.title ?? widget.name,
                photos: snapshot.data ?? const [],
                avatar: resolveCoverUrl(_artist?.cover ?? '', 800),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 10, 12, 0),
              child: MusicSectionHeader(
                title: '歌曲',
                onPlayAll: playAll,
                playAllBusy: playAllBusy,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ArtistPortrait extends StatelessWidget {
  const _ArtistPortrait({
    required this.name,
    required this.photos,
    required this.avatar,
  });

  final String name;
  final List<String> photos;
  final String avatar;
  static const _photoSystemStyle = SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
    statusBarBrightness: Brightness.dark,
    systemStatusBarContrastEnforced: false,
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final statusBarHeight = MediaQuery.paddingOf(context).top;
    final placeholder = ColoredBox(
      color: colors.surfaceContainerHighest,
      child: Center(
        child: Icon(
          Icons.person_rounded,
          size: 64,
          color: colors.onSurfaceVariant,
        ),
      ),
    );

    Widget image(String url, Widget fallback) => url.isEmpty
        ? fallback
        : Image.network(
            url,
            fit: BoxFit.cover,
            alignment: const Alignment(0, -0.45),
            excludeFromSemantics: true,
            frameBuilder: (context, child, frame, synchronous) =>
                frame == null && !synchronous ? fallback : child,
            errorBuilder: (_, _, _) => fallback,
          );

    Widget portrait(String url) =>
        image(url, image(avatar == url ? '' : avatar, placeholder));

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: _photoSystemStyle,
      child: LayoutBuilder(
        builder: (context, constraints) => SizedBox(
          height:
              (constraints.maxWidth * 0.86).clamp(160.0, 328.0) +
              statusBarHeight,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (photos.length > 1)
                _ArtistCarousel(
                  key: ObjectKey(photos),
                  photoCount: photos.length,
                  portrait: (index) => portrait(photos[index]),
                )
              else
                portrait(photos.firstOrNull ?? ''),
              const IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      stops: [0, 0.45, 0.55, 1],
                      colors: [
                        Colors.black54,
                        Colors.transparent,
                        Colors.transparent,
                        Colors.black54,
                      ],
                    ),
                  ),
                ),
              ),
              Positioned(
                // 只有顶栏避让状态栏，照片和渐变一直铺到屏幕顶部。
                top: statusBarHeight,
                left: 0,
                right: 0,
                height: kToolbarHeight,
                child: AppBar(
                  primary: false,
                  backgroundColor: Colors.transparent,
                  foregroundColor: Colors.white,
                  scrolledUnderElevation: 0,
                  systemOverlayStyle: _photoSystemStyle,
                ),
              ),
              Positioned(
                left: 20,
                right: 20,
                // 多图时为底部的轮播指示留出一行。
                bottom: photos.length > 1 ? 32 : 18,
                child: IgnorePointer(
                  child: Semantics(
                    header: true,
                    child: Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.left,
                      style: theme.textTheme.headlineSmall?.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ArtistCarousel extends StatefulWidget {
  const _ArtistCarousel({
    super.key,
    required this.photoCount,
    required this.portrait,
  });

  final int photoCount;
  final Widget Function(int index) portrait;

  @override
  State<_ArtistCarousel> createState() => _ArtistCarouselState();
}

class _ArtistCarouselState extends State<_ArtistCarousel> {
  final _pages = PageController(initialPage: 1, keepPage: false);
  Timer? _advance;
  bool _autoPlay = false;
  int _index = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final isCurrent = ModalRoute.isCurrentOf(context) ?? true;
    _autoPlay = isCurrent && !MediaQuery.disableAnimationsOf(context);
    _scheduleAdvance();
  }

  @override
  void dispose() {
    _advance?.cancel();
    _pages.dispose();
    super.dispose();
  }

  void _scheduleAdvance() {
    _advance?.cancel();
    if (!_autoPlay) return;
    _advance = Timer(const Duration(seconds: 5), () {
      if (!_pages.hasClients || _pages.position.isScrollingNotifier.value) {
        return;
      }
      unawaited(
        _pages.nextPage(
          duration: const Duration(milliseconds: 350),
          curve: Curves.easeInOut,
        ),
      );
    });
  }

  void _settle() {
    if (!mounted ||
        !_pages.hasClients ||
        _pages.position.isScrollingNotifier.value) {
      return;
    }
    final page = _pages.page?.round();
    // 首尾各加一张重复图，滑到重复图后无动画回到相同画面。
    if (page == 0) _pages.jumpToPage(widget.photoCount);
    if (page == widget.photoCount + 1) _pages.jumpToPage(1);
    _scheduleAdvance();
  }

  @override
  Widget build(BuildContext context) {
    final behavior = ScrollConfiguration.of(context);
    return Stack(
      fit: StackFit.expand,
      children: [
        NotificationListener<ScrollNotification>(
          onNotification: (notification) {
            if (notification.depth != 0) return false;
            if (notification is ScrollStartNotification) _advance?.cancel();
            if (notification is ScrollEndNotification) {
              scheduleMicrotask(_settle);
            }
            return false;
          },
          child: PageView.builder(
            controller: _pages,
            scrollBehavior: behavior.copyWith(
              dragDevices: {...behavior.dragDevices, PointerDeviceKind.mouse},
            ),
            allowImplicitScrolling: true,
            itemCount: widget.photoCount + 2,
            onPageChanged: (page) {
              final index = (page - 1) % widget.photoCount;
              if (index != _index) setState(() => _index = index);
            },
            itemBuilder: (context, page) =>
                widget.portrait((page - 1) % widget.photoCount),
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 12,
          child: Center(
            child: IgnorePointer(
              child: Semantics(
                label: '照片 ${_index + 1} / ${widget.photoCount}',
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Colors.black45,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 4,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (var i = 0; i < widget.photoCount; i++)
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 2),
                            child: Icon(
                              Icons.circle,
                              size: 6,
                              color: i == _index
                                  ? Colors.white
                                  : Colors.white54,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

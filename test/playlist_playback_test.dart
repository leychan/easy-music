import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:easy_music/account/account.dart';
import 'package:easy_music/account/kugou/kugou_auth.dart';
import 'package:easy_music/music/catalog.dart';
import 'package:easy_music/music/discover_cache.dart';
import 'package:easy_music/music/kugou_music_api.dart';
import 'package:easy_music/music/music_library.dart';
import 'package:easy_music/music/song.dart';
import 'package:easy_music/player/playback.dart';
import 'package:easy_music/player/session_store.dart';
import 'package:easy_music/player/track.dart';
import 'package:easy_music/ui/cover.dart';
import 'package:easy_music/ui/discover_page.dart';
import 'package:easy_music/ui/mini_player_bar.dart';
import 'package:easy_music/ui/mv_player_page.dart';
import 'package:easy_music/ui/now_playing.dart';
import 'package:easy_music/ui/search_page.dart';
import 'package:easy_music/ui/song_tile.dart';
import 'package:easy_music/ui/workspace_page.dart';
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/services.dart' show SystemChannels;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

const _first = Song(hash: 'ABC', title: '歌单歌曲甲', albumAudioId: 1);
const _second = Song(hash: 'DEF', title: '歌单歌曲乙', albumAudioId: 2);
const _unavailable = Song(hash: 'FA0', title: '无法播放的歌曲', albumAudioId: 3);
const _url = SongUrl(url: 'https://example.org/audio.mp3');

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  Future<(_TestPlayer, _TestLibrary)> mount(
    WidgetTester tester, TargetPlatform platform, List<Song> songs,
  ) async {
    final store = SessionStore(':memory:');
    final account = Account();
    final player = _TestPlayer(store);
    final library = _TestLibrary(account);
    addTearDown(store.close);
    addTearDown(account.dispose);
    addTearDown(library.dispose);
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(platform: platform),
      home: SongListPage(
        title: '测试歌单', player: player, library: library,
        playlist: const Playlist(globalCollectionId: 'test', name: '测试歌单', listId: 1),
        loader: () async => songs,
      ),
    ));
    await tester.pumpAndSettle();
    return (player, library);
  }

  Finder row(Song song) => find.ancestor(
    of: find.text(song.title), matching: find.byType(SongTile),
  );

  Finder button(Song song, String tooltip) => find.descendant(
    of: row(song), matching: find.byTooltip(tooltip),
  );

  Future<void> finishPlayingTransition(WidgetTester tester) async {
    // 等待页面切换完成。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
  }

  testWidgets('点播打开播放页，返回时列表同步高亮、暂停和切歌', (tester) async {
    final (player, library) = await mount(tester, TargetPlatform.linux, [_first, _second]);
    final queued = Track.online('queued', 'https://example.org/queued.mp3');
    await player.playTracks([queued]);
    final pending = Completer<SongUrl?>();
    library.firstRequest = pending.future;
    await tester.tap(find.text(_first.title));
    await tester.pump();
    expect(tester.widget<SongTile>(row(_first)).loading, isTrue);
    await tester.tap(find.text(_first.title));
    expect(library.requested, [_first.id]);

    pending.complete(_url);
    await finishPlayingTransition(tester);
    expect(find.byType(NowPlayingPage), findsOneWidget);
    expect(find.text(_first.title), findsOneWidget);
    expect(player.tracks.value.map((track) => track.id), [queued.id, _first.id]);
    await tester.tap(find.byTooltip('返回播放器'));
    await tester.pumpAndSettle();
    expect(tester.widget<SongTile>(row(_first)).selected, isTrue);
    expect(button(_first, '暂停'), findsOneWidget);

    await tester.tap(button(_first, '暂停'));
    await tester.pumpAndSettle();
    expect(player.playbackState.value.playing, isFalse);
    await tester.tap(button(_first, '播放'));
    await finishPlayingTransition(tester);
    expect(find.byType(NowPlayingPage), findsOneWidget);
    expect(find.text(_first.title), findsOneWidget);
    expect(library.requested, [_first.id]);
    await tester.tap(find.byTooltip('返回播放器'));
    await tester.pumpAndSettle();

    await tester.tap(button(_second, '播放'));
    await finishPlayingTransition(tester);
    expect(find.text(_second.title), findsOneWidget);
    await tester.tap(find.byTooltip('返回播放器'));
    await tester.pumpAndSettle();
    expect(tester.widget<SongTile>(row(_first)).selected, isFalse);
    expect(tester.widget<SongTile>(row(_second)).selected, isTrue);
  });

  testWidgets('取不到地址留在歌单，播放全部从可播歌曲打开 Android 播放页', (tester) async {
    final (player, _) = await mount(tester, TargetPlatform.android, [_unavailable, _second]);
    await player.playTracks([Track.online('old', 'https://example.org/old.mp3')]);
    await tester.tap(button(_unavailable, '播放'));
    await tester.pumpAndSettle();
    expect(find.byType(NowPlayingPage), findsNothing);
    expect(find.text('酷狗暂未返回可播放的地址，请稍后重试。'), findsOneWidget);
    expect(tester.widget<SongTile>(row(_unavailable)).selected, isFalse);

    await tester.tap(find.byTooltip('播放全部'));
    await finishPlayingTransition(tester);
    expect(find.byType(NowPlayingPage), findsOneWidget);
    expect(find.byTooltip('返回播放器'), findsOneWidget);
    expect(find.text(_second.title), findsOneWidget);
    expect(player.tracks.value.map((track) => track.id), [_second.id]);
  });

  testWidgets('发现页重开先显示上次结果，原位替换成功的列表并保留刷新失败的列表', (tester) async {
    final directory = Directory.systemTemp.createTempSync('discover-test-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final path = '${directory.path}/player.sqlite3';
    final previous = SessionStore(path);
    final cache = DiscoverCache(previous);
    List<Song> songs(String label) => [
      for (var index = 1; index <= 8; index++)
        Song(hash: 'A$index', title: '$label $index', albumAudioId: index),
    ];
    const savedPlaylist = Playlist(globalCollectionId: 'collection_1', name: '上次的歌单', listId: 1);
    cache.saveDaily(null, songs('上次的歌曲'));
    cache.saveDaily(47, [_first]);
    cache.savePlaylists(null, [savedPlaylist]);
    previous.close();

    final store = SessionStore(path);
    final account = Account();
    final player = _TestPlayer(store);
    final library = _TestLibrary(account, store: store);
    final daily = Completer<List<Song>>();
    final playlists = Completer<List<Playlist>>();
    library.nextDaily = daily.future;
    library.nextPlaylists = playlists.future;
    addTearDown(store.close);
    addTearDown(account.dispose);
    addTearDown(library.dispose);

    await tester.pumpWidget(MaterialApp(home: Scaffold(
      body: DiscoverPage(library: library, player: player, userid: null),
    )));
    final carousel = find.byKey(const PageStorageKey('每日推荐'));
    expect(find.text('上次的歌曲 1'), findsOneWidget);
    expect(find.text(_first.title), findsNothing);
    expect(find.text(savedPlaylist.name), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    final oldTop = tester.getTopLeft(carousel);
    final scroller = find.descendant(of: carousel, matching: find.byType(Scrollable));
    final position = tester.state<ScrollableState>(scroller).position;
    position.jumpTo(200);
    await tester.pump();
    final offset = position.pixels;
    expect(offset, greaterThan(0));

    daily.complete(songs('刷新的歌曲'));
    await tester.pump();
    expect(find.textContaining('刷新的歌曲 '), findsWidgets);
    expect(find.textContaining('上次的歌曲 '), findsNothing);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    playlists.completeError(StateError('模拟断网'));
    await tester.pumpAndSettle();
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(tester.getTopLeft(carousel), oldTop);
    expect(tester.state<ScrollableState>(scroller).position, same(position));
    expect(position.pixels, closeTo(offset, 0.01));
    expect(find.text(savedPlaylist.name), findsOneWidget);
    expect(DiscoverCache(store).readDaily(null)!.first.title, '刷新的歌曲 1');
    expect(DiscoverCache(store).readPlaylists(null)!.first.id, savedPlaylist.id);
  });

  testWidgets('每日推荐的全部播放替换队列并包含完整推荐列表', (tester) async {
    final store = SessionStore(':memory:');
    final account = Account();
    final player = _TestPlayer(store);
    final library = _TestLibrary(account);
    addTearDown(store.close);
    addTearDown(account.dispose);
    addTearDown(library.dispose);
    await player.playTracks([Track.online('old', 'https://example.org/old.mp3')]);
    final songs = [
      for (var index = 1; index <= 32; index++)
        Song(hash: 'A${index.toRadixString(16)}', title: '推荐 $index', albumAudioId: index),
    ];
    library.daily = songs;
    await tester.pumpWidget(MaterialApp(home: Scaffold(
      body: DiscoverPage(library: library, player: player, userid: null),
    )));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('全部播放'));
    await tester.pumpAndSettle();
    expect(player.tracks.value.map((track) => track.id), songs.map((song) => song.id));
    expect(player.playbackState.value.queueIndex, 0);
  });

  testWidgets('综合和分类搜索滚动追加结果，全部播放包含已加载歌曲并去重', (tester) async {
    tester.view
      ..physicalSize = const Size(380, 480)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final store = SessionStore(':memory:');
    final account = Account();
    final player = _TestPlayer(store);
    const extra = Song(hash: 'BEA', title: '第四个歌曲结果', albumAudioId: 4);
    const fifth = Song(hash: 'BE6', title: '第五个歌曲结果', albumAudioId: 7);
    const sixth = Song(hash: 'BE7', title: '第六个歌曲结果', albumAudioId: 8);
    const lyric = Song(hash: 'BED', title: '只匹配歌词的歌曲', albumAudioId: 5);
    const later = Song(hash: 'DAD', title: '新加载的歌曲', albumAudioId: 6);
    final library = _TestLibrary(account)
      ..searchResults = {
        (SearchType.song, 1): [_first, _second, _unavailable, extra, fifth, sixth].map(CatalogHit.track).toList(),
        (SearchType.artist, 1): [const CatalogHit(id: '123', title: '搜索命中的歌手')],
        (SearchType.lyric, 1): [CatalogHit.track(_second), CatalogHit.track(lyric)],
        (SearchType.song, 2): [CatalogHit.track(_second), CatalogHit.track(later)],
      };
    addTearDown(store.close);
    addTearDown(account.dispose);
    addTearDown(library.dispose);
    await player.playTracks([Track.online('old', 'https://example.org/old.mp3')]);
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(platform: TargetPlatform.android),
      home: Scaffold(body: SearchPage(library: library, player: player)),
    ));
    await tester.enterText(find.byType(TextField), '测试');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();

    final overview = find.widgetWithText(ChoiceChip, '综合');
    final mv = find.widgetWithText(ChoiceChip, 'MV');
    final filters = find.byWidgetPredicate((widget) =>
      widget is SingleChildScrollView && widget.scrollDirection == Axis.horizontal,
    );
    final playAll = find.byTooltip('全部播放');
    final allSongs = find.byTooltip('查看全部歌曲').hitTestable();
    final songHeader = find.ancestor(of: allSongs, matching: find.byType(MusicSectionHeader));
    expect(tester.widget<ChoiceChip>(overview).selected, isTrue);
    expect(tester.getCenter(overview).dy, tester.getCenter(mv).dy);
    expect(mv.hitTestable(), findsNothing);
    expect(tester.getCenter(playAll).dy, greaterThan(tester.getRect(filters).bottom));
    expect(tester.getCenter(playAll).dy, tester.getCenter(allSongs).dy);
    expect(tester.getSize(playAll), tester.getSize(allSongs));
    expect(tester.getRect(playAll).right, lessThanOrEqualTo(tester.getRect(allSongs).left));
    expect(tester.getRect(songHeader).right, 360);
    expect(find.descendant(of: songHeader, matching: playAll), findsOneWidget);
    expect(find.descendant(of: playAll, matching: find.byIcon(Icons.play_circle_outline_rounded)), findsOneWidget);
    expect(find.descendant(of: allSongs, matching: find.byIcon(Icons.chevron_right_rounded)), findsOneWidget);
    expect(find.text('全部播放'), findsNothing);
    expect(find.text('更多歌曲'), findsNothing);
    await tester.drag(filters, const Offset(-260, 0), kind: PointerDeviceKind.mouse);
    await tester.pumpAndSettle();
    expect(mv.hitTestable(), findsOneWidget);
    await tester.drag(filters, const Offset(260, 0));
    await tester.pumpAndSettle();

    expect(library.complexPages, [1]);
    expect(library.searched, SearchType.values.map((type) => (type, 1)));
    final results = find.byType(CustomScrollView);
    final scroll = tester.widget<CustomScrollView>(results).controller!;
    final firstExtent = scroll.position.maxScrollExtent;
    final scrollable = find.descendant(of: results, matching: find.byType(Scrollable));
    await tester.tap(playAll);
    await tester.pumpAndSettle();
    final firstPageSongs = [_first, _second, extra, fifth, sixth, lyric];
    expect(player.tracks.value.map((track) => track.id), firstPageSongs.map((song) => song.id));
    expect(player.playbackState.value.queueIndex, 0);

    await tester.scrollUntilVisible(find.text(fifth.title), 60, scrollable: scrollable);
    expect(find.text(sixth.title), findsNothing);
    expect(find.text('上一页'), findsNothing);
    expect(find.text('下一页'), findsNothing);
    await tester.drag(results, const Offset(0, -800));
    await tester.pumpAndSettle();
    expect(scroll.offset, greaterThan(0));
    expect(library.searched, [for (final page in [1, 2]) ...SearchType.values.map((type) => (type, page))],
      reason: '滚动位置 ${scroll.offset}，列表末尾 ${scroll.position.maxScrollExtent}',
    );
    expect(scroll.position.maxScrollExtent, greaterThan(firstExtent));
    scroll.jumpTo(scroll.position.maxScrollExtent);
    await tester.pumpAndSettle();
    expect(find.text(later.title), findsOneWidget);
    expect(library.complexPages, [1]);
    scroll.jumpTo(0);
    await tester.pumpAndSettle();
    await tester.tap(playAll);
    await tester.pumpAndSettle();
    expect(player.tracks.value.map((track) => track.id), [...firstPageSongs, later].map((song) => song.id));

    expect(find.text(_first.title), findsOneWidget);
    final beforeCategory = library.searched.length;
    await tester.tap(allSongs);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text(later.title), 120, scrollable: scrollable);
    await tester.pumpAndSettle();
    expect(find.text(sixth.title), findsOneWidget);
    expect(find.text(later.title), findsOneWidget);
    expect(library.searched.skip(beforeCategory), [(SearchType.song, 1), (SearchType.song, 2)]);

    await tester.tap(find.widgetWithText(ChoiceChip, '歌手'));
    await tester.pumpAndSettle();
    expect(find.text('搜索命中的歌手'), findsOneWidget);
    expect(playAll, findsNothing);
    expect(library.searched.last, (SearchType.artist, 1));
  });

  testWidgets('综合搜索的歌单和 MV 从右侧箭头进入完整分类', (tester) async {
    final store = SessionStore(':memory:');
    final account = Account();
    final player = _TestPlayer(store);
    final groups = {
      for (final type in [SearchType.playlist, SearchType.video])
        type: [for (var i = 1; i <= 4; i++) CatalogHit(id: '$i', title: '${type.label}结果 $i')],
    };
    final library = _TestLibrary(account)
      ..complexResults = {1: groups}
      ..searchResults = {for (final entry in groups.entries) (entry.key, 1): entry.value};
    addTearDown(store.close);
    addTearDown(account.dispose);
    addTearDown(library.dispose);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SearchPage(library: library, player: player))));
    await tester.enterText(find.byType(TextField), '测试');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();

    for (final MapEntry(key: type, value: hits) in groups.entries) {
      final arrow = find.byTooltip('查看全部${type.label}');
      expect(find.text('更多${type.label}'), findsNothing);
      expect(find.descendant(of: arrow, matching: find.byIcon(Icons.chevron_right_rounded)), findsOneWidget);
      expect(find.text(hits.last.title), findsNothing);
      await tester.tap(arrow);
      await tester.pumpAndSettle();
      expect(library.searched.last, (type, 1));
      expect(find.text(hits.last.title), findsOneWidget);

      await tester.tap(find.widgetWithText(ChoiceChip, '综合'));
      await tester.pumpAndSettle();
    }
  });

  testWidgets('默认综合接口自动补满列表，加载失败可重试并保留原结果', (tester) async {
    final store = SessionStore(':memory:');
    final account = Account();
    final player = _TestPlayer(store);
    final library = _TestLibrary(account)
      ..complexResults = {
        1: {SearchType.song: [CatalogHit.track(_first)]},
        2: {SearchType.song: [CatalogHit.track(_second)]},
      }
      ..failedComplexPage = 2;
    addTearDown(store.close);
    addTearDown(account.dispose);
    addTearDown(library.dispose);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SearchPage(library: library, player: player))));
    await tester.enterText(find.byType(TextField), '测试');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();

    expect(find.text(_first.title), findsOneWidget);
    expect(library.searched, isEmpty);
    expect(library.complexPages, [1, 2]);
    expect(find.text('综合搜索失败，请稍后重试。'), findsOneWidget);

    library.failedComplexPage = null;
    await tester.tap(find.text('重试加载更多'));
    await tester.pumpAndSettle();
    expect(find.text(_first.title), findsOneWidget);
    expect(find.text(_second.title), findsOneWidget);
    expect(find.text('重试加载更多'), findsNothing);
    expect(library.complexPages, [1, 2, 2]);
    expect(library.searched, isEmpty);
    await tester.tap(find.byTooltip('全部播放'));
    await tester.pumpAndSettle();
    expect(player.tracks.value.map((track) => track.id), [_first.id, _second.id]);
  });

  testWidgets('点击 MV 搜索结果直接进入播放页并自动取地址，失败后可重试和返回', (tester) async {
    tester.view
      ..physicalSize = const Size(420, 860)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final orientations = <List<String>>[];
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'SystemChrome.setPreferredOrientations') {
        orientations.add(List<String>.from(call.arguments as List));
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(SystemChannels.platform, null));
    final store = SessionStore(':memory:');
    final account = Account();
    final player = _TestPlayer(store);
    const hit = CatalogHit(id: 'ABC-MV', title: '示例 MV', subtitle: '示例歌手');
    final requested = <String>[];
    final pending = Completer<Uri>();
    final library = _TestLibrary(account)
      ..complexResults = {1: {SearchType.video: [hit]}}
      ..loadVideoAddress = (hash) async {
        requested.add(hash);
        if (requested.length == 1) return pending.future;
        throw const KugouFailure('视频源暂不可用。');
      };
    addTearDown(store.close);
    addTearDown(account.dispose);
    addTearDown(library.dispose);
    final queued = Track.online('old', 'https://example.org/old.mp3');
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(platform: TargetPlatform.android),
      home: Scaffold(body: SearchPage(library: library, player: player)),
    ));
    await tester.enterText(find.byType(TextField), '测试');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    await player.playTracks([queued]);

    await tester.tap(find.text(hit.title));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    final mvPage = find.byType(MvPlayerPage);
    expect(mvPage, findsOneWidget);
    final surface = find.descendant(
      of: mvPage,
      matching: find.byWidgetPredicate((widget) => widget is Material && widget.color == Colors.black),
    );
    final mvTheme = Theme.of(tester.element(surface));
    expect(mvTheme.brightness, Brightness.dark);
    Finder inMv(Finder matching) => find.descendant(of: mvPage, matching: matching);
    expect(inMv(find.byType(AppBar)), findsNothing);
    expect(inMv(find.byType(IconButton)), findsOneWidget);
    final title = tester.getCenter(inMv(find.text(hit.title)));
    final artist = tester.getCenter(inMv(find.text(hit.subtitle)));
    final video = tester.getCenter(inMv(find.byType(CircularProgressIndicator)));
    final progress = tester.getCenter(inMv(find.byType(Slider)));
    expect(title.dx, closeTo(210, 1));
    expect(artist.dx, closeTo(title.dx, 1));
    expect(artist.dy, greaterThan(title.dy));
    expect(video.dy, greaterThan(artist.dy));
    expect(video.dy, lessThan(430));
    expect(progress.dy, greaterThan(800));
    expect(requested, [hit.id]);

    await tester.tap(inMv(find.byTooltip('横屏播放')));
    await tester.pump();
    expect(orientations.last, ['DeviceOrientation.landscapeLeft', 'DeviceOrientation.landscapeRight']);
    tester.view.physicalSize = const Size(860, 420);
    await tester.pump();
    expect(inMv(find.byTooltip('切回竖屏')), findsOneWidget);
    expect(inMv(find.text(hit.title)), findsNothing);
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(mvPage, findsOneWidget);
    expect(orientations.last, ['DeviceOrientation.portraitUp']);
    tester.view.physicalSize = const Size(420, 860);
    await tester.pump();

    pending.completeError(const KugouFailure('读取 MV 失败。'));
    await tester.pumpAndSettle();
    expect(find.text('读取 MV 失败。'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, '重试'));
    await tester.pumpAndSettle();
    expect(find.text('视频源暂不可用。'), findsOneWidget);
    expect(requested, [hit.id, hit.id]);
    expect(player.tracks.value, [queued]);
    expect(player.playbackState.value.playing, isTrue);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(MvPlayerPage), findsNothing);
    expect(find.text(hit.title), findsOneWidget);
    expect(orientations.last, isEmpty);
  });

  testWidgets('点击全部播放后，播放栏立即展示第一首歌并转圈，失败时恢复原曲目', (tester) async {
    final store = SessionStore(':memory:');
    final account = Account();
    final player = Playback(store);
    final pending = Completer<SongUrl?>();
    const first = Song(
      hash: 'ABC', title: '新歌单首曲', albumAudioId: 1,
      singers: ['新歌手'], albumImage: 'https://example.org/first.jpg',
    );
    final old = Track(
      id: 'old', title: '旧歌曲', artist: '旧歌手',
      source: Uri.parse('https://example.org/old.mp3'),
      artUri: Uri.parse('https://example.org/old.jpg'),
    );
    final library = _TestLibrary(account)
      ..daily = [first]
      ..firstRequest = pending.future;
    addTearDown(store.close);
    addTearDown(account.dispose);
    addTearDown(library.dispose);
    player.tracks.value = [old];
    player.playbackState.add(PlaybackState(queueIndex: 0));
    await tester.pumpWidget(MaterialApp(home: Scaffold(
      body: DiscoverPage(library: library, player: player, userid: null),
      bottomNavigationBar: MiniPlayerBar(
        player: player, library: library, onOpen: ({required showLyrics}) {},
      ),
    )));
    await tester.pumpAndSettle();

    final bar = find.byType(MiniPlayerBar);
    Finder barText(String text) => find.descendant(of: bar, matching: find.text(text));
    String barCover() => tester.widget<Cover>(
      find.descendant(of: bar, matching: find.byType(Cover)),
    ).url;
    final spinner = find.descendant(of: bar, matching: find.byType(CircularProgressIndicator));
    expect(spinner, findsNothing);
    expect(barText(old.title), findsOneWidget);
    await tester.tap(find.byTooltip('全部播放'));
    await tester.pump();
    expect(library.requested, [first.id]);
    expect(player.tracks.value, [old]);
    expect(barText(old.title), findsNothing);
    expect(barText(first.title), findsOneWidget);
    expect(barText(first.artist), findsOneWidget);
    expect(barCover(), first.coverUrl(480));
    expect(spinner, findsOneWidget);

    pending.complete(null);
    await tester.pumpAndSettle();
    expect(spinner, findsNothing);
    expect(barText(old.title), findsOneWidget);
    expect(barCover(), old.artUri.toString());
  });
}

class _TestLibrary extends MusicLibrary {
  _TestLibrary(super.account, {super.store});

  Future<SongUrl?>? firstRequest;
  final requested = <String>[];
  List<Song> daily = const [];
  Future<List<Song>>? nextDaily;
  Future<List<Playlist>>? nextPlaylists;
  Map<(SearchType, int), List<CatalogHit>> searchResults = const {};
  Map<int, Map<SearchType, List<CatalogHit>>> complexResults = const {};
  Future<Uri> Function(String hash)? loadVideoAddress;
  int? failedComplexPage;
  final searched = <(SearchType, int)>[];
  final complexPages = <int>[];

  @override
  Future<Uri> videoAddress(String hash) => loadVideoAddress?.call(hash) ?? super.videoAddress(hash);

  @override
  Future<CatalogSearchResult<List<CatalogHit>>> searchCatalogPage(
    String keyword,
    SearchType type, {
    required int page,
  }) async {
    searched.add((type, page));
    return (
      hits: searchResults[(type, page)] ?? <CatalogHit>[],
      hasMore: searchResults.containsKey((type, page + 1)),
    );
  }

  @override
  Future<CatalogSearchResult<Map<SearchType, List<CatalogHit>>>> searchComplex(
    String keyword, {
    required int page,
  }) async {
    complexPages.add(page);
    final hits = complexResults[page];
    if (hits == null || page == failedComplexPage) {
      throw const KugouFailure('综合搜索失败，请稍后重试。');
    }
    return (hits: hits, hasMore: complexResults.containsKey(page + 1));
  }

  @override
  Future<List<Song>> dailyRecommend() async => nextDaily ?? daily;

  @override
  Future<List<Playlist>> recommendedPlaylists({int category = 0, bool refresh = false}) async => nextPlaylists ?? const [];

  @override
  Future<List<Song>> completeCovers(List<Song> songs) async => songs;

  @override
  Future<SongUrl?> songUrl(
    Song song, {
    bool refresh = false,
    AudioQuality quality = AudioQuality.standard,
  }) async {
    requested.add(song.id);
    if (song == _unavailable) return null;
    if (song.id == _first.id && firstRequest != null) return firstRequest;
    return _url;
  }
}

/// 用同步的播放状态代替原生音频输出，保留歌单的实际点播逻辑。
class _TestPlayer extends Playback {
  _TestPlayer(super.store);

  @override
  Future<void> playTracks(List<Track> items) async {
    final existing = {for (final track in tracks.value) track.id: track};
    existing.addEntries(items.map((track) => MapEntry(track.id, track)));
    _publishTracks(existing.values.toList(), items.first.id);
  }

  @override
  Future<bool> replaceTracks(
    FutureOr<List<Track>> items, {
    MediaItem? preview,
    Future<List<Track>> Function()? loadMore,
  }) async {
    final ready = await items;
    if (ready.isEmpty) return false;
    _publishTracks(ready, ready.first.id);
    return true;
  }

  void _publishTracks(List<Track> items, String selected) {
    tracks.value = items;
    playbackState.add(PlaybackState(
      processingState: AudioProcessingState.ready,
      playing: true,
      queueIndex: items.indexWhere((track) => track.id == selected),
    ));
  }

  @override
  Future<void> play() async => playbackState.add(playbackState.value.copyWith(playing: true));

  @override
  Future<void> pause() async => playbackState.add(playbackState.value.copyWith(playing: false));
}

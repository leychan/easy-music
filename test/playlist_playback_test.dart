import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:easy_music/account/account.dart';
import 'package:easy_music/music/discover_cache.dart';
import 'package:easy_music/music/kugou_music_api.dart';
import 'package:easy_music/music/music_library.dart';
import 'package:easy_music/music/song.dart';
import 'package:easy_music/player/playback.dart';
import 'package:easy_music/player/session_store.dart';
import 'package:easy_music/player/track.dart';
import 'package:easy_music/ui/discover_page.dart';
import 'package:easy_music/ui/now_playing.dart';
import 'package:easy_music/ui/song_tile.dart';
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
}

class _TestLibrary extends MusicLibrary {
  _TestLibrary(super.account, {super.store});

  Future<SongUrl?>? firstRequest;
  final requested = <String>[];
  List<Song> daily = const [];
  Future<List<Song>>? nextDaily;
  Future<List<Playlist>>? nextPlaylists;

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
    if (song == _first && firstRequest != null) return firstRequest;
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
  Future<bool> replaceTracks(FutureOr<List<Track>> items, {Future<List<Track>> Function()? loadMore}) async {
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

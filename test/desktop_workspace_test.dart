import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show ImageByteFormat, PointerDeviceKind;

import 'package:audio_service/audio_service.dart';
import 'package:easy_music/account/account.dart';
import 'package:easy_music/account/account_page.dart';
import 'package:easy_music/account/kugou/kugou_auth.dart';
import 'package:easy_music/account/kugou/kugou_client.dart';
import 'package:easy_music/account/kugou/kugou_device.dart';
import 'package:easy_music/main.dart';
import 'package:easy_music/music/music_library.dart';
import 'package:easy_music/music/song.dart';
import 'package:easy_music/player/audio_quality.dart';
import 'package:easy_music/player/lyrics.dart';
import 'package:easy_music/player/playback.dart';
import 'package:easy_music/player/session_store.dart';
import 'package:easy_music/player/track.dart';
import 'package:easy_music/ui/appearance.dart';
import 'package:easy_music/ui/cover.dart';
import 'package:easy_music/ui/desktop_player_bar.dart';
import 'package:easy_music/ui/desktop_workspace.dart';
import 'package:easy_music/ui/discover_page.dart';
import 'package:easy_music/ui/favorite_button.dart';
import 'package:easy_music/ui/glass_surface.dart';
import 'package:easy_music/ui/lyrics_display.dart';
import 'package:easy_music/ui/mini_player_bar.dart';
import 'package:easy_music/ui/my_page.dart';
import 'package:easy_music/ui/now_playing.dart';
import 'package:easy_music/ui/player_controls.dart';
import 'package:easy_music/ui/player_page.dart';
import 'package:easy_music/ui/workspace_page.dart';
import 'package:flutter/rendering.dart' show OffsetLayer;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  const cover = 'https://imge.kugou.com/stdmusic/{size}/example.jpg';
  final desktopSearch = find.byWidgetPredicate((widget) =>
    widget is TextField && widget.decoration?.hintText == '搜索歌曲、歌手、专辑',
  );

  Finder discoverHeading(String title) => find.descendant(
    of: find.byType(DiscoverPage), matching: find.text(title),
  );

  Finder viewAll(String title) => find.descendant(
    of: find.ancestor(of: discoverHeading(title), matching: find.byType(Row)).first,
    matching: find.byWidgetPredicate((widget) =>
      widget is IconButton && widget.tooltip == '查看全部',
    ),
  );

  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  testWidgets('首次启动跟随系统，手动选择可覆盖系统配色', (tester) async {
    final store = SessionStore(':memory:');
    final appearance = Appearance(store);
    addTearDown(store.close);
    addTearDown(appearance.dispose);
    final platform = tester.binding.platformDispatcher;
    addTearDown(platform.clearPlatformBrightnessTestValue);
    platform.platformBrightnessTestValue = Brightness.light;
    await tester.pumpWidget(EasyMusicApp(appearance: appearance));

    ThemeData currentTheme() => Theme.of(tester.element(find.byType(Scaffold)));
    expect(appearance.value.mode, ThemeMode.system);
    final day = currentTheme();
    expect(day.brightness, Brightness.light);
    expect(day.scaffoldBackgroundColor, const Color(0xFFFBF6EE));

    platform.platformBrightnessTestValue = Brightness.dark;
    await tester.pumpAndSettle();
    expect(currentTheme().brightness, Brightness.dark);
    expect(currentTheme().scaffoldBackgroundColor, const Color(0xFF211923));

    appearance.update(mode: ThemeMode.light, color: const Color(0xFF81A9FF));
    await tester.pumpAndSettle();
    expect(currentTheme().brightness, Brightness.light);
    expect(currentTheme().scaffoldBackgroundColor, day.scaffoldBackgroundColor);
    expect(currentTheme().colorScheme.primary, isNot(day.colorScheme.primary));

    appearance.update(mode: ThemeMode.dark);
    platform.platformBrightnessTestValue = Brightness.light;
    await tester.pumpAndSettle();
    expect(currentTheme().brightness, Brightness.dark);

    appearance.update(mode: ThemeMode.system);
    await tester.pumpAndSettle();
    expect(currentTheme().brightness, Brightness.light);
  });

  void expectPlaybackBarOrder(WidgetTester tester, String title) {
    Finder inBar(Finder finder) => find.descendant(
      of: find.byType(DesktopPlayerBar), matching: finder,
    );
    final groups = [
      inBar(find.byType(Cover)),
      inBar(find.text(title)),
      inBar(find.byType(PlayerControls)),
      inBar(find.byType(PlaybackSeekBar)),
      inBar(find.byTooltip('打开播放队列')),
    ].map(tester.getCenter).toList();
    for (var index = 1; index < groups.length; index++) {
      expect(groups[index].dx, greaterThan(groups[index - 1].dx));
      expect(groups[index].dy, closeTo(groups.first.dy, 12));
    }
    expect(tester.getSize(inBar(find.byType(Slider))).width, greaterThan(32));
  }

  Future<Playback> mount(
    WidgetTester tester,
    TargetPlatform platform,
    Size size, {
    List<Uri>? requests,
    Track? initialTrack,
    bool emptyQueue = false,
    KugouSession? session,
    FutureOr<Map<String, Object?>?> Function(http.Request)? respond,
    Account Function(KugouClient)? accountFactory,
    SessionStore? preferences,
  }) async {
    tester.view
      ..physicalSize = size
      ..devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final store = preferences ?? SessionStore(':memory:');
    if (preferences == null) addTearDown(store.close);
    final appearance = preferences == null ? null : Appearance(store);
    if (appearance != null) addTearDown(appearance.dispose);
    final player = Playback(store);
    if (session != null) {
      FlutterSecureStorage.setMockInitialValues({'kugou_session': jsonEncode(session.toJson())});
    }
    final client = KugouClient(
        KugouDevice(guid: 'desktop-test', mac: '02:00:00:00:00:00'),
        client: MockClient((request) async {
          requests?.add(request.url);
          final data = await respond?.call(request) ?? switch (request.url.path) {
            '/v2/search/song' => {
              'status': 1,
              'data': {
                'lists': [
                  {
                    'SongName': '搜索命中的歌曲',
                    'FileHash': 'ABC123',
                    'Audioid': 1234,
                  },
                ],
              },
            },
            '/everyday_song_recommend' => {
              'status': 1,
              'data': {
                'info': [
                  {'name': '推荐歌曲甲', 'hash': 'A1', 'mixsongid': 1},
                  {'name': '推荐歌曲乙', 'hash': 'A2', 'mixsongid': 2},
                ],
              },
            },
            '/kmr/v2/audio' => {
              'status': 1,
              'data': [
                {
                  'base': {'album_audio_id': 1234},
                  'album_info': {'cover': cover},
                },
              ],
            },
            '/kmr/v2/albums' => {
              'status': 1,
              'data': [
                {'album_id': 5678, 'sizable_cover': cover},
              ],
            },
            '/search' => {
              'candidates': [
                {'id': 1, 'accesskey': 'test-key', 'duration': 120000},
              ],
            },
            '/download' => {
              'contenttype': 1,
              'content': base64Encode(utf8.encode('[00:00.00]自动加载的歌词')),
            },
            _ => {'status': 1, 'data': <String, Object?>{}},
          };
          return http.Response.bytes(utf8.encode(jsonEncode(data)), 200);
        }),
    );
    final account = accountFactory?.call(client) ?? Account(client: client);
    addTearDown(account.dispose);
    if (!emptyQueue) {
      await tester.runAsync(
        () => player.addTracks([
          initialTrack ?? Track(
            id: 'test-track',
            title: '队列测试歌曲',
            source: Uri.parse('https://example.org/test.mp3'),
            lyrics: '[00:00.00]用于测试的歌词',
          ),
        ]),
      );
    }
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: platform),
        darkTheme: ThemeData(platform: platform, brightness: Brightness.dark),
        home: PlayerPage(player: player, account: account, appearance: appearance),
      ),
    );
    await tester.pumpAndSettle();
    return player;
  }

  testWidgets('滚动队列时，当前歌曲的背景色留在列表内', (tester) async {
    final player = await mount(
      tester, TargetPlatform.android, const Size(390, 760), emptyQueue: true,
    );
    player.tracks.value = [
      for (var index = 0; index < 12; index++)
        Track(
          id: 'queue-$index',
          title: '歌曲 $index',
          source: Uri.parse('https://example.org/$index.mp3'),
        ),
    ];
    player.playbackState.add(PlaybackState(queueIndex: 0));
    await tester.tap(find.widgetWithText(NavigationDestination, '队列'));
    await tester.pumpAndSettle();

    final list = find.byType(ReorderableListView);
    final scrollable = find.descendant(of: list, matching: find.byType(Scrollable));
    tester.state<ScrollableState>(scrollable).position.jumpTo(32);
    await tester.pumpAndSettle();

    final bounds = tester.getRect(list);
    final theme = Theme.of(tester.element(list));
    final layer = tester.binding.renderViews.single.debugLayer! as OffsetLayer;
    await tester.runAsync(() async {
      // 在列表上边界两侧取样，避开文字、封面和按钮。
      final image = await layer.toImage(
        Rect.fromLTWH(bounds.right - 112, bounds.top - 12, 1, 25),
      );
      final pixels = (await image.toByteData(format: ImageByteFormat.rawRgba))!;
      image.dispose();

      Color colorAt(int row) {
        final offset = row * 4;
        return Color.fromARGB(
          pixels.getUint8(offset + 3), pixels.getUint8(offset),
          pixels.getUint8(offset + 1), pixels.getUint8(offset + 2),
        );
      }

      expect(colorAt(0), theme.scaffoldBackgroundColor);
      expect(colorAt(24), theme.colorScheme.secondaryContainer);
    });
  });

  testWidgets('Linux 仅搜索页展示搜索栏，底部队列可打开并收起', (tester) async {
    final calls = <Uri>[];
    await mount(
      tester,
      TargetPlatform.linux,
      const Size(1280, 760),
      requests: calls,
    );
    expect(find.byType(DesktopWorkspace), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);
    expect(find.text('发现音乐'), findsOneWidget);
    final headingOrigin = tester.getTopLeft(find.text('发现音乐'));
    expect(find.text('Easy Music'), findsNothing);
    expect(desktopSearch, findsNothing);
    expect(tester.getCenter(find.byTooltip('添加音乐')).dx,
      lessThan(tester.getTopLeft(find.text('发现音乐')).dx),
    );
    expectPlaybackBarOrder(tester, '队列测试歌曲');

    await tester.tap(find.byTooltip('打开播放队列'));
    await tester.pumpAndSettle();
    expect(find.text('播放队列'), findsOneWidget);
    expect(find.byTooltip('清空队列'), findsOneWidget);
    await tester.tap(find.byTooltip('收起队列'));
    await tester.pumpAndSettle();
    expect(find.text('播放队列'), findsNothing);

    final searchTab = tester.getRect(find.byTooltip('搜索'));
    expect(searchTab.height, 47);
    await tester.tapAt(Offset(searchTab.center.dx, searchTab.bottom - 4));
    await tester.pumpAndSettle();
    expect(desktopSearch, findsOneWidget);
    expect(tester.getTopLeft(find.text('搜索音乐')), headingOrigin);
    expect(tester.widget<TextField>(desktopSearch).focusNode?.hasFocus, isTrue);
    await tester.enterText(desktopSearch, '晴天');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(find.text('搜索命中的歌曲'), findsOneWidget);
    expect(find.byWidgetPredicate((widget) => widget is Image &&
        widget.image is NetworkImage &&
        (widget.image as NetworkImage).url == cover.replaceAll('{size}', '150')),
      findsOneWidget,
    );
    expect(
      calls
          .where((uri) => uri.path == '/v2/search/song')
          .single
          .queryParameters['keyword'],
      '晴天',
    );

    await tester.longPress(find.text('搜索命中的歌曲'));
    await tester.pumpAndSettle();
    expect(find.text('歌曲详情'), findsOneWidget);
    expect(tester.getTopLeft(find.text('歌曲详情')), headingOrigin);
    expect(desktopSearch, findsNothing);
    expect(find.byType(BackButton), findsNothing);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(desktopSearch, findsOneWidget);

    await tester.tap(find.byTooltip('歌词'));
    await tester.pumpAndSettle();
    expect(find.text('用于测试的歌词'), findsOneWidget);
    final back = find.byTooltip('返回播放器');
    expect(back, findsOneWidget);
    final titleRect = tester.getRect(find.text('队列测试歌曲'));
    expect(tester.getCenter(back).dx, lessThan(titleRect.left));
    expect(tester.getCenter(back).dy, closeTo(titleRect.center.dy, 1));
    expect(find.byType(DesktopPlayerBar), findsNothing);
    await tester.tap(back);
    await tester.pumpAndSettle();
    expect(desktopSearch, findsOneWidget);
    expect(find.byType(DesktopPlayerBar), findsOneWidget);
  });

  testWidgets('桌面播放详情的渐隐封面与歌词并排，封面不会旋转', (tester) async {
    final player = await mount(tester, TargetPlatform.linux, const Size(1280, 760));
    await tester.tap(viewAll('每日推荐'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('歌词'));
    await tester.pumpAndSettle();

    final page = find.byType(NowPlayingPage);
    final artwork = find.byKey(const ValueKey('now-playing-artwork'));
    expect(tester.getSize(artwork).aspectRatio, 1);
    final masks = find.descendant(of: artwork, matching: find.byType(ShaderMask));
    expect(masks, findsNWidgets(2));
    expect(tester.widgetList<ShaderMask>(masks).map((mask) => mask.blendMode),
      everyElement(BlendMode.dstIn),
    );
    expect(
      tester.getRect(find.byType(SyncedLyrics)).left,
      greaterThan(tester.getRect(artwork).right),
    );
    expect(find.byType(PlaybackVolumeControl), findsOneWidget);
    expect(find.byType(DesktopPlayerBar), findsNothing);

    await tester.tap(artwork);
    await tester.pumpAndSettle();
    expect(page, findsOneWidget);
    expect(artwork, findsNothing);
    expect(find.byTooltip('显示封面'), findsOneWidget);
    await tester.tap(find.text('用于测试的歌词'));
    await tester.pumpAndSettle();
    expect(artwork.hitTestable(), findsOneWidget);

    player.playbackState.add(player.playbackState.value.copyWith(
      playing: true, processingState: AudioProcessingState.ready,
    ));
    await tester.pumpAndSettle();
    expect(find.descendant(of: page, matching: find.byType(RotationTransition)), findsNothing);
    expect(find.byTooltip('暂停'), findsOneWidget);
    await tester.tap(find.byTooltip('返回播放器'));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    expect(find.text('推荐歌曲甲'), findsOneWidget);
    expect(find.byType(DesktopPlayerBar), findsOneWidget);
  });

  testWidgets('播放页自动补齐旧队列的封面和歌词', (tester) async {
    final calls = <Uri>[];
    await mount(
      tester,
      TargetPlatform.linux,
      const Size(1280, 760),
      requests: calls,
      initialTrack: Track(
        id: 'kg:ABC123',
        title: '旧队列歌曲',
        source: Uri.parse('https://example.org/test.mp3'),
        albumAudioId: 1234,
        albumId: 5678,
        duration: const Duration(minutes: 2),
      ),
    );
    await tester.tap(find.byTooltip('歌词'));
    await tester.pumpAndSettle();
    expect(find.text('自动加载的歌词'), findsOneWidget);
    expect(find.byWidgetPredicate((widget) => widget is Image &&
         widget.width == null && widget.image is NetworkImage &&
         (widget.image as NetworkImage).url == cover.replaceAll('{size}', '480')),
       findsWidgets,
    );
    expect(find.descendant(
      of: find.byType(ImageFiltered),
      matching: find.byWidgetPredicate((widget) => widget is Image &&
        widget.image is NetworkImage &&
        (widget.image as NetworkImage).url == cover.replaceAll('{size}', '480')),
    ), findsOneWidget);
    expect(calls.where((uri) => uri.host == 'krcs.kugou.com'), hasLength(1));
    expect(calls.where((uri) => uri.path == '/kmr/v2/albums'), hasLength(1));
  });

  testWidgets('歌曲列表用专辑编号补查缺少的封面', (tester) async {
    await mount(tester, TargetPlatform.linux, const Size(1280, 760),
      respond: (request) => request.url.path == '/everyday_song_recommend' ? {
        'status': 1,
        'data': {'info': [{'name': '缺图的列表歌曲', 'hash': 'A3', 'album_id': 5678}]},
      } : null,
    );
    await tester.tap(viewAll('每日推荐'));
    await tester.pumpAndSettle();
    expect(find.text('缺图的列表歌曲'), findsOneWidget);
    expect(find.byWidgetPredicate((widget) => widget is Image &&
        widget.image is NetworkImage &&
        (widget.image as NetworkImage).url == cover.replaceAll('{size}', '150')),
      findsOneWidget,
    );
  });

  testWidgets('Linux 长歌曲列表保留已查到的封面并补齐下一页', (tester) async {
    final requestedAlbums = <int>[];
    final client = KugouClient(KugouDevice.generate(), client: MockClient((request) async {
      expectSync(request.url.path, '/kmr/v2/albums');
      final ids = [
        for (final row in jsonDecode(request.body)['data'] as List) row['album_id'] as int,
      ];
      requestedAlbums.addAll(ids);
      return http.Response(jsonEncode({
        'status': 1,
        'data': [
          for (final id in ids)
            {'album_id': id, 'sizable_cover': 'https://example.org/{size}/$id.jpg'},
        ],
      }), 200);
    }));
    final account = Account(client: client);
    final store = SessionStore(':memory:');
    final library = MusicLibrary(account);
    addTearDown(store.close);
    addTearDown(account.dispose);
    addTearDown(library.dispose);

    // 超过全局封面缓存容量，第一批仍须留在本次列表里。
    const firstPageSize = 401;
    final songs = [
      for (var id = 1; id <= firstPageSize + 1; id++)
        Song(hash: 'A$id', title: '歌曲 $id', albumId: id),
    ];
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(platform: TargetPlatform.linux),
      home: SongListPage(
        title: '长歌单', library: library, player: Playback(store),
        loader: () async => songs.take(firstPageSize).toList(),
        loadMore: () async => songs,
      ),
    ));
    await tester.pumpAndSettle();

    void expectCover(int id) {
      final row = find.ancestor(of: find.text('歌曲 $id'), matching: find.byType(ListTile));
      final image = find.descendant(of: row, matching: find.byType(Image));
      expect((tester.widget<Image>(image).image as NetworkImage).url, 'https://example.org/150/$id.jpg');
    }

    expectCover(1);
    final scroll = tester.state<ScrollableState>(find.byType(Scrollable)).position;
    scroll.jumpTo(scroll.maxScrollExtent);
    await tester.pumpAndSettle();
    scroll.jumpTo(scroll.maxScrollExtent);
    await tester.pumpAndSettle();
    expectCover(firstPageSize + 1);
    scroll.jumpTo(0);
    await tester.pumpAndSettle();
    expectCover(1);
    expect(requestedAlbums, unorderedEquals(songs.map((song) => song.albumId)));
  });

  testWidgets('音乐云盘提示登录失效，重试成功后在右侧显示文件', (tester) async {
    var loads = 0;
    await mount(
      tester, TargetPlatform.linux, const Size(1280, 760),
      session: const KugouSession(userid: 47, token: 'test-token', nickname: '测试账号', avatar: ''),
      respond: (request) {
        if (request.url.host != 'mcloudservice.kugou.com' || request.url.path != '/v1/get_list') {
          return null;
        }
        if (++loads == 1) return {'status': 0, 'error_code': 20017};
        return {
          'list': [{'hash': 'ABCD', 'filename': '歌手 - 云盘测试歌曲.flac', 'kv_id': 81}],
          'list_count': 1,
        };
      },
    );
    await tester.tap(find.text('音乐云盘'));
    await tester.pumpAndSettle();
    expect(find.text('酷狗登录已失效，请重新登录后访问音乐云盘。'), findsOneWidget);
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.text('云盘测试歌曲'), findsOneWidget);
    expect(find.byTooltip('移除云盘文件'), findsOneWidget);
    expect(find.byType(DesktopPlayerBar), findsOneWidget);
    expect(loads, 2);
  });

  testWidgets('侧栏切换与右侧详情返回时，侧栏和播放栏一直可用', (tester) async {
    await mount(tester, TargetPlatform.linux, const Size(1280, 760));
    final discover = find.byTooltip('发现');
    final sidebarPosition = tester.getCenter(discover);
    void expectWorkspace() {
      expect(tester.getCenter(discover), sidebarPosition);
      expect(find.byType(DesktopPlayerBar), findsOneWidget);
      expect(find.byType(BackButton), findsNothing);
      expect(find.byType(WorkspaceHeading), findsOneWidget);
    }

    await tester.tap(find.text('最近播放'));
    await tester.pumpAndSettle();
    expect(find.text('还没有播放记录。'), findsOneWidget);
    expectWorkspace();
    await tester.tap(find.byTooltip('听歌统计'));
    await tester.pumpAndSettle();
    expect(find.text('听歌统计'), findsOneWidget);
    expect(tester.getTopLeft(find.text('听歌统计')).dx, greaterThan(sidebarPosition.dx));
    expectWorkspace();

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('还没有播放记录。'), findsOneWidget);
    await tester.tap(find.byTooltip('听歌统计'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('免费听'), findsNothing);
    await tester.tap(find.byTooltip('私人 FM'));
    await tester.pumpAndSettle();
    expect(find.byType(SongListPage), findsOneWidget);
    expect(find.text('还没有播放记录。'), findsNothing);
    expect(find.text('听歌统计'), findsNothing);
    expect(desktopSearch, findsNothing);
    expectWorkspace();

    await tester.tap(find.byTooltip('排行榜'));
    await tester.pumpAndSettle();
    expect(find.byType(RankingsPage), findsOneWidget);
    expectWorkspace();

    await tester.tap(find.byTooltip('搜索'));
    await tester.pumpAndSettle();
    await tester.enterText(desktopSearch, '晴天');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(find.text('搜索命中的歌曲'), findsOneWidget);
    expect(find.byType(SongListPage), findsNothing);
    expectWorkspace();

    await tester.tap(find.text('登录酷狗'));
    await tester.pumpAndSettle();
    expect(find.text('登录酷狗账号'), findsOneWidget);
    expect(desktopSearch, findsNothing);
    expectWorkspace();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('搜索命中的歌曲'), findsOneWidget);
    expect(desktopSearch, findsOneWidget);
    expectWorkspace();

    await tester.tap(find.text('我的歌单'));
    await tester.pumpAndSettle();
    expect(find.byType(MyPlaylistsPage), findsOneWidget);
    expectWorkspace();
  });

  testWidgets('Linux 窄窗口仍提供桌面侧栏与播放工具', (tester) async {
    const title = '窄窗口也能显示较长的歌曲名称';
    await mount(
      tester, TargetPlatform.linux, const Size(640, 560),
      initialTrack: Track(
        id: 'kg:A1', title: title, artist: '测试歌手',
        source: Uri.parse('https://example.org/test.mp3'), lyrics: '[00:00.00]歌词',
      ),
    );
    expect(find.byType(DesktopWorkspace), findsOneWidget);
    expect(find.byTooltip('打开播放队列'), findsOneWidget);
    expectPlaybackBarOrder(tester, title);
    await tester.tap(find.byTooltip('更多播放选项'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('音量'));
    await tester.pumpAndSettle();
    expect(find.text('播放器音量'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('桌面三点菜单的图标和文字对齐，歌词勾选后不偏移', (tester) async {
    const desktopChannel = MethodChannel('dev.easymusic.easy_music/desktop');
    final messenger = tester.binding.defaultBinaryMessenger;
    final changes = <Object?>[];
    messenger.setMockMethodCallHandler(desktopChannel, (call) async {
      if (call.method == 'lyricsVisible') changes.add(call.arguments);
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(desktopChannel, null));
    await mount(tester, TargetPlatform.linux, const Size(1280, 760));

    final mini = find.text('迷你播放器');
    final lyrics = find.text('桌面歌词');
    final menu = find.byTooltip('桌面播放');
    await tester.tap(menu);
    await tester.pumpAndSettle();
    final labelLeft = tester.getTopLeft(mini).dx;
    expect(tester.getTopLeft(lyrics).dx, labelLeft);
    final miniIcon = find.byIcon(Icons.picture_in_picture_alt_outlined);
    final lyricsIcon = find.descendant(
      of: find.ancestor(of: lyrics, matching: find.byType(Row)).first,
      matching: find.byIcon(Icons.lyrics_outlined),
    );
    expect(tester.getCenter(miniIcon).dx, tester.getCenter(lyricsIcon).dx);
    expect(find.byIcon(Icons.check_rounded), findsNothing);

    await tester.tap(lyrics);
    await tester.pumpAndSettle();
    expect(changes, [true]);
    await tester.tap(menu);
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(mini).dx, labelLeft);
    expect(tester.getTopLeft(lyrics).dx, labelLeft);
    expect(find.byIcon(Icons.check_rounded), findsOneWidget);
  });

  testWidgets('红心收藏同步到「我喜欢」，在歌单取消收藏后播放器也更新', (tester) async {
    bool stored = false;
    bool rejectAdd = true;
    final writes = <String>[];
    await mount(
      tester, TargetPlatform.linux, const Size(1280, 760),
      session: const KugouSession(userid: 47, token: 'test-token', nickname: '账号', avatar: ''),
      initialTrack: Track(
        id: 'kg:A1', title: '推荐歌曲甲', albumAudioId: 1,
        source: Uri.parse('https://example.org/test.mp3'), lyrics: '[00:00.00]歌词',
      ),
      respond: (request) {
        final path = request.url.path;
        if (path == '/v7/get_all_list') {
          return {
            'status': 1,
            'data': {'info': [{'listid': 8, 'name': '我喜欢', 'is_def': 1}]},
          };
        }
        if (path == '/v4/get_list_all_file_v3') {
          return {
            'status': 1,
            'data': {'info': [
              if (stored) {'name': '推荐歌曲甲', 'hash': 'A1', 'mixsongid': 1, 'fileid': 55},
            ]},
          };
        }
        if (path == '/cloudlist.service/v6/add_song') {
          if (rejectAdd) return {'status': 0, 'message': '收藏写入失败'};
          final row = (jsonDecode(request.body)['data'] as List).single as Map;
          expect(row['mixsongid'], 1);
          writes.add('add');
          stored = true;
          return {'status': 1};
        }
        if (path == '/v4/delete_songs') {
          final row = (jsonDecode(request.body)['data'] as List).single as Map;
          expect(row['fileid'], 55);
          writes.add('remove');
          stored = false;
          return {'status': 1};
        }
        return null;
      },
    );
    Finder playerHeart(String label) => find.descendant(
      of: find.byType(DesktopPlayerBar), matching: find.byTooltip(label),
    );

    await tester.tap(playerHeart('收藏歌曲'));
    await tester.pumpAndSettle();
    final toast = find.byKey(const ValueKey('music-toast'));
    expect(find.textContaining('收藏写入失败'), findsOneWidget);
    expect(tester.getCenter(toast), const Offset(640, 380));
    expect(playerHeart('收藏歌曲'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(toast, findsNothing);
    rejectAdd = false;
    await tester.tap(playerHeart('收藏歌曲'));
    await tester.pumpAndSettle();
    expect(toast, findsNothing);
    expect(playerHeart('取消收藏'), findsOneWidget);
    expect(find.byTooltip('取消收藏'), findsNWidgets(2));

    await tester.tap(find.text('我喜欢').first);
    await tester.pumpAndSettle();
    final list = find.byType(SongListPage);
    expect(find.descendant(of: list, matching: find.text('推荐歌曲甲')), findsOneWidget);
    expect(playerHeart('取消收藏'), findsOneWidget);
    await tester.tap(find.descendant(of: list, matching: find.byTooltip('取消收藏')));
    await tester.pumpAndSettle();
    expect(toast, findsNothing);
    expect(find.text('这个列表里还没有歌曲。'), findsOneWidget);
    await tester.tap(find.byTooltip('发现'));
    await tester.pumpAndSettle();
    expect(playerHeart('收藏歌曲'), findsOneWidget);
    expect(writes, ['add', 'remove']);
  });

  testWidgets('Android 切回发现保留数据和滚动位置，回前台也不刷新', (tester) async {
    final requests = <Uri>[];
    const dailyRoute = '/everyday_song_recommend';
    const playlistsRoute = '/v2/special_recommend';
    const fmRoute = '/v2/personal_recommend';
    const rankRoute = '/ocean/v6/rank/list';
    int calls(String route) => requests.where((url) => url.path == route).length;
    var callsWhileInitializing = -1;
    await mount(
      tester, TargetPlatform.android, const Size(390, 760),
      requests: requests,
      accountFactory: (client) {
        final account = _InitializingAccount(client);
        Future<void>.delayed(const Duration(milliseconds: 500), () {
          callsWhileInitializing = calls(dailyRoute) + calls(playlistsRoute) + calls(rankRoute);
          account.finishInitializing();
        });
        return account;
      },
      respond: (request) => request.url.path != dailyRoute ? null : {
        'status': 1,
        'data': {'info': [
          for (var index = 1; index <= 18; index++)
            {'hash': 'A$index', 'name': '推荐歌曲$index', 'mixsongid': index, 'cover': cover},
        ]},
      },
    );
    expect(callsWhileInitializing, 0);
    expect(calls(dailyRoute), 1);
    expect(calls(playlistsRoute), 1);
    expect(calls(fmRoute), 0);
    expect(calls(rankRoute), 0);
    expect(find.text('排行榜'), findsNothing);
    expect(find.text('登录酷狗后可查看私人 FM 推荐。'), findsOneWidget);
    final playAll = tester.widget<IconButton>(find.byWidgetPredicate(
      (widget) => widget is IconButton && widget.tooltip == '全部播放',
    ));
    expect((playAll.icon as Icon).icon, Icons.play_circle_outline_rounded);
    final first = tester.getCenter(find.text('推荐歌曲1'));
    final second = tester.getCenter(find.text('推荐歌曲2'));
    expect(first.dy, second.dy);
    expect(first.dx, lessThan(second.dx));

    final discover = find.byType(DiscoverPage);
    final list = find.descendant(
      of: find.byKey(const PageStorageKey('每日推荐')), matching: find.byType(Scrollable),
    );
    double offset() => tester.state<ScrollableState>(list).position.pixels;
    await tester.drag(list, const Offset(-320, 0));
    await tester.pumpAndSettle();
    final savedOffset = offset();
    expect(savedOffset, greaterThan(0));

    for (final label in ['搜索', '我的', '队列']) {
      await tester.tap(find.widgetWithText(NavigationDestination, label));
      await tester.pumpAndSettle();
      expect(discover, findsNothing);
      await tester.tap(find.widgetWithText(NavigationDestination, '发现'));
      await tester.pump();
      expect(find.descendant(of: discover, matching: find.byType(LinearProgressIndicator)), findsNothing);
      await tester.pumpAndSettle();
      expect(discover, findsOneWidget);
      expect(offset(), closeTo(savedOffset, 0.01));
    }
    expect(calls(dailyRoute), 1);
    expect(calls(playlistsRoute), 1);

    for (final state in [
      AppLifecycleState.inactive, AppLifecycleState.hidden, AppLifecycleState.paused,
      AppLifecycleState.hidden, AppLifecycleState.inactive, AppLifecycleState.resumed,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
    await tester.pumpAndSettle();
    expect(calls(dailyRoute), 1);
    expect(calls(playlistsRoute), 1);
    expect(calls(fmRoute), 0);
    expect(calls(rankRoute), 0);
    expect(find.descendant(of: discover, matching: find.byType(FavoriteButton)), findsNothing);
    await tester.tap(viewAll('每日推荐'));
    await tester.pumpAndSettle();
    expect(find.byType(SongListPage), findsOneWidget);
    expect(find.descendant(of: find.byType(SongListPage), matching: find.byType(FavoriteButton)), findsNothing);
  });

  testWidgets('Linux 返回发现不刷新，手动刷新只更新每日推荐', (tester) async {
    final requests = <Uri>[];
    const fmRoute = '/v2/personal_recommend';
    const dailyRoute = '/everyday_song_recommend';
    const playlistsRoute = '/v2/special_recommend';
    int calls(String route) => requests.where((url) => url.path == route).length;
    final store = SessionStore(':memory:');
    addTearDown(store.close);
    await mount(tester, TargetPlatform.linux, const Size(1000, 540),
      requests: requests, preferences: store, emptyQueue: true,
      session: const KugouSession(userid: 47, token: 'desktop-fm', nickname: '测试账号', avatar: ''),
      respond: (request) {
        if (request.url.path != fmRoute) return null;
        final start = (calls(fmRoute) - 1) * 10 + 1;
        return {'status': 1, 'data': {'song_list': [
          for (var id = start; id < start + 10 && id <= 40; id++)
            {'FileHash': 'DM$id', 'SongName': '桌面 FM $id', 'Audioid': id},
        ]}};
      },
    );
    expect(find.byTooltip('外观设置'), findsNothing);
    expect(find.text('桌面 FM 1'), findsOneWidget);
    final discover = find.byType(DiscoverPage);
    final discoverState = tester.state(discover);

    await tester.tap(find.byTooltip('搜索'));
    await tester.pumpAndSettle();
    expect(discover, findsNothing);
    await tester.tap(find.byTooltip('发现'));
    await tester.pump();
    expect(find.descendant(of: discover, matching: find.byType(LinearProgressIndicator)), findsNothing);
    await tester.pumpAndSettle();
    expect(tester.state(discover), same(discoverState));

    await tester.tap(find.text('我的'));
    await tester.pumpAndSettle();
    expect(find.text('签到领 VIP'), findsNothing);
    final settings = find.widgetWithText(ListTile, '设置');
    await tester.ensureVisible(settings);
    await tester.pumpAndSettle();
    await tester.tap(settings);
    await tester.pumpAndSettle();
    expect(find.text('外观'), findsOneWidget);
    await tester.tap(find.byTooltip('发现'));
    await tester.pumpAndSettle();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect([calls(fmRoute), calls(dailyRoute), calls(playlistsRoute)], [1, 1, 1]);
    expect(find.text('桌面 FM 1'), findsOneWidget);

    await tester.tap(find.byTooltip('刷新每日推荐'));
    await tester.pumpAndSettle();
    expect([calls(fmRoute), calls(dailyRoute), calls(playlistsRoute)], [1, 2, 1]);
    expect(find.text('桌面 FM 1'), findsOneWidget);

    await tester.tap(find.byTooltip('私人 FM'));
    await tester.pumpAndSettle();
    final fm = find.byType(SongListPage);
    final scrollable = find.descendant(of: fm, matching: find.byType(Scrollable));
    await tester.scrollUntilVisible(find.text('桌面 FM 11'), 150, scrollable: scrollable);
    await tester.pumpAndSettle();
    expect(find.text('桌面 FM 11').hitTestable(), findsOneWidget);
    expect(calls(fmRoute), 2);
  });

  for (final (platform, size, device) in const [
    (TargetPlatform.android, Size(390, 760), PointerDeviceKind.touch),
    (TargetPlatform.linux, Size(960, 760), PointerDeviceKind.mouse),
  ]) {
    testWidgets('${platform.name} 发现页推荐歌单可以横向滑动并打开', (tester) async {
      final requests = <Uri>[];
      await mount(tester, platform, size, requests: requests, respond: (request) {
        if (request.url.path != '/v2/special_recommend') return null;
        final category = (jsonDecode(request.body) as Map)['special_recommend']['categoryid'];
        return {
          'status': 1,
          'data': {'special_list': [
            if (category == 11292)
              {'gid': 'hires-test', 'name': 'Hi-Res 测试歌单'}
            else
              for (var index = 1; index <= 12; index++)
                {'gid': 'test-playlist-$index', 'name': '测试歌单 $index'},
          ]},
        };
      });
      expect(find.text('免费听'), findsNothing);
      final horizontal = find.byWidgetPredicate((widget) =>
        widget is Scrollable && axisDirectionToAxis(widget.axisDirection) == Axis.horizontal,
      );
      final carousel = find.descendant(
        of: find.byKey(const PageStorageKey('recommended-playlists')), matching: horizontal,
      );
      await tester.ensureVisible(find.text('测试歌单 1'));
      await tester.pumpAndSettle();
      final scroll = tester.state<ScrollableState>(carousel).position;
      expect(find.text('测试歌单 1').hitTestable(), findsOneWidget);
      expect(find.text('测试歌单 3').hitTestable(), findsOneWidget);
      final isDesktop = platform == TargetPlatform.linux;
      if (isDesktop) expect(find.text('测试歌单 4').hitTestable(), findsOneWidget);
      final stacked = find.text(isDesktop ? '测试歌单 5' : '测试歌单 4');
      expect(stacked.hitTestable(), findsNothing);
      final covers = find.descendant(of: carousel, matching: find.byType(Cover));
      final stride = tester.widget<Cover>(covers.first).size! + 12;
      Finder unfoldingCover() => find.descendant(
        of: find.ancestor(of: stacked, matching: find.byType(InkWell)).first,
        matching: find.byType(Cover),
      );
      scroll.jumpTo(stride - 2);
      await tester.pumpAndSettle();
      final before = tester.getTopLeft(unfoldingCover()).dx;
      final reusedCover = tester.widget<Cover>(unfoldingCover());
      scroll.jumpTo(stride);
      await tester.pumpAndSettle();
      final flat = tester.getTopLeft(unfoldingCover()).dx;
      scroll.jumpTo(stride + 2);
      await tester.pumpAndSettle();
      final after = tester.getTopLeft(unfoldingCover()).dx;
      // 平铺前后的两段位移接近，且过渡期间继续使用同一个封面组件。
      expect(before - flat, closeTo(flat - after, 0.25));
      expect(tester.widget<Cover>(unfoldingCover()), same(reusedCover));
      scroll.jumpTo(0);
      await tester.pumpAndSettle();

      if (isDesktop) {
        tester.view.physicalSize = const Size(1480, 760);
        await tester.pumpAndSettle();
        expect(find.text('测试歌单 7').hitTestable(), findsOneWidget);
        expect(find.text('测试歌单 8').hitTestable(), findsNothing);

        scroll.jumpTo(scroll.maxScrollExtent);
        await tester.pumpAndSettle();
        expect(find.text('测试歌单 12').hitTestable(), findsOneWidget);

        // 全部放得下时直接平铺，窗口缩回后恢复堆叠。
        tester.view.physicalSize = const Size(2300, 760);
        await tester.pumpAndSettle();
        expect(scroll.maxScrollExtent, 0);
        expect(scroll.pixels, 0);
        expect(find.text('测试歌单 1').hitTestable(), findsOneWidget);
        expect(find.text('测试歌单 12').hitTestable(), findsOneWidget);

        tester.view.physicalSize = size;
        await tester.pumpAndSettle();
        expect(find.text('测试歌单 4').hitTestable(), findsOneWidget);
        expect(stacked.hitTestable(), findsNothing);
      }

      await tester.drag(carousel, const Offset(-270, 0), kind: device);
      await tester.pumpAndSettle();
      expect(scroll.pixels, greaterThan(0));
      expect(find.text('测试歌单 1').hitTestable(), findsNothing);
      await tester.tap(find.text('测试歌单 4').hitTestable());
      await tester.pumpAndSettle();
      expect(find.widgetWithText(SongListPage, '测试歌单 4'), findsOneWidget);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await tester.ensureVisible(viewAll('推荐歌单'));
      await tester.pumpAndSettle();
      expect(tester.widget<IconButton>(viewAll('推荐歌单')).icon,
        isA<Icon>().having((icon) => icon.icon, 'icon', Icons.chevron_right_rounded),
      );
      await tester.tap(viewAll('推荐歌单'));
      await tester.pumpAndSettle();
      final recommendedPage = find.byType(RecommendedPlaylistsPage);
      expect(find.descendant(of: recommendedPage, matching: horizontal), findsNothing);
      final firstTile = find.widgetWithText(ListTile, '测试歌单 1');
      final secondTile = find.widgetWithText(ListTile, '测试歌单 2');
      expect(tester.getTopLeft(firstTile).dx, tester.getTopLeft(secondTile).dx);
      expect(tester.getTopLeft(firstTile).dy, lessThan(tester.getTopLeft(secondTile).dy));
      expect(requests.where((url) => url.path == '/v2/special_recommend'), hasLength(1));
      await tester.tap(find.widgetWithText(ChoiceChip, 'Hi-Res'));
      await tester.pumpAndSettle();
      expect(find.text('Hi-Res 测试歌单').hitTestable(), findsOneWidget);
    });
  }

  testWidgets('Android 窄屏同时显示封面和可滚动歌词，底部播放控件固定', (tester) async {
    const title = '队列测试歌曲';
    const artist = '测试歌手';
    const firstLine = '第 1 行歌词';
    await mount(tester, TargetPlatform.android, const Size(390, 760),
      initialTrack: Track(
        id: 'kg:A1', title: title, artist: artist,
        source: Uri.parse('https://example.org/test.mp3'),
        artUri: Uri.parse('https://example.org/test-cover.png'),
        lyrics: List.generate(24, (index) =>
          '[00:${index.toString().padLeft(2, '0')}.00]第 ${index + 1} 行歌词',
        ).join('\n'),
      ),
    );
    tester.view.padding = const FakeViewPadding(top: 24, bottom: 24);
    addTearDown(tester.view.resetPadding);
    final page = find.byType(NowPlayingPage);
    final back = find.byTooltip('返回播放器');
    await tester.tap(find.text(title));
    await tester.pumpAndSettle();
    expect(page, findsOneWidget);
    expect(tester.getRect(page), const Rect.fromLTWH(0, 0, 390, 760));
    expect(find.byType(BottomSheet), findsNothing);
    expect(find.byType(NavigationBar), findsNothing);
    expect(tester.getTopLeft(back).dy, greaterThanOrEqualTo(24));
    final artwork = find.byKey(const ValueKey('now-playing-artwork'));
    expect(artwork, findsOneWidget);
    final artworkRect = tester.getRect(artwork);
    expect(artworkRect.size, const Size.square(312));
    expect(artworkRect.center.dx, 195);
    final activeLine = find.text(firstLine);
    final inactiveLine = find.text('第 2 行歌词');
    final platform = tester.binding.platformDispatcher;
    addTearDown(platform.clearPlatformBrightnessTestValue);
    final systemBars = find.descendant(
      of: page,
      matching: find.byType(AnnotatedRegion<SystemUiOverlayStyle>),
    );
    SystemUiOverlayStyle barStyle() =>
        tester.widget<AnnotatedRegion<SystemUiOverlayStyle>>(systemBars).value;
    expect(tester.widget<Text>(activeLine).style?.color, isNot(Colors.white));
    expect(barStyle().statusBarIconBrightness, Brightness.dark);
    platform.platformBrightnessTestValue = Brightness.dark;
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(activeLine).style?.color, Colors.white);
    expect(barStyle().statusBarIconBrightness, Brightness.light);
    platform.clearPlatformBrightnessTestValue();
    await tester.pumpAndSettle();
    final activeSize = tester.widget<Text>(activeLine).style!.fontSize!;
    final inactiveSize = tester.widget<Text>(inactiveLine).style!.fontSize!;
    expect(inactiveSize, lessThan(activeSize));
    expect(tester.widget<Text>(activeLine).textAlign, TextAlign.center);
    expect(tester.getCenter(activeLine).dx, closeTo(195, 1));
    expect(tester.getCenter(activeLine).dy,
      closeTo(tester.getCenter(find.byType(CustomScrollView)).dy, 1),
    );
    expect(find.text('正在播放'), findsNothing);
    expect(find.text('歌词'), findsNothing);
    expect(find.byTooltip('全屏歌词'), findsNothing);
    expect(find.byTooltip('歌词选项'), findsNothing);
    expect(find.byType(PlaybackVolumeControl), findsNothing);

    await tester.tap(artwork);
    await tester.pumpAndSettle();
    expect(page, findsOneWidget);
    expect(artwork, findsNothing);
    expect(find.byTooltip('显示封面'), findsOneWidget);
    final expandedLyricsRect = tester.getRect(find.byType(SyncedLyrics));
    await tester.tap(activeLine);
    await tester.pumpAndSettle();
    expect(artwork.hitTestable(), findsOneWidget);

    final lyrics = find.descendant(
      of: find.byType(SyncedLyrics), matching: find.byType(CustomScrollView),
    );
    final controls = find.byType(PlayerControls);
    final lyricsRect = tester.getRect(lyrics);
    final controlsRect = tester.getRect(controls);
    final quality = find.byTooltip('首选音质');
    final favorite = find.byTooltip('收藏歌曲');
    final speed = find.byTooltip('播放速度');
    final qualityRect = tester.getRect(quality);
    final favoriteRect = tester.getRect(favorite);
    final titleRect = tester.getRect(find.text(title));
    final artistRect = tester.getRect(find.text(artist));
    expect(tester.getTopLeft(artwork).dy, lessThan(110));
    expect(titleRect.center.dy, closeTo(tester.getCenter(back).dy, 1));
    expect(artistRect.center.dy, closeTo(titleRect.center.dy, 1));
    expect(artistRect.left, greaterThan(titleRect.right));
    expect(titleRect.bottom, lessThan(tester.getTopLeft(artwork).dy));
    expect(lyricsRect.height, greaterThanOrEqualTo(64));
    expect(tester.getBottomLeft(find.text(firstLine)).dy, lessThan(lyricsRect.bottom));
    expect(lyricsRect.bottom, lessThanOrEqualTo(controlsRect.top));
    expect(qualityRect.top, greaterThanOrEqualTo(controlsRect.bottom));
    expect(qualityRect.center.dy, closeTo(favoriteRect.center.dy, 1));
    expect(qualityRect.center.dy, closeTo(tester.getCenter(speed).dy, 1));
    expect(favoriteRect.bottom, lessThanOrEqualTo(760 - 24));
    expect(find.byIcon(Icons.shuffle_rounded), findsNothing);
    expect(find.byTooltip('手动切歌淡入淡出'), findsNothing);
    expect(find.byTooltip('播放').hitTestable(), findsOneWidget);

    for (final (current, next) in const [
      ('顺序播放', '列表循环'),
      ('列表循环', '单曲循环'),
      ('单曲循环', '顺序播放'),
    ]) {
      await tester.tap(find.byTooltip(current));
      await tester.pumpAndSettle();
      expect(find.byTooltip(next), findsOneWidget);
      expect(find.text(next), findsNothing);
    }

    await tester.drag(lyrics, const Offset(0, -160));
    await tester.pumpAndSettle();
    final lyricsScroll = find.descendant(of: lyrics, matching: find.byType(Scrollable));
    expect(tester.state<ScrollableState>(lyricsScroll).position.pixels, greaterThan(0));
    expect(tester.getRect(controls), controlsRect);
    expect(tester.getRect(quality), qualityRect);
    expect(tester.getRect(favorite), favoriteRect);

    await tester.tap(find.byTooltip('展开歌词'));
    await tester.pumpAndSettle();
    expect(artwork, findsNothing);
    expect(tester.getRect(find.byType(SyncedLyrics)), expandedLyricsRect);
    expect(tester.getSize(lyrics).height, greaterThan(lyricsRect.height));
    expect(tester.getRect(controls), controlsRect);
    final expandedScroll = tester.state<ScrollableState>(lyricsScroll).position;
    final expandedOffset = expandedScroll.pixels;
    await tester.drag(lyrics, const Offset(0, -160));
    await tester.pumpAndSettle();
    expect(expandedScroll.pixels, greaterThan(expandedOffset));
    expect(artwork, findsNothing);
    await tester.longPressAt(tester.getCenter(lyrics));
    await tester.pumpAndSettle();
    expect(find.text('更换歌词'), findsOneWidget);
    expect(find.text('全屏歌词'), findsNothing);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('显示封面'));
    await tester.pumpAndSettle();
    expect(artwork, findsOneWidget);

    tester.view.physicalSize = const Size(320, 568);
    await tester.pumpAndSettle();
    final narrowArtwork = tester.getRect(artwork);
    expect(narrowArtwork.size, const Size.square(256));
    expect(narrowArtwork.center.dx, 160);
    expect(tester.getSize(lyrics).height, greaterThanOrEqualTo(64));
    expect(find.byTooltip('播放').hitTestable(), findsNothing);

    await tester.drag(artwork, const Offset(0, -180));
    await tester.pumpAndSettle();
    expect(find.byTooltip('播放').hitTestable(), findsOneWidget);
    expect(find.byTooltip('播放速度').hitTestable(), findsOneWidget);
    expect(tester.getRect(controls).bottom, lessThanOrEqualTo(568 - 24));
    expect(lyrics.hitTestable(), findsOneWidget);
    expect(tester.getRect(lyrics).bottom, lessThanOrEqualTo(tester.getRect(controls).top));
    await tester.longPressAt(tester.getCenter(lyrics));
    await tester.pumpAndSettle();
    expect(find.text('更换歌词').hitTestable(), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    await tester.tap(back);
    await tester.pumpAndSettle();
    expect(page, findsNothing);
    expect(find.byType(NavigationBar), findsOneWidget);
    tester.view.physicalSize = const Size(390, 760);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('歌词'));
    await tester.pumpAndSettle();
    expect(artwork, findsNothing);
    expect(find.text(firstLine), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(page, findsNothing);
    expect(find.byType(NavigationBar), findsOneWidget);
  });

  testWidgets('Android 窄屏无歌词时可导入，更新后直接显示歌词', (tester) async {
    final track = Track(
      id: 'no-lyrics', title: '没有歌词的歌曲',
      source: Uri.parse('https://example.org/test.mp3'),
    );
    final player = await mount(tester, TargetPlatform.android, const Size(320, 568),
      initialTrack: track,
    );
    tester.view.padding = const FakeViewPadding(top: 24, bottom: 24);
    addTearDown(tester.view.resetPadding);
    await tester.tap(find.text(track.title));
    await tester.pumpAndSettle();

    final empty = find.text('还没有歌词');
    final artwork = find.byKey(const ValueKey('now-playing-artwork'));
    expect(empty.hitTestable(), findsOneWidget);
    expect(artwork, findsOneWidget);
    await tester.tap(artwork);
    await tester.pumpAndSettle();
    expect(find.byType(NowPlayingPage), findsOneWidget);
    expect(artwork, findsNothing);
    await tester.tap(empty);
    await tester.pumpAndSettle();
    expect(artwork.hitTestable(), findsOneWidget);
    expect(tester.getBottomLeft(empty).dy, lessThan(tester.getTopLeft(find.byType(PlayerControls)).dy));
    await tester.longPress(empty);
    await tester.pumpAndSettle();
    expect(find.text('导入歌词').hitTestable(), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    await tester.runAsync(() => player.setLyrics(track, '[00:00.00]补上的歌词'));
    await tester.pumpAndSettle();
    expect(empty, findsNothing);
    expect(find.text('补上的歌词').hitTestable(), findsOneWidget);
    await tester.drag(artwork, const Offset(0, -180));
    await tester.pumpAndSettle();
    expect(find.byTooltip('播放').hitTestable(), findsOneWidget);
  });

  testWidgets('播放舞台歌词向上滚到中央，点按歌词不跳转', (tester) async {
    const secondLine = '第二句歌词比较长所以会自动换行';
    final store = SessionStore(':memory:');
    final player = _LyricPlayback(store);
    addTearDown(store.close);
    addTearDown(player.positions.close);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 280,
          height: 220,
          child: SyncedLyrics(
            player: player,
            lines: parseLyrics('[00:00]第一句\n[00:03]$secondLine\n[00:07]第三句'),
            textAlign: TextAlign.start,
            stage: true,
          ),
        ),
      ),
    ));
    final second = find.text(secondLine);
    final third = find.text('第三句');
    final lyrics = find.byType(CustomScrollView);
    final secondStart = tester.getCenter(second).dy;
    final middle = tester.getCenter(lyrics).dy;
    player.setPosition(const Duration(seconds: 3));
    await tester.pump();
    final colors = Theme.of(tester.element(second)).colorScheme;
    expect(tester.widget<Text>(second).style?.color, colors.onSurface);
    expect(tester.getCenter(second).dy, closeTo(secondStart, 1));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 90));
    expect(tester.getCenter(second).dy, inExclusiveRange(middle, secondStart));
    await tester.pumpAndSettle();
    expect(tester.getCenter(second).dy, closeTo(middle, 1));
    expect(tester.widget<Text>(third).style?.color, colors.onSurfaceVariant);
    expect(tester.getSize(second).height, greaterThan(tester.getSize(third).height * 2));
    await tester.tap(third);
    expect(player.lastSeek, isNull);
    expect(player.position, const Duration(seconds: 3));
    player.setPosition(const Duration(seconds: 7));
    await tester.pumpAndSettle();
    expect(tester.getCenter(third).dy, closeTo(tester.getCenter(lyrics).dy, 1));
    player.setPosition(Duration.zero);
    await tester.pumpAndSettle();
    expect(tester.getCenter(find.text('第一句')).dy,
      closeTo(tester.getCenter(lyrics).dy, 1),
    );
  });

  testWidgets('逐字歌词在同一个字的时长内连续推进高亮', (tester) async {
    final store = SessionStore(':memory:');
    final player = _LyricPlayback(store);
    addTearDown(store.close);
    addTearDown(player.positions.close);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: SyncedLyrics(
        player: player,
        lines: parseLyrics('[0,1000]<0,1000,0>春'),
        stage: true,
      )),
    ));

    final painted = find.ancestor(
      of: find.text('春'),
      matching: find.byWidgetPredicate(
        (widget) => widget is CustomPaint &&
            widget.foregroundPainter != null && widget.child is Text,
      ),
    );
    final painter = tester.widget<CustomPaint>(painted).foregroundPainter!;
    double highlightedWidth() {
      final canvas = TestRecordingCanvas();
      painter.paint(canvas, tester.getSize(painted));
      final path = canvas.invocations
          .singleWhere((call) => call.invocation.memberName == #clipPath)
          .invocation.positionalArguments.single as Path;
      return path.getBounds().width;
    }

    expect(highlightedWidth(), 0);
    player.setPosition(const Duration(milliseconds: 250));
    await tester.pump();
    final first = highlightedWidth();
    player.playbackState.add(PlaybackState(
      playing: true, processingState: AudioProcessingState.ready,
    ));
    await tester.pump();
    // 不给进度流发事件，验证绘制能靠帧回调继续推进。
    player.currentPosition = const Duration(milliseconds: 500);
    await tester.pump(const Duration(milliseconds: 16));
    final second = highlightedWidth();
    expect(identical(tester.widget<CustomPaint>(painted).foregroundPainter, painter), isTrue);
    expect(first, greaterThan(0));
    expect(second, closeTo(first * 2, 0.1));
    player.playbackState.add(PlaybackState());
    await tester.pump();
    player.currentPosition = const Duration(milliseconds: 750);
    await tester.pump(const Duration(milliseconds: 16));
    expect(highlightedWidth(), second);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Android 切换到概念版主登录后，同一凭证完成领取和升级', (tester) async {
    final requests = <Uri>[];
    await mount(
      tester, TargetPlatform.android, const Size(390, 760),
      requests: requests,
      session: const KugouSession(userid: 47, token: 'vip-test-token', nickname: '测试账号', avatar: ''),
      respond: (request) => switch (request.url.path) {
        '/v7/login_by_verifycode' => {
          'status': 1, 'data': {'userid': 47, 'token': 'vip-main-lite'},
        },
        '/youth/v1/recharge/receive_vip_listen_song' => {'status': 1, 'error_code': 0},
        '/youth/v1/listen_song/upgrade_vip_reward' => {'status': 1, 'error_code': 0},
        _ => null,
      },
    );
    int claims() => requests.where((url) => url.path == '/youth/v1/recharge/receive_vip_listen_song').length;
    expect(claims(), 0);
    await tester.tap(find.widgetWithText(NavigationDestination, '我的'));
    await tester.pumpAndSettle();
    expect(find.text('签到领 VIP'), findsNothing);
    await tester.tap(find.widgetWithText(ListTile, '测试账号'));
    await tester.pumpAndSettle();
    final switchLogin = find.widgetWithText(TextButton, '切换到概念版登录');
    await tester.tap(switchLogin);
    await tester.pumpAndSettle();
    expect(find.text('切换到概念版登录'), findsOneWidget);
    expect(find.text('获取验证码'), findsOneWidget);
    await tester.enterText(find.byType(TextField).first, '13800138000');
    await tester.enterText(find.byType(TextField).last, '123456');
    await tester.tap(find.widgetWithText(FilledButton, '登录'));
    await tester.pumpAndSettle();
    final login = requests.singleWhere((url) => url.path == '/v7/login_by_verifycode');
    expect(login.queryParameters['appid'], '3116');
    final claim = requests.singleWhere((url) => url.path == '/youth/v1/recharge/receive_vip_listen_song');
    expect(claim.queryParameters['token'], 'vip-main-lite');
    final upgrade = requests.singleWhere((url) => url.path == '/youth/v1/listen_song/upgrade_vip_reward');
    expect(upgrade.queryParameters['token'], 'vip-main-lite');
    expect(find.byType(AccountPage), findsOneWidget);
    expect(switchLogin, findsNothing);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(claims(), 1);
    expect(requests.where((url) => url.path == upgrade.path), hasLength(1));
    expect(find.text('签到领 VIP'), findsNothing);
    expect(find.text('今日畅听 VIP 已领取，概念版 VIP 已升级。'), findsNothing);
  });

  testWidgets('Android 双区玻璃播放条跨标签保留封面旋转状态', (tester) async {
    final player = await mount(tester, TargetPlatform.android, const Size(390, 760));
    final bar = find.byType(MiniPlayerBar);
    final panels = find.descendant(of: bar, matching: find.byType(GlassSurface));
    final record = find.descendant(of: bar, matching: find.byType(Cover));
    final spin = find.descendant(of: bar, matching: find.byType(RotationTransition));
    double angle() => tester.widget<RotationTransition>(spin).turns.value;

    expect(panels, findsNWidgets(2));
    expect(tester.widget<Cover>(record).radius, tester.getSize(record).width / 2);
    expect(tester.getRect(panels.first).contains(tester.getCenter(record)), isTrue);
    expect(tester.getRect(panels.last).contains(tester.getCenter(find.byTooltip('播放'))), isTrue);
    expect(tester.getBottomLeft(bar).dy, lessThanOrEqualTo(
      tester.getTopLeft(find.byType(NavigationBar)).dy,
    ));

    void setPlaying(bool playing) => player.playbackState.add(
      player.playbackState.value.copyWith(
        playing: playing,
        processingState: AudioProcessingState.ready,
      ),
    );
    setPlaying(true);
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(angle(), greaterThan(0));
    for (final tab in ['搜索', '我的', '队列', '发现']) {
      final previous = angle();
      await tester.tap(find.widgetWithText(NavigationDestination, tab));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(angle(), greaterThan(previous));
    }

    setPlaying(false);
    await tester.pump();
    final paused = angle();
    await tester.pump(const Duration(milliseconds: 350));
    expect(angle(), paused);
    setPlaying(true);
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(angle(), greaterThan(paused));

    final dispatcher = tester.binding.platformDispatcher;
    addTearDown(dispatcher.clearAccessibilityFeaturesTestValue);
    dispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(disableAnimations: true);
    await tester.pump();
    final reducedMotion = angle();
    await tester.pump(const Duration(milliseconds: 350));
    expect(angle(), reducedMotion);
    setPlaying(false);
    await tester.pump();
  });

  testWidgets('Android 内容延伸至悬浮栏下，列表末项可以滑出遮挡', (tester) async {
    tester.view.padding = const FakeViewPadding(top: 24, bottom: 26);
    addTearDown(tester.view.resetPadding);
    await mount(tester, TargetPlatform.android, const Size(390, 540),
      session: const KugouSession(userid: 47, token: 'floating-bar-test', nickname: '测试账号', avatar: ''),
    );
    final bar = find.byType(MiniPlayerBar);
    final navigation = find.byType(NavigationBar);
    expect(tester.getRect(find.byType(DiscoverPage)).bottom, 540);
    expect(tester.getBottomLeft(navigation).dy, lessThanOrEqualTo(540 - 26));

    await tester.tap(find.widgetWithText(NavigationDestination, '我的'));
    await tester.pumpAndSettle();
    final list = find.descendant(of: find.byType(MyPage), matching: find.byType(Scrollable));
    final position = tester.state<ScrollableState>(list).position;
    expect(tester.getRect(list).bottom, 540);
    final panes = find.descendant(of: bar, matching: find.byType(GlassSurface));
    final left = tester.getRect(panes.first);
    final right = tester.getRect(panes.last);
    final gap = Offset((left.right + right.left) / 2, left.center.dy);
    await tester.dragFrom(gap, const Offset(0, -150));
    await tester.pumpAndSettle();
    expect(position.pixels, greaterThan(0));
    position.jumpTo(position.maxScrollExtent);
    await tester.pumpAndSettle();

    final last = find.widgetWithText(ListTile, '设置');
    expect(tester.getBottomLeft(last).dy, lessThan(tester.getTopLeft(bar).dy));
    expect(last.hitTestable(), findsOneWidget);
  });

  testWidgets('Android 播放条在底部标签上方，我的歌单是独立菜单', (tester) async {
    tester.view.padding = const FakeViewPadding(top: 24);
    addTearDown(tester.view.resetPadding);
    await mount(tester, TargetPlatform.android, const Size(390, 760),
      session: const KugouSession(userid: 47, token: 'playlist-test', nickname: '测试账号', avatar: ''),
    );
    expect(find.byType(DesktopWorkspace), findsNothing);
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.text('Easy Music'), findsNothing);
    expect(tester.getTopLeft(find.byType(DiscoverPage)).dy, 24);
    for (final tab in ['发现', '搜索', '队列', '我的']) {
      await tester.tap(find.widgetWithText(NavigationDestination, tab));
      await tester.pumpAndSettle();
      expect(find.byType(AppBar), findsNothing);
      expect(find.byTooltip('账号'), findsNothing);
      expect(find.byTooltip('添加音乐'), findsNothing);
    }
    expect(tester.getBottomLeft(find.byTooltip('歌词')).dy,
      lessThanOrEqualTo(tester.getTopLeft(find.byType(NavigationBar)).dy),
    );
    final menu = find.widgetWithText(ListTile, '我的歌单');
    final history = find.widgetWithText(ListTile, '最近播放');
    expect(tester.widget<ListTile>(menu).trailing.runtimeType,
      tester.widget<ListTile>(history).trailing.runtimeType,
    );
    await tester.tap(menu);
    await tester.pumpAndSettle();
    expect(find.byType(MyPlaylistsPage), findsOneWidget);
    expect(find.byTooltip('新建歌单'), findsOneWidget);
  });

  testWidgets('Android 我的喜欢打开收藏列表，取消收藏后刷新', (tester) async {
    var liked = true;
    await mount(
      tester, TargetPlatform.android, const Size(390, 760),
      emptyQueue: true,
      session: const KugouSession(userid: 47, token: 'liked-test', nickname: '测试账号', avatar: ''),
      respond: (request) {
        if (request.url.path == '/v7/get_all_list') {
          return {'status': 1, 'data': {'info': [{'listid': 8, 'name': '我喜欢', 'is_def': 1}]}};
        }
        if (request.url.path == '/v4/get_list_all_file_v3') {
          return {'status': 1, 'data': {'info': [
            if (liked) {'name': '收藏歌曲甲', 'hash': 'A1', 'mixsongid': 1, 'fileid': 55},
          ]}};
        }
        if (request.url.path == '/v4/delete_songs') {
          liked = false;
          return {'status': 1};
        }
        return null;
      },
    );
    await tester.tap(find.widgetWithText(NavigationDestination, '我的'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ListTile, '我的喜欢'));
    await tester.pumpAndSettle();
    expect(find.text('收藏歌曲甲'), findsOneWidget);
    await tester.tap(find.byTooltip('取消收藏'));
    await tester.pumpAndSettle();
    expect(find.text('收藏歌曲甲'), findsNothing);
    expect(find.text('这个列表里还没有歌曲。'), findsOneWidget);
  });

  testWidgets('Android 立即登录和退出自动返回我的，设置沿用已有偏好', (tester) async {
    final directory = Directory.systemTemp.createTempSync('easy-music-settings-test');
    addTearDown(() => directory.deleteSync(recursive: true));
    final path = '${directory.path}/session.sqlite3';
    final store = SessionStore(path);
    addTearDown(store.close);
    final calls = <Uri>[];
    final player = await mount(
      tester, TargetPlatform.android, const Size(390, 760),
      emptyQueue: true, requests: calls, preferences: store,
      respond: (request) => switch (request.url.path) {
        '/v7/send_mobile_code' => {'status': 1},
        '/v7/login_by_verifycode' => {
          'status': 1, 'data': {'userid': 47, 'token': 'login-test', 'nickname': '测试账号'},
        },
        '/youth/v1/recharge/receive_vip_listen_song' || '/youth/v1/listen_song/upgrade_vip_reward' =>
          {'status': 1, 'error_code': 0},
        _ => null,
      },
    );
    await tester.tap(find.widgetWithText(NavigationDestination, '我的'));
    await tester.pumpAndSettle();
    final login = find.widgetWithText(FilledButton, '立即登录');
    void expectSignedOut() {
      expect(find.text('我的喜欢'), findsNothing);
      expect(login.hitTestable(), findsOneWidget);
      final page = find.byType(MyPage);
      final icon = find.descendant(of: page, matching: find.byIcon(Icons.headphones_rounded));
      final visibleCenter = (tester.getTopLeft(page).dy + tester.getTopLeft(find.byType(MiniPlayerBar)).dy) / 2;
      final loginCenter = (tester.getTopLeft(icon).dy + tester.getBottomLeft(login).dy) / 2;
      expect(loginCenter, closeTo(visibleCenter, 1));
    }

    expectSignedOut();
    expect(find.text('设置'), findsNothing);
    expect(find.text('我的歌单'), findsNothing);
    await tester.tap(login);
    await tester.pumpAndSettle();
    expect(find.byType(AccountPage), findsOneWidget);
    await tester.enterText(find.byType(TextField).first, '13800138000');
    await tester.tap(find.text('获取验证码'));
    await tester.pumpAndSettle();
    expect(find.text('验证码已发送，请查看短信。'), findsOneWidget);
    await tester.enterText(find.byType(TextField).last, '123456');
    await tester.tap(find.widgetWithText(FilledButton, '登录'));
    await tester.pumpAndSettle();
    expect(find.byType(AccountPage), findsNothing);
    expect(login, findsNothing);
    expect(find.text('我的喜欢'), findsOneWidget);
    expect(find.text('我的歌单'), findsOneWidget);
    expect(find.text('音乐云盘'), findsOneWidget);
    expect(find.text('已购音乐'), findsOneWidget);
    await tester.tap(find.widgetWithText(ListTile, '设置'));
    await tester.pumpAndSettle();

    final quality = find.widgetWithText(ListTile, '首选音质');
    await tester.tap(quality);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(SimpleDialogOption, '无损'));
    await tester.pumpAndSettle();
    expect(player.preferredQuality.value, AudioQuality.lossless);
    expect(find.descendant(of: quality, matching: find.text('无损')), findsOneWidget);
    expect(calls.where((url) => url.path == '/tracker/v5/url'), isEmpty);

    final fade = find.widgetWithText(ListTile, '播放淡入淡出');
    await tester.tap(fade);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(SimpleDialogOption, '0.5 秒'));
    await tester.pumpAndSettle();
    expect(player.fadeMilliseconds.value, 500);
    expect(find.descendant(of: fade, matching: find.text('0.5 秒')), findsOneWidget);

    final autoVip = find.widgetWithText(SwitchListTile, '自动签到领 VIP');
    expect(tester.widget<SwitchListTile>(autoVip).value, isTrue);
    await tester.tap(autoVip);
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(autoVip).value, isFalse);
    expect(find.text('主题模式'), findsNothing);
    await tester.tap(find.widgetWithText(ListTile, '外观'));
    await tester.pumpAndSettle();
    final systemMode = find.widgetWithText(ChoiceChip, '跟随系统');
    final darkMode = find.widgetWithText(ChoiceChip, '夜间模式');
    expect(tester.widget<ChoiceChip>(systemMode).selected, isTrue);
    await tester.tap(darkMode);
    await tester.pumpAndSettle();
    expect(tester.widget<ChoiceChip>(darkMode).selected, isTrue);
    final reopened = SessionStore(path);
    addTearDown(reopened.close);
    expect(reopened.readSettings().preferredQuality, AudioQuality.lossless);
    expect(reopened.readPreference('manual_fade_ms'), '500');
    final restoredAppearance = Appearance(reopened);
    addTearDown(restoredAppearance.dispose);
    expect(restoredAppearance.value.mode, ThemeMode.dark);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ListTile, '关于'));
    await tester.pumpAndSettle();
    expect(find.byType(AboutDialog), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('自动签到已关闭。'), findsNothing);

    await tester.tap(find.widgetWithText(ListTile, '测试账号'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(OutlinedButton, '退出登录'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, '退出登录'));
    await tester.pumpAndSettle();
    expect(find.byType(AccountPage), findsNothing);
    expectSignedOut();
    expect(find.text('设置'), findsNothing);
  });

  testWidgets('Android 开启自动签到时执行一次，失败后设置仍可使用', (tester) async {
    const session = KugouSession(userid: 47, token: 'vip-test', nickname: '测试账号', avatar: '', lite: true);
    FlutterSecureStorage.setMockInitialValues({
      'kugou_session': jsonEncode(session.toJson()), 'auto_daily_vip': 'false',
    });
    final calls = <Uri>[];
    const claim = '/youth/v1/recharge/receive_vip_listen_song';
    await mount(tester, TargetPlatform.android, const Size(390, 760),
      emptyQueue: true, requests: calls,
      respond: (request) => request.url.path == claim
          ? {'status': 0, 'error_msg': '测试签到失败'}
          : null,
    );
    int claims() => calls.where((url) => url.path == claim).length;
    expect(claims(), 0);
    await tester.tap(find.widgetWithText(NavigationDestination, '我的'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ListTile, '设置'));
    await tester.pumpAndSettle();
    final autoVip = find.widgetWithText(SwitchListTile, '自动签到领 VIP');
    expect(tester.widget<SwitchListTile>(autoVip).value, isFalse);
    await tester.tap(autoVip);
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(autoVip).value, isTrue);
    expect(claims(), 1);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(claims(), 1);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('测试签到失败'), findsNothing);
    expect(find.widgetWithText(ListTile, '设置').hitTestable(), findsOneWidget);
  });

  testWidgets('Android 私人 FM 左滑自动追加，加载图标居中，失败可重试', (tester) async {
    var batches = 0;
    final pendingBatch = Completer<void>();
    final requests = <Uri>[];
    await mount(tester, TargetPlatform.android, const Size(390, 760),
      emptyQueue: true, requests: requests,
      session: const KugouSession(userid: 47, token: 'fm-test', nickname: '测试账号', avatar: ''),
      respond: (request) {
        if (request.url.path != '/v2/personal_recommend') return null;
        final ids = switch (++batches) {
          1 => [1, 2, 3, 4, 5],
          2 => [6, 7, 8, 9, 10],
          3 => null,
          4 => [10, 11, 12, 13, 14, 15],
          5 => [16, 17, 18, 19, 20],
          _ => [20],
        };
        if (ids == null) return pendingBatch.future.then((_) => {'status': 0});
        return {
          'status': 1,
          'data': {'song_list': [
            for (final id in ids)
              {'FileHash': 'FM$id', 'SongName': '私人推荐$id', 'Audioid': id},
          ]},
        };
      },
    );
    final row = find.byKey(const PageStorageKey('私人 FM'));
    final scroll = find.descendant(of: row, matching: find.byType(Scrollable));
    expect(tester.getTopLeft(discoverHeading('私人 FM')).dy,
      lessThan(tester.getTopLeft(row).dy),
    );
    expect(tester.getTopLeft(row).dy, lessThan(tester.getTopLeft(discoverHeading('每日推荐')).dy));
    expect(tester.getTopLeft(discoverHeading('每日推荐')).dy,
      lessThan(tester.getTopLeft(discoverHeading('推荐歌单')).dy),
    );
    expect(find.descendant(of: row, matching: find.byType(Cover)), findsWidgets);
    expect(find.descendant(of: row, matching: find.byType(FavoriteButton)), findsNothing);
    expect(find.text('私人推荐1').hitTestable(), findsOneWidget);
    expect(batches, 2);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    unawaited(tester.state<RefreshIndicatorState>(find.byType(RefreshIndicator)).show());
    await tester.pumpAndSettle();
    expect(batches, 2);
    expect(requests.where((url) => url.path == '/v2/personal_recommend'), hasLength(2));
    expect(requests.where((url) => url.path == '/v2/special_recommend'), hasLength(1));
    expect(requests.where((url) => url.path == '/everyday_song_recommend'), hasLength(2));

    await tester.drag(row, const Offset(-120, 0));
    await tester.pumpAndSettle();
    expect(batches, 2);

    // 暂停第二页响应，滑到尾项完全展开后检查加载图标的位置。
    final position = tester.state<ScrollableState>(scroll).position;
    position.jumpTo(position.maxScrollExtent);
    await tester.pump();
    expect(batches, 3);
    position.jumpTo(position.maxScrollExtent);
    await tester.pump();
    final spinner = find.byWidgetPredicate((widget) =>
      widget is CircularProgressIndicator && widget.semanticsLabel == '正在加载私人 FM',
    );
    final lastCover = find.descendant(
      of: find.ancestor(of: find.text('私人推荐10'), matching: find.byType(InkWell)).first,
      matching: find.byType(Cover),
    );
    final coverCenter = tester.getCenter(lastCover);
    final expectedCenter = coverCenter + Offset(tester.getSize(lastCover).width + 12, 0);
    expect(tester.getCenter(spinner).dy, closeTo(expectedCenter.dy, 0.01));
    expect(tester.getCenter(spinner).dx, closeTo(expectedCenter.dx, 0.01));

    pendingBatch.complete();
    await tester.pumpAndSettle();
    final retry = find.descendant(of: row, matching: find.widgetWithText(TextButton, '重试'));
    expect(tester.getCenter(retry).dy, closeTo(expectedCenter.dy, 0.01));
    expect(batches, 3);
    expect(find.text('私人推荐10').hitTestable(), findsOneWidget);
    await tester.tap(retry);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('私人推荐11'), 150, scrollable: scroll);
    expect(batches, 5);
    expect(find.text('私人推荐10'), findsOneWidget);
    expect(find.text('私人推荐11').hitTestable(), findsOneWidget);

    await tester.scrollUntilVisible(find.text('私人推荐20'), 240, scrollable: scroll);
    await tester.pumpAndSettle();
    await tester.drag(row, const Offset(-150, 0));
    await tester.pumpAndSettle();
    expect(batches, 8);
    await tester.drag(row, const Offset(-150, 0));
    await tester.pumpAndSettle();
    expect(batches, 8);
    await tester.ensureVisible(viewAll('私人 FM'));
    await tester.pumpAndSettle();
    await tester.tap(viewAll('私人 FM'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(AppBar, '私人 FM'), findsOneWidget);
    expect(find.descendant(of: find.byType(SongListPage), matching: find.byType(FavoriteButton)), findsNothing);
    expect(batches, 8);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('私人推荐20').hitTestable(), findsOneWidget);
  });
}

class _LyricPlayback extends Playback {
  _LyricPlayback(super.store);

  final positions = StreamController<Duration>.broadcast(sync: true);
  Duration currentPosition = Duration.zero;
  Duration? lastSeek;

  @override
  Duration get position => currentPosition;

  void setPosition(Duration position) {
    currentPosition = position;
    positions.add(position);
  }

  @override
  Stream<Duration> get positionStream => positions.stream;

  @override
  Future<void> seek(Duration position) async => lastSeek = position;
}

/// 模拟 Android 冷启动时本机凭证与请求客户端尚未准备好。
class _InitializingAccount extends Account {
  _InitializingAccount(KugouClient client) : super(client: client);

  bool _ready = false;

  @override
  bool get loading => !_ready || super.loading;

  @override
  KugouClient? get client => _ready ? super.client : null;

  void finishInitializing() {
    _ready = true;
    notifyListeners();
  }
}

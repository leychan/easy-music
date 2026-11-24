import 'dart:convert';

import 'package:easy_music/account/kugou/kugou_client.dart';
import 'package:easy_music/account/kugou/kugou_auth.dart';
import 'package:easy_music/account/kugou/kugou_device.dart';
import 'package:easy_music/account/kugou/signature.dart';
import 'package:easy_music/music/kugou_music_api.dart';
import 'package:easy_music/music/song.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 酷狗音乐库接口的契约测试。
///
/// 这些测试不联网：用 mock 传输层断言我们发出的请求形状（参数、请求头、
/// 签名），以及各种层级的响应能否解析出用户需要的数据。真实联通性另有
/// 联网用例（KUGOU_NET=1），这里只锁住「请求本身是否按酷狗要求组装」。
void main() {
  final device = KugouDevice(guid: 'g-1', mac: 'AA:BB:CC:DD:EE:FF');

  /// 记录所有请求，便于断言。
  late List<http.Request> requests;

  KugouClient clientReturning(Object Function(http.Request) respond) {
    requests = [];
    return KugouClient(
      device,
      client: MockClient((request) async {
        requests.add(request);
        return http.Response(
          jsonEncode(respond(request)),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );
  }

  /// 一条搜索结果，字段取自真实响应（已裁剪）。
  ///
  /// 注意这里**故意不放** `AlbumAudioID`：真实响应里根本没有这个字段，
  /// 用的是 `Audioid`。测试数据如果自造一个 `AlbumAudioID`，就会掩盖
  /// 「搜索列表有歌但每首都点不动」这个真实故障。
  Map<String, Object?> rawSong({
    String hash = 'B3A52A7A958BF0AED0EBFBA2E9A818B7',
    String songName = '晴天',
    int albumAudioId = 20505418,
  }) => {
    'FileHash': hash.toLowerCase(),
    'SongName': songName,
    'SingerName': '周杰伦',
    'Audioid': albumAudioId,
    'Scid': albumAudioId,
    'AlbumID': 966846,
    'AlbumName': '叶惠美',
    'Duration': 269,
    'Image': 'http://imge.kugou.com/stdmusic/{size}/a.jpg',
    'Privilege': 10,
    'PayType': 3,
    'HQFileHash': '1B56126A8A03924F1DD066259C095CBC',
    'SQFileHash': '0A69169202DE95AAF24A9944CCF0730D',
  };

  group('Song 解析', () {
    test('搜索结果的字段映射到 Song', () {
      final song = Song.fromJson(rawSong().cast<String, dynamic>());
      expect(song.hash, 'B3A52A7A958BF0AED0EBFBA2E9A818B7');
      expect(song.title, '晴天');
      expect(song.artist, '周杰伦');
      expect(song.albumAudioId, 20505418);
      expect(song.duration, const Duration(seconds: 269));
      expect(song.coverUrl(240), contains('/240/'));
      expect(song.playable, isTrue);
      expect(song.id, 'kg:B3A52A7A958BF0AED0EBFBA2E9A818B7');
    });

    test('SingerName 是「A、B」串时拆成多个歌手', () {
      final song = Song.fromJson({
        'FileHash': 'AA',
        'SongName': '合唱',
        'SingerName': '周杰伦、费玉清',
      });
      expect(song.singers, ['周杰伦', '费玉清']);
      expect(song.artist, '周杰伦、费玉清');
    });

    test('哈希为 0 的音质视为不存在', () {
      final song = Song.fromJson({
        'FileHash': 'AA',
        'SongName': 'x',
        'HQFileHash': '0',
        'SQFileHash': '0',
      });
      expect(song.hash320, isEmpty);
      expect(song.hashFlac, isEmpty);
    });

    test('缺少 AlbumAudioID 的条目不可播放', () {
      // 只有 hash 没有 album_audio_id 时取地址一定失败，
      // 提前在模型层判掉，界面就不会给出「点了没反应」的入口。
      final song = Song.fromJson({'FileHash': 'AA', 'SongName': 'x'});
      expect(song.playable, isFalse);
    });

    test('嵌套 audios 的条目也能解出来', () {
      final song = Song.tryParse({'audios': rawSong()});
      expect(song, isNotNull);
      expect(song!.title, '晴天');
    });

    test('歌单识别传输字段的封面并改用 HTTPS 旧域名对应地址', () {
      final song = Song.tryParse({
        'name': '歌曲', 'hash': 'AB',
        'pic': '0',
        'trans_param': {'union_cover': '//c1.kgimg.com/stdmusic/{size}/ab.jpg'},
      });
      expect(song?.coverUrl(150), 'https://imge.kugou.com/stdmusic/150/ab.jpg');
    });

    test('album_audio_id 从 Audioid 取（搜索接口没有 AlbumAudioID）', () {
      // 真实响应的 key 是 Audioid / Scid，没有 AlbumAudioID。
      // 只按 AlbumAudioID 取会得到 0 → playable 为 false，
      // 界面表现是「搜到了歌，但每一首都点不动」。
      final song = Song.fromJson({
        'FileHash': 'AA',
        'SongName': '晴天',
        'Audioid': 20505418,
        'Scid': 20505418,
      });
      expect(song.albumAudioId, 20505418);
      expect(song.playable, isTrue);
    });

    test('AlbumAudioID 为 "0" 时回退到 Audioid', () {
      // 用 `??` 会把这个字符串 "0" 当成有效值，后面的 Audioid 就取不到了。
      final song = Song.fromJson({
        'FileHash': 'AA',
        'SongName': '晴天',
        'AlbumAudioID': '0',
        'Audioid': 20505418,
      });
      expect(song.albumAudioId, 20505418);
    });

    test('Audioid 也缺失时才判为不可播放', () {
      final song = Song.fromJson({'FileHash': 'AA', 'SongName': 'x'});
      expect(song.albumAudioId, 0);
      expect(song.playable, isFalse);
    });
  });

  group('searchSongs', () {
    test('请求带 x-router 与 AndroidFilter 参数', () async {
      // 没有 x-router 时网关直接回 502（kws），这是实测踩过的坑。
      final api = KugouMusicApi(
        clientReturning(
          (_) => {
            'status': 1,
            'data': {
              'lists': [rawSong()],
            },
          },
        ),
      );
      final songs = await api.searchSongs('晴天');
      expect(songs, hasLength(1));
      expect(songs.single.title, '晴天');

      final request = requests.single;
      expect(request.url.path, '/v2/search/song');
      expect(request.headers['x-router'], 'complexsearch.kugou.com');
      expect(request.url.queryParameters['keyword'], '晴天');
      expect(request.url.queryParameters['platform'], 'AndroidFilter');
      expect(request.url.queryParameters['pagesize'], '30');
      // 签名必须存在，否则服务端按裸请求处理。
      expect(request.url.queryParameters['signature'], hasLength(32));
    });

    test('data 里没有 lists 时返回空列表而不是抛错', () async {
      final api = KugouMusicApi(clientReturning((_) => {'status': 1}));
      expect(await api.searchSongs('x'), isEmpty);
    });

    test('用 Android 盐签名、带 Android UA（否则服务端回 err signature）', () async {
      // 实测：web 盐 + Mozilla UA → {"status":0,"error_code":20006,
      // "error_msg":"err signature"}，界面上表现为「搜不到歌」；
      // 换成 android 盐 + Android UA → status:1，total:480。
      // 这条用例锁住「不能回退成 web 签名」。
      final api = KugouMusicApi(
        clientReturning((_) => {'status': 1, 'data': {'lists': [rawSong()]}}),
      );
      await api.searchSongs('晴天');

      final request = requests.single;
      expect(
        request.headers['user-agent'],
        'Android15-1070-11083-46-0-DiscoveryDRADProtocol-wifi',
      );
      // 用固定参数子集复算签名，确认用的是 Android 盐：
      // MD5(android盐 + 排序后 k=v + android盐)。
      expect(
        KugouSignature.android({
          'area_code': '1',
          'keyword': '晴天',
          'pagesize': '30',
          'platform': 'AndroidFilter',
        }),
        '258e3b1dbf4f99123e2ef28bda8303b5',
      );
      // 同时确认它不是 web 盐算出来的值。
      expect(
        KugouSignature.web({
          'area_code': '1',
          'keyword': '晴天',
          'pagesize': '30',
          'platform': 'AndroidFilter',
        }),
        isNot('258e3b1dbf4f99123e2ef28bda8303b5'),
      );
    });
  });

  group('searchSuggest', () {
    Map<String, Object?> suggestResponse() => {
      'status': 1,
      'data': [
        {
          'LableName': '歌曲',
          'RecordCount': 2,
          'RecordDatas': [
            {'HintInfo': '晴天', 'TransType': 0},
            {'HintInfo': '晴天 周杰伦', 'TransType': 0},
          ],
        },
        {
          'LableName': '歌单',
          'RecordDatas': [
            {'HintInfo': '晴天'},
          ],
        },
      ],
    };

    test('从 data[].RecordDatas[].HintInfo 取联想词并去重', () async {
      // 真实结构是三层嵌套，不是常见的 data.lists[].keyword：
      // 按后者取会永远得到空列表，表现为「联想词不出现」。
      final api = KugouMusicApi(clientReturning((_) => suggestResponse()));
      final hints = await api.searchSuggest('晴天');
      expect(hints, ['晴天', '晴天 周杰伦']);
      expect(requests.single.headers['x-router'], 'searchtip.kugou.com');
    });

    test('结构不符时返回空列表而不是抛错', () async {
      final api = KugouMusicApi(
        clientReturning((_) => {'status': 1, 'data': {'lists': []}}),
      );
      expect(await api.searchSuggest('x'), isEmpty);
    });
  });

  group('songUrl', () {
    const session = KugouSession(
      userid: 42,
      token: 'test-token',
      nickname: '测试账号',
      avatar: '',
    );
    final song = Song.fromJson(rawSong().cast<String, dynamic>());

    KugouMusicApi playbackApi(Object Function(http.Request) tracker) =>
        KugouMusicApi(clientReturning((request) => switch (request.url.path) {
          '/v1/user_verify' => {'status': 1, 'data': {'auth': 'user-auth'}},
          '/v1/authorization' => {
            'status': 1,
            'data': {'auth': 'track-auth', 'open_time': '1787673734'},
          },
          '/tracker/v5/url' => tracker(request),
          _ => throw StateError('未知的播放接口'),
        })..session = session);

    test('先验证账号再授权歌曲，最后签名请求播放地址', () async {
      final api = playbackApi((_) => {
        'status': 1,
        'url': ['https://fs.kugou.com/a.mp3'],
        'bitRate': '128',
        'fileSize': '1234',
        'extName': 'mp3',
      });
      final url = await api.songUrl(song);

      expect(url, isNotNull);
      expect(url!.url, 'https://fs.kugou.com/a.mp3');
      expect(url.quality, AudioQuality.standard);
      expect(url.bitrate, 128);
      expect(url.size, 1234);
      expect(requests.map((request) => request.url.path), [
        '/v1/user_verify',
        '/v1/authorization',
        '/tracker/v5/url',
      ]);
      expect(requests.map((request) => request.url.scheme), everyElement('https'));
      expect(requests.map((request) => request.url.queryParameters['token']), everyElement('test-token'));
      expect(requests.first.headers['x-router'], 'trackercdngz.kugou.com');
      final authorize = requests[1].url.queryParameters;
      expect(authorize['authorization'], 'user-auth');
      expect(authorize['album_audio_id'], '${song.albumAudioId}');
      // queryParameters 无法区分 module 和 module=，要断言实际请求的原始查询串。
      expect(requests.last.url.query.split('&'), contains('module='));
      final tracker = Map.of(requests.last.url.queryParameters);
      expect(tracker['auth'], 'track-auth');
      expect(tracker['open_time'], '1787673734');
      expect(tracker['hash'], song.hash.toLowerCase());
      expect(tracker['album_audio_id'], '${song.albumAudioId}');
      expect(tracker['quality'], '128');
      expect(tracker['pid'], '2');
      expect(tracker['page_id'], '151369488');
      expect(tracker['ppage_id'], '463467626,350369493,788954147');
      expect(
        tracker['key'],
        KugouSignature.trackerKey(
          hash: song.hash.toLowerCase(),
          mid: device.mid,
          userid: session.userid,
        ),
      );
      final signature = tracker.remove('signature');
      expect(signature, KugouSignature.android(tracker));
    });

    test('概念版登录使用概念版参数和凭证签名获取播放地址', () async {
      final api = playbackApi((_) => {
        'status': 1,
        'url': ['https://fs.kugou.com/concept.mp3'],
      });
      api.client.session = const KugouSession(
        userid: 42, token: 'lite-main-token', nickname: '', avatar: '', lite: true,
      );
      expect((await api.songUrl(song))?.url, 'https://fs.kugou.com/concept.mp3');
      expect(requests, hasLength(3));
      for (final request in requests) {
        final query = Map.of(request.url.queryParameters);
        expect(query['appid'], '3116');
        expect(query['token'], 'lite-main-token');
        final signature = query.remove('signature');
        expect(signature, KugouSignature.liteAndroid(query));
      }
      final tracker = requests.last.url.queryParameters;
      expect(tracker['pid'], '411');
      expect(tracker['page_id'], '967177915');
      expect(tracker['ppage_id'], '356753938,823673182,967485191');
      expect(tracker['key'], KugouSignature.trackerKey(
        hash: song.hash.toLowerCase(), mid: device.mid, userid: 42, lite: true,
      ));
    });

    test('高音质不可用时沿用授权请求标准音质并接受备用地址', () async {
      final api = playbackApi((request) {
        if (request.url.queryParameters['quality'] == '320') {
          return {'status': 0, 'error_code': '35104'};
        }
        return {
          'status': '1',
          'data': {
            'url': ['file:///do-not-play.mp3'],
            'backupUrl': [{'url': 'https://fs.kugou.com/backup.mp3'}],
          },
        };
      });
      final url = await api.songUrl(song, quality: AudioQuality.high);
      expect(url?.url, 'https://fs.kugou.com/backup.mp3');
      expect(url?.quality, AudioQuality.standard);
      expect(requests.skip(2).map((request) => request.url.queryParameters['quality']), ['320', '128']);
    });

    test('优先选择 HTTPS 备用地址并保留它的音质信息', () async {
      final api = playbackApi((_) => {
        'status': 1,
        'url': ['http://fs.youthandroid.kugou.com/primary.mp3'],
        'backup_url': {
          'data': [
            {'playUrl': 'https://fs.youthandroid2.kugou.com/backup.flac', 'q': 'flac'},
          ],
        },
      });
      final result = await api.songUrl(song);
      expect(result?.url, 'https://fs.youthandroid2.kugou.com/backup.flac');
      expect(result?.quality, AudioQuality.lossless);
    });

    test('非标准音质返回 31833 时沿用授权试一次标准音质', () async {
      final api = playbackApi((request) {
        final query = request.url.queryParameters;
        expect(query['auth'], 'track-auth');
        return query['quality'] == 'flac'
            ? {'status': 0, 'errcode': 31833}
            : {'status': 1, 'url': ['https://fs.kugou.com/standard.mp3']};
      });
      final url = await api.songUrl(song, quality: AudioQuality.lossless);
      expect(url?.quality, AudioQuality.standard);
      expect(requests.skip(2).map((r) => r.url.queryParameters['quality']), ['flac', '128']);
    });

    test('标准音质也被拒绝时保留 31833，不重复请求', () async {
      final api = playbackApi((_) => {'status': 0, 'error_code': '31833'});
      await expectLater(
        api.songUrl(song),
        throwsA(isA<KugouFailure>().having((e) => e.message, 'message', contains('31833'))),
      );
      expect(requests, hasLength(3));
    });

    test('降到标准音质仍无链接时保留原错误码', () async {
      final api = playbackApi((request) => request.url.queryParameters['quality'] == '320'
          ? {'status': 0, 'error_code': 31833}
          : {'status': 1, 'url': []});
      await expectLater(
        api.songUrl(song, quality: AudioQuality.high),
        throwsA(isA<KugouFailure>().having((e) => e.message, 'message', contains('31833'))),
      );
      expect(requests, hasLength(4));
    });

    test('31833 同时要求账号验证时不降档重试', () async {
      final api = playbackApi((_) => {'status': 0, 'error_code': 31833, 'ssaCode': 'verify'});
      await expectLater(
        api.songUrl(song, quality: AudioQuality.lossless),
        throwsA(isA<KugouFailure>().having((e) => e.message, 'message', contains('账号验证'))),
      );
      expect(requests, hasLength(3));
    });

    test('酷狗仅返回 HTTP 地址时保留原始授权链接', () async {
      const url = 'http://fs.youthandroid.kugou.com/song.mp3?signature=abc%2Bdef';
      final api = playbackApi((_) => {'status': 1, 'url': [url]});
      expect((await api.songUrl(song))?.url, url);
    });

    test('服务端返回空 url 数组时判为拿不到地址', () async {
      final api = playbackApi((_) => {'status': 1, 'url': []});
      expect(await api.songUrl(song), isNull);
    });

    test('使用酷狗返回的实际音质，而不是请求的档位', () async {
      final api = playbackApi((_) => {
        'status': 1,
        'url': ['https://fs.kugou.com/standard.mp3'],
        'q': 128,
      });
      final url = await api.songUrl(song, quality: AudioQuality.lossless);
      expect(requests.last.url.queryParameters['quality'], 'flac');
      expect(url?.quality, AudioQuality.standard);
    });

    test('凭证失效时停止取地址并提示重新登录', () async {
      final api = KugouMusicApi(clientReturning(
        (_) => {'status': 0, 'error_code': 35005},
      )..session = session);
      await expectLater(api.songUrl(song), throwsA(isA<KugouSessionExpired>()));
      expect(requests.single.url.path, '/v1/user_verify');
    });

    test('tracker 签名错误给出接口错误码', () async {
      final api = playbackApi((_) => {'status': 0, 'errcode': '20006'});
      await expectLater(
        api.songUrl(song),
        throwsA(isA<KugouFailure>().having((e) => e.message, 'message', contains('20006'))),
      );
    });

    test('更换账号后不沿用上一账号的播放授权', () async {
      late final KugouClient client;
      client = clientReturning((_) {
        client.session = null;
        return {'status': 1, 'data': {'auth': 'old-auth'}};
      })..session = session;
      await expectLater(KugouMusicApi(client).songUrl(song), throwsA(isA<KugouFailure>()));
      expect(requests.single.url.path, '/v1/user_verify');
    });

    test('未登录或没有 AlbumAudioID 时不发请求', () async {
      final api = KugouMusicApi(clientReturning((_) => throw StateError('不应发请求')));
      final noId = Song.fromJson({
        'FileHash': 'AA',
        'SongName': 'x',
        'AlbumAudioID': 0,
      });
      expect(await api.songUrl(noId), isNull);
      await expectLater(
        api.songUrl(song),
        throwsA(isA<KugouFailure>().having((e) => e.message, 'message', contains('请先登录'))),
      );
      expect(requests, isEmpty);
    });
  });

  group('列表接口', () {
    test('每日推荐从 data.info 里取歌', () async {
      final api = KugouMusicApi(
        clientReturning(
          (_) => {
            'status': 1,
            'data': {
              'info': [rawSong()],
            },
          },
        ),
      );
      final songs = await api.dailyRecommend(userid: 42);
      expect(songs, hasLength(1));
      final request = requests.single;
      expect(request.headers['x-router'], 'everydayrec.service.kugou.com');
      expect(jsonDecode(request.body)['userid'], '42');
    });

    test('自建歌单从 data.info 读取云歌单格式的歌曲', () async {
      final client = clientReturning(
        (_) => {
          'status': 1,
          'data': {
            'info': [
              {
                'hash': 'b3a52a7a958bf0aed0ebfba2e9a818b7',
                'name': '周杰伦 - 晴天.mp3',
                'fileid': 9,
                'audio_id': 34,
                'mixsongid': '20505418',
                'timelen': 269792,
                'media_pay_type': 3,
                'albuminfo': {'name': '叶惠美', 'id': 966846},
              },
            ],
          },
        },
      )..session = const KugouSession(
        userid: 42,
        token: 'test-token',
        nickname: '测试账号',
        avatar: '',
      );
      final songs = await KugouMusicApi(client).playlistSongs(
        Playlist.fromJson({
          'name': '我喜欢',
          'listid': '777',
          'userid': 42,
          'list_create_userid': '42',
        }),
      );
      final song = songs.single;
      expect(song.playable, isTrue);
      expect(song.title, '晴天');
      expect(song.artist, '周杰伦');
      expect(song.albumName, '叶惠美');
      expect(song.albumAudioId, 20505418);
      expect(song.duration.inMilliseconds, 269792);
      expect(song.payType, 3);
      final request = requests.single;
      expect(request.url.path, '/v4/get_list_all_file_v3');
      expect(request.headers['x-router'], 'cloudlist.service.kugou.com');
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      expect(body['listid'], 777);
      expect(body['userid'], 42);
      expect(body['token'], 'test-token');
    });

    test('收藏的公开歌单通过原歌单 ID 读取 data.songs', () async {
      final client = clientReturning((_) => {
        'status': 1,
        'data': {
          'songs': [
            {'hash': 'abc', 'name': '青鸟飞鱼 - 此生不换', 'mixsongid': 132865997},
          ],
        },
      })..session = const KugouSession(
        userid: 42,
        token: 'test-token',
        nickname: '测试账号',
        avatar: '',
      );
      final songs = await KugouMusicApi(client).playlistSongs(
        Playlist.fromJson({
          'name': '我的收藏',
          'listid': 777,
          'userid': 42,
          'global_collection_id': 'collection_3_42_777_0',
          'list_create_userid': 2187780004,
          'list_create_listid': 153,
        }),
        page: 2,
        pageSize: 30,
      );
      expect(songs.single.title, '此生不换');
      expect(songs.single.playable, isTrue);
      final request = requests.single;
      expect(request.method, 'GET');
      expect(request.url.path, '/pubsongs/v2/get_other_list_file_nofilt');
      expect(request.url.queryParameters['global_collection_id'], 'collection_3_2187780004_153_0');
      expect(request.url.queryParameters['begin_idx'], '30');
    });

    test('歌单接口返回错误时显示原因，空列表仍可正常展示', () async {
      const playlist = Playlist(globalCollectionId: 'public-gid', name: '测试', listId: 0);
      final expired = KugouMusicApi(clientReturning(
        (_) => {'status': 0, 'error_code': '20017'},
      ));
      await expectLater(
        expired.playlistSongs(playlist),
        throwsA(isA<KugouFailure>().having((e) => e.message, 'message', contains('重新登录'))),
      );
      final malformed = KugouMusicApi(clientReturning(
        (_) => {'status': 1, 'data': {'songs': [{'fileid': 9}]}},
      ));
      await expectLater(malformed.playlistSongs(playlist), throwsA(isA<KugouFailure>()));
      final empty = KugouMusicApi(clientReturning(
        (_) => {'status': 1, 'data': {'songs': []}},
      ));
      expect(await empty.playlistSongs(playlist), isEmpty);
    });

    test('未登录时不会去请求用户歌单', () async {
      final api = KugouMusicApi(clientReturning((_) => {}));
      expect(await api.userPlaylists(), isEmpty);
      expect(requests, isEmpty);
    });
  });

  group('Playlist 解析', () {
    test('没有 global_collection_id 时用 userid:listid 兜底', () {
      final playlist = Playlist.fromJson({
        'listid': 12,
        'userid': 34,
        'name': '收藏',
        'count': 5,
      });
      expect(playlist.id, '34:12');
      expect(playlist.songCount, 5);
    });

    test('排行榜映射名称和封面，预览条数不会当成总数', () async {
      final api = KugouMusicApi(
        clientReturning(
          (_) => {
            'status': 1,
            'data': {
              'info': [
                {
                  'rankid': 8888,
                  'rankname': '酷狗飙升榜',
                  'imgurl': 'http://x/{size}.jpg',
                  'songinfo': [1, 2, 3],
                },
                {
                  'rankid': 8889,
                  'rankname': '新歌榜',
                  'song_count': '100',
                  'songinfo': [1, 2, 3],
                },
              ],
            },
          },
        ),
      );
      final ranks = await api.rankList();
      expect(ranks, hasLength(2));
      expect(ranks.first.name, '酷狗飙升榜');
      expect(ranks.first.cover, 'http://x/{size}.jpg');
      expect(ranks.first.globalCollectionId, '8888');
      expect(ranks.map((rank) => rank.songCount), [0, 100]);
    });

    test('排行榜单曲用 audio_info/album_info/authors 这套字段', () {
      // `/openapi/kmr/v2/rank/audio` 的单曲结构与搜索接口完全不同：
      // hash 在 audio_info.hash_128，封面在 album_info.sizable_cover，
      // 歌手在 authors[].author_name。不单独处理的话 hash 取不到，
      // 条目会被过滤掉且不报错——表现为「排行榜打开没有歌」。
      final song = Song.tryParse({
        'album_audio_id': 12345,
        'songname': '晴天',
        'audio_info': {
          'hash_128': 'b3a52a7a958bf0aed0ebfba2e9a818b7',
          'hash_320': '1b56126a8a03924f1dd066259c095cbc',
          'hash_flac': '0',
          'duration_128': 269000,
        },
        'album_info': {'sizable_cover': 'http://imge.kugou.com/rank/a.jpg'},
        'authors': [
          {'author_name': '周杰伦'},
          {'author_name': '方文山'},
        ],
        'privilege_download': {'privilege_128': 10},
      });

      expect(song, isNotNull);
      expect(song!.hash, 'B3A52A7A958BF0AED0EBFBA2E9A818B7');
      expect(song.title, '晴天');
      expect(song.singers, ['周杰伦', '方文山']);
      expect(song.albumAudioId, 12345);
      expect(song.albumImage, 'http://imge.kugou.com/rank/a.jpg');
      expect(song.hash320, '1B56126A8A03924F1DD066259C095CBC');
      expect(song.hashFlac, isEmpty);
      // 时长字段是毫秒，别和搜索接口的「秒」混用。
      expect(song.duration, const Duration(milliseconds: 269000));
      expect(song.playable, isTrue);
    });

    test('rankSongs 不发 x-router（带上会被网关判成 502）', () async {
      final api = KugouMusicApi(
        clientReturning(
          (_) => {
            'status': 1,
            'data': {
              'info': [
                {
                  'songname': '晴天',
                  'audio_info': {'hash_128': 'AA'},
                  'authors': [
                    {'author_name': '周杰伦'},
                  ],
                },
              ],
            },
          },
        ),
      );
      final songs = await api.rankSongs('8888');
      expect(songs, hasLength(1));
      expect(requests.single.headers.containsKey('x-router'), isFalse);
    });
  });

  group('userPlaylists', () {
    test('用普通 Android 签名，x-router 放请求头', () async {
      // 权威对照：上游 module/user_playlist.js 用同样的普通签名，
      // 假 token 得 20017、未登录得 20010，与本实现一致。
      // 只有写操作才走 cloudlist 的 RSA+AES 协议，读取列表不走。
      final client = clientReturning(
        (_) => {
          'status': 1,
          'data': {
            'info': [
              {'listid': 12, 'userid': 34, 'name': '收藏', 'count': 5},
            ],
          },
        },
      )..session = const KugouSession(
        userid: 34,
        token: 'tok',
        nickname: '我',
        avatar: '',
      );
      final lists = await KugouMusicApi(client).userPlaylists();
      expect(lists, hasLength(1));

      final request = requests.single;
      expect(request.url.path, '/v7/get_all_list');
      expect(request.headers['x-router'], 'cloudlist.service.kugou.com');
      // x-router 绝不能进查询参数，否则参与签名会变成 20006。
      expect(request.url.queryParameters.containsKey('x-router'), isFalse);
      expect(request.url.queryParameters['plat'], '1');
      expect(request.url.queryParameters['token'], 'tok');

      // 请求体是明文 JSON，字段与上游 dataMap 对齐。
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      expect(body['userid'], 34);
      expect(body['token'], 'tok');
      expect(body['total_ver'], 979);
      expect(body['type'], 2);
    });

    test('凭证失效时抛错，错误信息带 token 指纹', () async {
      // 返回空列表和「真的没有歌单」在界面上无法区分。
      // 带上指纹是为了区分「token 长度异常」和「token 正常但不被接受」。
      final client = clientReturning(
        (_) => {'status': 0, 'error_code': 20017},
      )..session = const KugouSession(
        userid: 34,
        token: 'abcdef1234567890zzzz',
        nickname: '我',
        avatar: '',
      );
      await expectLater(
        KugouMusicApi(client).userPlaylists(),
        throwsA(
          isA<KugouFailure>().having(
            (error) => error.message,
            'message',
            allOf(contains('酷狗不认这个登录凭证'), contains('abcd')),
          ),
        ),
      );
    });

    test('token 过短时直接标为长度异常', () async {
      final client = clientReturning(
        (_) => {'status': 0, 'error_code': 20017},
      )..session = const KugouSession(
        userid: 34,
        token: 'short',
        nickname: '我',
        avatar: '',
      );
      await expectLater(
        KugouMusicApi(client).userPlaylists(),
        throwsA(
          isA<KugouFailure>().having(
            (error) => error.message,
            'message',
            contains('长度异常'),
          ),
        ),
      );
    });

    test('其他错误码带上服务端给的原文', () async {
      final client = clientReturning(
        (_) => {'status': 0, 'error_code': 20001, 'error_msg': '参数错误'},
      )..session = const KugouSession(
        userid: 34,
        token: 'tok',
        nickname: '我',
        avatar: '',
      );
      await expectLater(
        KugouMusicApi(client).userPlaylists(),
        throwsA(
          isA<KugouFailure>().having(
            (error) => error.message,
            'message',
            contains('参数错误'),
          ),
        ),
      );
    });
  });

  test('trackerKey 与 KuGouMusicApi 的 signKey 一致', () {
    // 对照值由 Node 端按 helper.js 的 signKey（标准版盐值）算出：
    // MD5(hash + 57ae12eb… + appid + mid + userid)。改盐值或字段顺序会立刻失败。
    final mid = '7565304436484971299367348748134733451';
    expect(
      KugouSignature.trackerKey(
        hash: 'b3a52a7a958bf0aed0ebfba2e9a818b7',
        mid: mid,
        userid: 42,
      ),
      '692105d09d1cc8824ca6e8d7a6293b9a',
    );
    expect(
      KugouSignature.trackerKey(
        hash: 'B3A52A7A958BF0AED0EBFBA2E9A818B7',
        mid: mid,
        userid: 42,
      ),
      '49a16555fcd5a0e7ea838849b682fb3d',
    );
  });
}

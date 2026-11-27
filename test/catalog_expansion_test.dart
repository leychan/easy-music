import 'dart:convert';

import 'package:easy_music/account/kugou/kugou_auth.dart';
import 'package:easy_music/account/kugou/kugou_client.dart';
import 'package:easy_music/account/kugou/kugou_device.dart';
import 'package:easy_music/account/kugou/signature.dart';
import 'package:easy_music/music/catalog.dart';
import 'package:easy_music/music/kugou_catalog_api.dart';
import 'package:easy_music/music/kugou_music_api.dart';
import 'package:easy_music/music/kugou_playlist_api.dart';
import 'package:easy_music/music/song.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  late List<http.Request> requests;
  const cloudSession = KugouSession(userid: 4, token: 'test-token', nickname: '', avatar: '');


  KugouMusicApi apiFor(Map<String, Object?> Function(http.Request) response) {
    requests = [];
    final client = KugouClient(
      KugouDevice(guid: 'catalog-test', mac: '02:00:00:00:00:00'),
      client: MockClient((request) async {
        requests.add(request);
        return http.Response.bytes(
          utf8.encode(jsonEncode(response(request))),
          200,
        );
      }),
    );
    addTearDown(client.close);
    return KugouMusicApi(client);
  }

  Map<String, Object?> fmBatch(Iterable<int> ids) => {
    'status': 1,
    'data': {
      'song_list': [
        {'FileHash': 'INVALID', 'SongName': '缺少曲目 ID'},
        for (final id in ids) {'FileHash': 'FM$id', 'SongName': '推荐 $id', 'Audioid': id},
      ],
    },
  };

  test('歌手照片去重后按固定顺序选取，接口改变顺序时首图不变', () async {
    final api = apiFor((_) => throw StateError('Unexpected catalog request'));
    const filenames = ['f', 'a', 'e', 'c', 'd', 'b', 'a'];
    var requestCount = 0;
    await http.runWithClient(() async {
      final first = await api.artistImages('17');
      final second = await api.artistImages('17');
      expect(first, [
        for (final name in ['a', 'b', 'c', 'd', 'e'])
          'https://imge.kugou.com/stdmusic/800/$name.jpg',
      ]);
      expect(second, first);
      expect(requestCount, 2);
    }, () => MockClient((request) async {
      expect(request.url.queryParameters['entity_id'], '17');
      final order = requestCount++ == 0 ? filenames : filenames.reversed;
      return http.Response(jsonEncode({
        'status': 1,
        'data': [
          {
            'imgs': [
              for (final name in order)
                {'file': 'http://imge.kugou.com/stdmusic/{size}/$name.jpg'},
              {'file': 'file:///missing.jpg'},
            ],
          },
        ],
      }), 200);
    }));
  });

  test('歌手作品按请求页返回，并根据总数判断是否还有下一页', () async {
    final api = apiFor((request) {
      expect(request.url.path, '/kmr/v1/audio_group/author');
      final body = jsonDecode(request.body) as Map;
      final page = body['page'] as int;
      expect(body['author_id'], '17');
      expect(body['pagesize'], 100);
      return {
        'status': 1,
        'data': {
          'total': '101',
          'audio': [
            {'FileHash': 'SONG$page', 'SongName': '示例 $page', 'Audioid': page},
          ],
        },
      };
    });

    final first = await api.artistTracksPage('17', page: 1);
    final last = await api.artistTracksPage('17', page: 2);
    expect(first.hits.single.id, 'kg:SONG1');
    expect(last.hits.single.id, 'kg:SONG2');
    expect(first.hasMore, isTrue);
    expect(last.hasMore, isFalse);
  });

  test('私人 FM 首批够用时只发一批，补批后也最多保留十首', () async {
    for (final firstBatchSize in [5, 12]) {
      final api = apiFor((request) {
        expect(request.url.path, '/v2/personal_recommend');
        expect(request.headers['x-router'], 'persnfm.service.kugou.com');
        return requests.length == 1
            ? fmBatch(Iterable<int>.generate(firstBatchSize, (i) => i + 1))
            : fmBatch([6, 7, 8, 9, 10]);
      });
      api.client.session = cloudSession;
      expect((await api.personalFmSongs()).map((song) => song.albumAudioId),
        List.generate(10, (index) => index + 1),
      );
      expect(requests, hasLength(firstBatchSize == 5 ? 2 : 1));
    }
  });

  test('私人 FM 重复或不足时按推荐顺序保留唯一歌曲，最多请求三批', () async {
    final api = apiFor((_) => switch (requests.length) {
      1 => fmBatch([3, 1, 3]),
      2 => fmBatch([1, 4, 3]),
      _ => fmBatch([4, 1]),
    });
    api.client.session = cloudSession;
    expect((await api.personalFmSongs()).map((song) => song.albumAudioId), [3, 1, 4]);
    expect(requests, hasLength(3));
  });

  test('私人 FM 补批失败时保留首批，首批失败时保留错误提示', () async {
    const failed = {'status': 0, 'error_msg': '推荐服务暂不可用'};
    final api = apiFor((_) => requests.length == 1 ? fmBatch([1, 2]) : failed);
    api.client.session = cloudSession;
    expect((await api.personalFmSongs()).map((song) => song.albumAudioId), [1, 2]);
    expect(requests, hasLength(2));

    final failing = apiFor((_) => failed);
    failing.client.session = cloudSession;
    await expectLater(failing.personalFmSongs(), throwsA(isA<KugouFailure>()));
    expect(requests, hasLength(1));
  });

  test('按专辑分类搜索，再用专辑 ID 获取可播曲目', () async {
    final api = apiFor(
      (request) => switch (request.url.path) {
        '/v1/search/album' => {
          'status': 1,
          'data': {
            'lists': [
              {'albumid': 17, 'albumname': '示例专辑', 'singer': '示例歌手'},
            ],
          },
        },
        '/v1/album_audio/lite' => {
          'status': 1,
          'data': {
            'songs': [
              {
                'base': {
                  'album_audio_id': 42,
                  'audio_name': '示例歌曲',
                  'album_id': 17,
                },
                'audio_info': {'hash_128': 'abcdef', 'duration_128': 210000},
              },
            ],
          },
        },
        _ => throw StateError('Unexpected route'),
      },
    );

    final result = (await api.searchCatalog('示例', SearchType.album)).single;
    final song = (await api.albumTracks(result.id)).single;
    expect(result.title, '示例专辑');
    expect(song.title, '示例歌曲');
    expect(song.playable, isTrue);
    expect(song.albumAudioId, 42);
    expect(requests.first.headers['x-router'], 'complexsearch.kugou.com');
    expect(requests.last.headers['kg-tid'], '255');
  });

  test('综合搜索解析带标记的分类结果，并使用分组总数判断下一页', () async {
    final client = KugouClient(
      KugouDevice(guid: 'catalog-test', mac: '02:00:00:00:00:00'),
      client: MockClient((request) async {
        expect(request.url.host, 'complexsearch.kugou.com');
        expect(request.url.path, '/v6/search/complex');
        final params = request.url.queryParameters;
        expect(params['keyword'], '示例');
        expect(params['page'], '2');
        expect(params['pagesize'], '30');
        expect(params['cursor'], '0');
        expect(params['signature'], hasLength(32));
        final payload = jsonEncode({
          'status': 1,
          'data': {
            'lists': [
              {
                'type': 'song', 'total': 61,
                'lists': [{'FileHash': 'ABC', 'SongName': '示例歌曲', 'Audioid': 17, 'MixSongID': '42'}],
              },
              {
                'type': 'collect', 'total': 31,
                'lists': [{'gid': '2:3', 'specialname': '示例歌单'}],
              },
              {'type': 'talent', 'total': 70, 'lists': [{'id': 1}]},
            ],
          },
        });
        return http.Response.bytes(
          utf8.encode('<!--KG_TAG_RES_START-->$payload<!--KG_TAG_RES_END-->\n'),
          200,
        );
      }),
    );
    addTearDown(client.close);

    final result = await KugouMusicApi(client).searchComplex('示例', page: 2);
    expect(result.hits.keys, [SearchType.song, SearchType.playlist]);
    expect(result.hits[SearchType.song]!.single.song!.albumAudioId, 42);
    expect(result.hits[SearchType.playlist]!.single.title, '示例歌单');
    expect(result.hasMore, isTrue);
  });

  test('单项搜索将页码传给歌曲和专辑接口，末页停止翻页', () async {
    final api = apiFor((request) {
      expect(request.url.queryParameters['page'], '2');
      return {
        'status': 1,
        'data': {
          'total': 31,
          'lists': [
            if (request.url.path == '/v2/search/song')
              {'FileHash': 'ABC', 'SongName': '示例歌曲', 'Audioid': 17}
            else
              {'albumid': 17, 'albumname': '示例专辑'},
          ],
        },
      };
    });
    for (final type in [SearchType.song, SearchType.album]) {
      final result = await api.searchCatalogPage('示例', type, page: 2);
      expect(result.hits, hasLength(1));
      expect(result.hasMore, isFalse);
    }
    expect(requests.map((request) => request.url.path), ['/v2/search/song', '/v1/search/album']);
  });

  test('增删歌单歌曲分别使用专辑音频 ID 与歌单文件 ID', () async {
    final api = apiFor((_) => {'status': 1});
    api.client.session = const KugouSession(
      userid: 4,
      token: 'token',
      nickname: '',
      avatar: '',
    );
    const list = Playlist(
      globalCollectionId: '4:3',
      name: '歌单',
      listId: 3,
      userId: 4,
    );
    const song = Song(hash: 'abc', title: '歌曲', albumAudioId: 17, fileId: 99);
    await api.addPlaylistSong(list, song);
    await api.removePlaylistSong(list, song);
    expect(requests.first.url.path, '/cloudlist.service/v6/add_song');
    expect(jsonDecode(requests.first.body)['data'][0]['mixsongid'], 17);
    expect(requests.last.url.path, '/v4/delete_songs');
    expect(jsonDecode(requests.last.body)['data'][0]['fileid'], 99);
  });

  test('云盘列表用 Android 签名，兼容顶层和 data 中的文件列表', () async {
    const list = [
      {
        'hash': 'AABB',
        'hash_128': 'CCDD',
        'hash_std': 'EEFF',
        'filename': '歌手 - 云盘歌曲.flac',
        'kv_id': '79',
        'mixsongid': 23,
        'duration': 197,
        'audio_info': {'audio_id': 154},
      },
    ];
    final api = apiFor((request) {
      final query = request.url.queryParameters;
      expect(request.url.host, 'mcloudservice.kugou.com');
      expect(request.url.path, '/v1/get_list');
      final timestamp = int.parse(query['clienttime']!);
      expect(query['key'], KugouSignature.loginKey(timestamp));
      expect(query['key'], isNot(KugouSignature.smsKey(timestamp)));
      expect(query, isNot(contains('token')));
      expect(query['p'], matches(r'^[A-F0-9]{256}$'));
      expect(request.bodyBytes.length % 16, 0);
      return requests.length == 1
          ? {'status': 1, 'list': list}
          : {'status': 1, 'data': {'list': list}};
    })..client.session = cloudSession;

    for (final page in [1, 2]) {
      final track = (await api.cloudTracks(page)).single;
      expect(track.song.hash, 'AABB');
      expect(track.song.title, '云盘歌曲');
      expect(track.fileName, '歌手 - 云盘歌曲.flac');
      expect(track.audioId, 154);
      expect(track.song.albumAudioId, 23);
      expect(track.song.duration, const Duration(seconds: 197));
      expect(track.fileId, '79');
    }
  });

  test('云盘读失败时显示登录失效，异常列表不会当成空歌单', () async {
    final api = apiFor((_) => switch (requests.length) {
      1 => {'status': 0, 'error_code': 20017},
      2 => {'status': 1, 'data': {'other': true}},
      _ => {'status': 1, 'data': {'list_count': 0}},
    })..client.session = cloudSession;
    await expectLater(api.cloudTracks(1), throwsA(isA<KugouFailure>().having(
      (error) => error.message, 'message', contains('登录已失效'),
    )));
    await expectLater(api.cloudTracks(1), throwsA(isA<KugouFailure>().having(
      (error) => error.message, 'message', contains('云盘列表格式'),
    )));
    expect(await api.cloudTracks(1), isEmpty);
  });

  test('云盘播放使用文件哈希签名，并接受备用地址', () async {
    final api = apiFor((request) {
      final query = request.url.queryParameters;
      expect(request.url.path, '/bsstrackercdngz/v2/query_musicclound_url');
      expect(query['hash'], 'aabb');
      expect(query['audio_id'], '154');
      expect(query['album_audio_id'], '23');
      expect(query['key'], 'ca0792beb2c5d71372eb428b09f91db7');
      return {
        'status': 1,
        'data': {
          'url': 'http://musicclound.bssdl.kugou.com/cloud.flac',
          'backup_url': ['invalid-url', 'https://example.org/cloud.flac'],
        },
      };
    })..client.session = cloudSession;
    const track = CloudTrack(
      Song(hash: 'AABB', title: '云盘歌曲', albumAudioId: 23), '云盘歌曲.flac', 154, 4,
    );
    expect(await api.cloudAddress(track), Uri.parse('https://example.org/cloud.flac'));
  });
}

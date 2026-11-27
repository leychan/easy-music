import 'dart:convert';

import 'package:http/http.dart' as http;

import '../account/kugou/kugou_auth.dart' show KugouFailure, KugouSession;
import '../account/kugou/crypto.dart';
import '../account/kugou/signature.dart';
import 'catalog.dart';
import 'kugou_music_api.dart';
import 'song.dart';

extension KugouCatalogApi on KugouMusicApi {
  static const _gateway = 'https://gateway.kugou.com';

  Future<List<CatalogHit>> searchCatalog(
    String keyword,
    SearchType type,
  ) async {
    if (type == SearchType.song) {
      return (await searchSongs(keyword)).map(CatalogHit.track).toList();
    }
    return (await searchCatalogPage(keyword, type, page: 1)).hits;
  }

  Future<CatalogSearchResult<List<CatalogHit>>> searchCatalogPage(
    String keyword,
    SearchType type, {
    required int page,
  }) async {
    const pageSize = 30;
    if (type == SearchType.song) {
      final result = await searchSongsPage(keyword, page: page, pageSize: pageSize);
      return (hits: result.hits.map(CatalogHit.track).toList(), hasMore: result.hasMore);
    }
    final json = await client.get(
      Uri.parse('$_gateway/v1/search/${type.apiName}'),
      extraParams: {
        'keyword': keyword,
        'page': page,
        'pagesize': pageSize,
        'platform': 'AndroidFilter',
        'iscorrection': 1,
        if (type == SearchType.album) ...{
          'category': 1,
          'sorttype': 0,
          'searchsong': 0,
        } else ...{
          'albumhide': 0,
          'nocollect': 0,
        },
      },
      headers: {'x-router': 'complexsearch.kugou.com'},
    );
    final data = _catalogData(json, '搜索${type.label}');
    return parseCatalogSearch(data, (row) => CatalogHit.fromJson(type, row), page: page, pageSize: pageSize);
  }

  Future<CatalogSearchResult<Map<SearchType, List<CatalogHit>>>> searchComplex(
    String keyword, {
    required int page,
  }) async {
    const pageSize = 30;
    final json = await client.get(
      Uri.parse('https://complexsearch.kugou.com/v6/search/complex'),
      extraParams: {
        'keyword': keyword,
        'platform': 'AndroidFilter',
        'page': page,
        'pagesize': pageSize,
        'cursor': 0,
      },
    );
    final data = _catalogData(json, '综合搜索');
    if (data is! Map || data['lists'] is! List) {
      throw const KugouFailure('酷狗未返回可识别的综合搜索结果。');
    }
    final hits = <SearchType, List<CatalogHit>>{};
    var hasMore = false;
    for (final group in _catalogRows(data, 'lists')) {
      final type = switch (group['type']) {
        'song' => SearchType.song,
        'author' => SearchType.artist,
        'album' => SearchType.album,
        'collect' => SearchType.playlist,
        'lyric' => SearchType.lyric,
        'mv' => SearchType.video,
        _ => null,
      };
      if (type == null) continue;
      final result = parseCatalogSearch(
        group, (row) => CatalogHit.fromJson(type, row), page: page, pageSize: pageSize,
      );
      if (result.hits.isNotEmpty) hits.putIfAbsent(type, () => []).addAll(result.hits);
      hasMore |= result.hasMore;
    }
    return (hits: hits, hasMore: hasMore);
  }

  Future<List<Song>> albumTracks(String id, {bool purchased = false}) async {
    const size = 30;
    final songs = <Song>[];
    final firstIds = <String>{};
    for (var page = 1; ; page++) {
      final json = await client.post(
        Uri.parse('$_gateway/v1/album_audio/lite'),
        body: {
          'album_id': id,
          'is_buy': purchased ? 1 : '',
          'page': page,
          'pagesize': size,
        },
        headers: {'x-router': 'openapi.kugou.com', 'kg-tid': '255'},
      );
      final data = _catalogData(json, '读取专辑');
      final batch = _tracks(data, 'songs');
      if (batch.isEmpty || !firstIds.add(batch.first.id)) break;
      songs.addAll(batch);
      final total = data is Map ? int.tryParse('${data['total']}') : null;
      if (batch.length < size || (total != null && page * size >= total)) break;
    }
    return songs;
  }

  Future<CatalogSearchResult<List<Song>>> artistTracksPage(String id, {required int page}) async {
    const pageSize = 100;
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final json = await client.post(
      Uri.parse('https://openapi.kugou.com/kmr/v1/audio_group/author'),
      body: {
        'appid': client.appid,
        'clientver': client.clientver,
        'mid': client.device.mid,
        'clienttime': now,
        'key': client.isLite ? KugouSignature.loginKey(now, lite: true) : KugouSignature.smsKey(now),
        'author_id': id,
        'pagesize': pageSize,
        'page': page,
        'sort': 1,
        'area_code': 'all',
      },
      headers: {'x-router': 'openapi.kugou.com', 'kg-tid': '220'},
    );
    return parseCatalogSearch(
      _catalogData(json, '读取歌手作品'), Song.tryParse,
      page: page, pageSize: pageSize, listKey: 'audio',
    );
  }

  Future<List<Song>> freeListenSongs() async {
    final json = await client.post(
      Uri.parse('$_gateway/concepts/v1/ai/recommend_song'),
      body: {'apiver': 2, 'source': 2, 'pagesize': 30, 'page': 1},
    );
    return _tracks(_catalogData(json, '读取免费听'), 'list');
  }

  Future<List<Song>> personalFmSongs({Set<String> excludeIds = const {}}) async {
    final session = client.session;
    if (session == null) throw const KugouFailure('请先登录酷狗账号。');
    final songs = <Song>[];
    final ids = {...excludeIds};
    // 接口可能只返回一小批推荐，最多补两批，并保留已经收到的顺序。
    for (var batch = 0; batch < 3; batch++) {
      if (client.session?.token != session.token) break;
      List<Song> recommendations;
      try {
        recommendations = await _personalFmBatch(session);
      } on Exception {
        if (songs.isEmpty) rethrow;
        break;
      }
      for (final song in recommendations) {
        if (!song.playable || !ids.add(song.id)) continue;
        songs.add(song);
        if (songs.length == 10) return songs;
      }
    }
    return songs;
  }

  Future<List<Song>> _personalFmBatch(KugouSession session) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final json = await client.post(
      Uri.parse('$_gateway/v2/personal_recommend'),
      headers: {'x-router': 'persnfm.service.kugou.com'},
      body: {
        'appid': client.appid,
        'clienttime': now,
        'mid': client.device.mid,
        'action': 'play',
        'recommend_source_locked': 0,
        'song_pool_id': 0,
        'callerid': 0,
        'm_type': 1,
        'platform': 'ios',
        'area_code': 1,
        'remain_songcnt': 0,
        'clientver': client.clientver,
        'is_overplay': 0,
        'mode': 'normal',
        'fakem': 'ca981cfc583a4c37f28d2d49000013c16a0a',
        'key': client.isLite ? KugouSignature.loginKey(now, lite: true) : KugouSignature.smsKey(now),
        'userid': session.userid,
        'kguid': session.userid,
        'token': session.token,
        if (session.vipType != 0) 'vip_type': session.vipType,
      },
    );
    return _tracks(_catalogData(json, '读取私人 FM'), 'song_list');
  }

  Future<List<Playlist>> recommendedPlaylists({int category = 0}) async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final json = await client.post(
      Uri.parse('$_gateway/v2/special_recommend'),
      headers: {'x-router': 'specialrec.service.kugou.com'},
      body: {
        'appid': client.appid,
        'mid': client.device.mid,
        'clientver': client.clientver,
        'platform': 'android',
        'clienttime': '$now',
        'userid': client.session?.userid ?? 0,
        'module_id': 1,
        'page': 1,
        'pagesize': 20,
        'key': client.isLite ? KugouSignature.loginKey(now, lite: true) : KugouSignature.smsKey(now),
        'special_recommend': {
          'withtag': 1,
          'withsong': 1,
          'sort': 1,
          'ugc': 1,
          'is_selected': 0,
          'withrecommend': 1,
          'area_code': 1,
          'categoryid': category,
        },
        'req_multi': 1,
        'retrun_min': 5,
        'return_special_falg': 1,
      },
    );
    return _catalogRows(_catalogData(json, '读取推荐歌单'), 'special_list')
        .map(Playlist.fromJson)
        .where(
          (playlist) =>
              playlist.trackCollectionId.isNotEmpty && playlist.name.isNotEmpty,
        )
        .toList();
  }

  Future<List<String>> artistPortraits(String name) async {
    final results = await searchCatalog(name, SearchType.artist);
    final artist = results.where((item) => item.title == name).firstOrNull;
    if (artist == null) return const [];
    return artistImages(artist.id);
  }

  /// 已知歌手 ID 的页面可直接取大图，避免重复搜索和同名误配。
  Future<List<String>> artistImages(String id) async {
    final response = await http
        .get(
          Uri.https('openapicdnretry.kugou.com', '/kmr/v1/author/extend', {
            'fields_pack': 'allimages',
            'authorimg_type': '2,3',
            'entity_id': id,
          }),
        )
        .timeout(const Duration(seconds: 10));
    if (response.statusCode != 200) return const [];
    final result = jsonDecode(response.body);
    final data = result is Map && result['status']?.toString() == '1'
        ? result['data']
        : null;
    final photos = data is List && data.firstOrNull is Map
        ? (data.first as Map)['imgs']
        : null;
    if (photos is! List) return const [];
    final urls = <String>{};
    for (final photo in photos.whereType<Map>()) {
      final raw = photo['file'];
      if (raw is! String) continue;
      final address = resolveCoverUrl(raw, 800);
      if (address.isNotEmpty) urls.add(address);
    }
    // 接口可能改变返回顺序，先排序再截取，避免同一批照片换首图。
    final ordered = urls.toList()..sort();
    return List.unmodifiable(ordered.take(5));
  }

  Future<Uri> videoAddress(String hash) async {
    final json = await client.get(
      Uri.parse('$_gateway/v2/interface/index'),
      extraParams: {
        'backupdomain': 1,
        'cmd': 123,
        'ext': 'mp4',
        'ismp3': 0,
        'hash': hash,
        'pid': 1,
        'type': 1,
        'key': KugouSignature.trackerKey(
          hash: hash,
          mid: client.device.mid,
          userid: client.session?.userid ?? 0,
          lite: client.isLite,
        ),
      },
      headers: {'x-router': 'trackermv.kugou.com'},
    );
    final data = _catalogData(json, '读取 MV');
    final row = data is Map ? data[hash.toLowerCase()] ?? data[hash] : null;
    if (row is Map) {
      final backups = row['backupdownurl'];
      final urls = [row['downurl'], if (backups is List) ...backups];
      for (final value in urls.whereType<String>()) {
        final uri = Uri.tryParse(value);
        if (uri != null &&
            uri.host.isNotEmpty &&
            uri.userInfo.isEmpty &&
            (uri.scheme == 'https' || uri.scheme == 'http')) {
          return uri;
        }
      }
    }
    throw const KugouFailure('酷狗未返回可播放的 MV 地址。');
  }

  Future<List<Song>> purchasedSongs(int page) async {
    final data = await _purchased('audio/get_goods', page, false);
    return _catalogRows(data, 'goods')
        .map((row) {
          final audio = row['audio_info'];
          return Song.tryParse({
            if (audio is Map<String, dynamic>) ...audio,
            ...row,
            'album_audio_id': row['album_audio_id'] ?? row['good_scid'],
            'cover': row['album_cover'],
          });
        })
        .whereType<Song>()
        .toList();
  }

  Future<List<CatalogHit>> purchasedAlbums(int page) async {
    final data = await _purchased('get_album_goods', page, true);
    return [
      for (final row in _catalogRows(data, 'goods'))
        if (row['album_id'] != null && row['album_name'] != null)
          CatalogHit(
            id: row['album_id'].toString(),
            title: row['album_name'].toString(),
            subtitle: row['singer_name']?.toString() ?? '',
            cover: row['cover']?.toString() ?? '',
          ),
    ];
  }

  Future<Object?> _purchased(String endpoint, int page, bool albums) async {
    final session = client.session;
    if (session == null) throw const KugouFailure('请先登录酷狗账号。');
    final url = albums
        ? '$_gateway/openapi/v1/copyright/$endpoint'
        : '$_gateway/openapi/copyright/v1/$endpoint';
    final json = await client.post(
      Uri.parse(url),
      body: {
        'appid': client.appid,
        'clientver': '${client.clientver}',
        'userid': session.userid,
        'token': session.token,
        'page': page,
        'pagesize': 30,
        'deleted': 0,
        if (!albums) ...{'need_audio_info': 1, 'area_code': '1'},
      },
    );
    return _catalogData(json, '读取已购音乐') ?? json;
  }

  Future<List<CloudTrack>> cloudTracks(int page) async {
    final session = client.session;
    if (session == null) throw const KugouFailure('请先登录酷狗账号。');
    final json = await client.cloudPost(
      Uri.parse('https://mcloudservice.kugou.com/v1/get_list'),
      body: {'page': page, 'pagesize': 30, 'getkmr': 1},
    );
    final data = _cloudData(json, '读取音乐云盘');
    final fields = data is Map ? data : json;
    final rows = data is List ? data : fields['list'] ?? json['list'];
    if (rows is! List) {
      final count = fields['list_count'] ?? fields['count'];
      if (rows == null && count?.toString() == '0') return const [];
      throw const KugouFailure('酷狗返回的云盘列表格式无法识别。');
    }
    final tracks = rows.whereType<Map<String, dynamic>>()
        .map((row) => CloudTrack.tryParse(row, session.userid)).whereType<CloudTrack>().toList();
    if (rows.isNotEmpty && tracks.isEmpty) {
      throw const KugouFailure('酷狗返回的云盘文件缺少可识别的音频信息。');
    }
    return tracks;
  }

  Future<Uri> cloudAddress(CloudTrack track) async {
    if (track.userid <= 0 || client.session?.userid != track.userid) {
      throw const KugouFailure('请登录保存这首歌的酷狗账号。');
    }
    final hash = track.song.hash.toLowerCase();
    final json = await client.get(
      Uri.parse('$_gateway/bsstrackercdngz/v2/query_musicclound_url'),
      extraParams: {
        'hash': hash,
        'ssa_flag': 'is_fromtrack',
        'version': '20102',
        'ssl': 0,
        'album_audio_id': track.song.albumAudioId,
        'pid': 20026,
        'audio_id': track.audioId,
        'kv_id': 2,
        'key': KugouCrypto.md5(
          'musicclound${hash}20026ebd1ac3134c880bda6a2194537843caa0162e2e7',
        ),
        'bucket': 'musicclound',
        'name': track.fileName,
        'with_res_tag': 0,
      },
    );
    final data = _cloudData(json, '获取云盘播放地址');
    if (data is Map) {
      Uri? fallback;
      for (final value in [
        for (final entry in [data['url'], data['backup_url'], data['backupUrl']])
          if (entry is List) ...entry else entry,
      ].whereType<String>()) {
        final url = Uri.tryParse(value.trim());
        if (url != null && (url.scheme == 'https' || url.scheme == 'http') &&
            url.host.isNotEmpty && url.userInfo.isEmpty) {
          if (url.scheme == 'https') return url;
          fallback ??= url;
        }
      }
      if (fallback != null) return fallback;
    }
    throw const KugouFailure('酷狗未返回这首云盘音乐的播放地址。');
  }

  Future<void> deleteCloudTrack(CloudTrack track) async {
    if (client.session?.userid != track.userid || track.fileId == null) {
      throw const KugouFailure('云盘文件编号不可用，请刷新后重试。');
    }
    final raw = track.fileId.toString();
    final json = await client.cloudPost(
      Uri.parse('https://mcloudservice.kugou.com/v1/del_files'),
      body: {
        'data': [
          {
            'kv_id': int.tryParse(raw) ?? raw,
            'album_audio_id': track.song.albumAudioId,
          },
        ],
      },
    );
    _cloudData(json, '移除云盘文件');
    if (json['status']?.toString() != '1') {
      throw const KugouFailure('酷狗未确认移除云盘文件。');
    }
  }

  /// 云盘接口既会直接返回列表，也会把结果放在 data 中。
  static Object _cloudData(Map<String, dynamic> json, String action) {
    final code = int.tryParse('${json['error_code']}');
    if (code == 20017 || code == 20018 || code == 20019) {
      throw const KugouFailure('酷狗登录已失效，请重新登录后访问音乐云盘。');
    }
    if (json['status']?.toString() == '0' || (code != null && code != 0)) {
      final detail = code == null || code == 0 ? '' : '（错误码 $code）';
      throw KugouFailure('$action失败$detail，请稍后重试。');
    }
    return json['data'] ?? json;
  }

  static Object? _catalogData(Map<String, dynamic> json, String action) {
    final code = json['error_code'];
    if (json['status']?.toString() == '0' ||
        (code != null && code.toString() != '0')) {
      throw KugouFailure('$action失败，请稍后重试。');
    }
    return json['data'];
  }

  static Iterable<Map<String, dynamic>> _catalogRows(Object? data, String key) {
    final rows = data is Map ? data[key] : data;
    return rows is List ? rows.whereType<Map<String, dynamic>>() : const [];
  }

  static List<Song> _tracks(Object? data, String key) =>
      _catalogRows(data, key).map(Song.tryParse).whereType<Song>().toList();
}

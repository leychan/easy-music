import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint;

import '../account/kugou/kugou_auth.dart'
    show KugouFailure, KugouSession, KugouSessionExpired;
import '../account/kugou/kugou_client.dart';
import '../account/kugou/signature.dart';
import '../player/audio_quality.dart';
import '../player/lyrics.dart';
import 'catalog.dart';
import 'song.dart';

export '../player/audio_quality.dart';

/// 一首歌在某个音质下的可播地址。
class SongUrl {
  const SongUrl({
    required this.url,
    this.quality = AudioQuality.standard,
    this.bitrate = 0,
    this.size = 0,
    this.format = 'mp3',
  });

  final String url;
  final AudioQuality quality;
  final int bitrate;
  final int size;
  final String format;

  factory SongUrl.fromJson(Map<String, dynamic> json, {AudioQuality? quality}) {
    final bitrate = _number(json['bitRate'] ?? json['bitrate']);
    return SongUrl(
      url: (json['url'] as String?) ?? '',
      quality: AudioQuality.fromApiName(json['q']) ??
          quality ??
          _qualityOf(bitrate),
      bitrate: bitrate,
      size: _number(json['fileSize']),
      format: json['extName']?.toString() ?? 'mp3',
    );
  }

  static int _number(Object? value) =>
      value is num ? value.toInt() : int.tryParse('$value') ?? 0;

  static AudioQuality _qualityOf(int bitrate) => switch (bitrate) {
    >= 1000 => AudioQuality.lossless,
    >= 320 => AudioQuality.high,
    _ => AudioQuality.standard,
  };
}

/// 音乐库接口集合。
///
/// 对应 KuGouMusicApi 的搜索、播放授权、歌词和榜单模块。
/// 搜索等公开内容可匿名访问，播放授权和个人歌单使用当前登录会话。
class KugouMusicApi {
  KugouMusicApi(this.client);

  final KugouClient client;

  static const _gateway = 'https://gateway.kugou.com';
  static const _authHeaders = {'x-router': 'trackercdngz.kugou.com'};
  static const _trackerVersion = 11561;
  static const _playbackModule = 51;

  /// 搜索接口要打 `complexsearch` 集群，缺这个头网关直接回 502。
  static const _searchHeaders = {'x-router': 'complexsearch.kugou.com'};

  /// 搜索歌曲。[page] 从 1 开始，[pageSize] 最大 100。
  Future<List<Song>> searchSongs(
    String keyword, {
    int page = 1,
    int pageSize = 30,
  }) async {
    final json = await _searchSongResponse(keyword, page, pageSize);
    return parseCatalogSearch(json['data'], Song.tryParse, page: page, pageSize: pageSize).hits;
  }

  Future<CatalogSearchResult<List<Song>>> searchSongsPage(
    String keyword, {
    required int page,
    required int pageSize,
  }) async {
    final json = await _searchSongResponse(keyword, page, pageSize);
    final code = json['error_code'];
    if (json['status']?.toString() == '0' || (code != null && code.toString() != '0')) {
      throw const KugouFailure('搜索歌曲失败，请稍后重试。');
    }
    return parseCatalogSearch(json['data'], Song.tryParse, page: page, pageSize: pageSize);
  }

  Future<Map<String, dynamic>> _searchSongResponse(String keyword, int page, int pageSize) =>
    client.get(
      Uri.parse('$_gateway/v2/search/song'),
      extraParams: {
        'keyword': keyword,
        'page': page,
        'pagesize': pageSize,
        'platform': 'AndroidFilter',
        'iscorrection': 1,
        'privilegefilter': 0,
        'area_code': 1,
        'dopicfull': 1,
      },
      headers: _searchHeaders,
    );

  /// 歌单只给编号时，批量查询缺少的专辑封面。
  Future<Map<int, String>> songCovers(Iterable<int> ids) async {
    final result = await client.post(
      Uri.parse('$_gateway/kmr/v2/audio'),
      body: {
        'data': [for (final id in ids) {'entity_id': id}],
        'fields': 'album_info,base',
      },
      headers: {'x-router': 'openapi.kugou.com', 'KG-TID': '238'},
      includeSession: false,
      timeout: const Duration(seconds: 4),
    );
    final rows = result['data'];
    if (rows is! List) return const {};
    final covers = <int, String>{};
    for (final row in rows.whereType<Map>()) {
      final base = row['base'];
      final album = row['album_info'];
      if (base is! Map || album is! Map || '${row['__status']}' == '0') continue;
      final id = int.tryParse('${base['album_audio_id']}');
      if (id == null || id <= 0) continue;
      if (_albumCover(album) case final cover?) covers[id] = cover;
    }
    return covers;
  }

  /// 老歌曲可能查不到歌曲详情，但专辑接口仍然提供封面。
  Future<Map<int, String>> albumCovers(Iterable<int> ids) async {
    final result = await client.post(
      Uri.parse('$_gateway/kmr/v2/albums'),
      body: {
        'data': [for (final id in ids) {'album_id': id}],
        'is_buy': 0,
        'fields': 'album_id,sizable_cover,cover',
      },
      headers: {'x-router': 'openapi.kugou.com', 'KG-TID': '255'},
      includeSession: false,
      timeout: const Duration(seconds: 4),
    );
    final rows = result['data'];
    if (rows is! List) return const {};
    final covers = <int, String>{};
    for (final row in rows.whereType<Map>()) {
      final id = int.tryParse('${row['album_id']}');
      if (id == null || id <= 0) continue;
      if (_albumCover(row) case final cover?) covers[id] = cover;
    }
    return covers;
  }

  static String? _albumCover(Map album) => [album['sizable_cover'], album['cover']]
      .whereType<String>().where((cover) => resolveCoverUrl(cover).isNotEmpty).firstOrNull;

  /// 搜索联想词，用于输入框下拉提示。
  ///
  /// 响应结构实际是 `data[] -> RecordDatas[] -> HintInfo`，而不是常见的
  /// `data.lists[].keyword`：按后者取会永远得到空列表，表现为「联想词不出现」。
  /// 各分组（音乐/歌手/专辑）的候选都在 `RecordDatas` 里，按出现顺序拼接。
  Future<List<String>> searchSuggest(String keyword) async {
    if (keyword.trim().isEmpty) return const [];
    final json = await client.get(
      Uri.parse('$_gateway/v2/getSearchTip'),
      extraParams: {
        'keyword': keyword,
        'AlbumTipCount': 10,
        'CorrectTipCount': 10,
        'MVTipCount': 10,
        'MusicTipCount': 10,
        'radiotip': 1,
      },
      headers: {'x-router': 'searchtip.kugou.com'},
    );
    final data = json['data'];
    if (data is! List) return const [];
    final seen = <String>{};
    for (final group in data) {
      if (group is! Map) continue;
      final records = group['RecordDatas'];
      if (records is! List) continue;
      for (final record in records) {
        if (record is! Map) continue;
        final hint = record['HintInfo'];
        if (hint is String && hint.isNotEmpty) seen.add(hint);
      }
    }
    return seen.toList();
  }

  /// 用当前账号取得歌曲授权，再向 tracker 换取可播放的地址。
  Future<SongUrl?> songUrl(
    Song song, {
    AudioQuality quality = AudioQuality.standard,
  }) async {
    if (!song.playable) return null;
    final session = client.session;
    if (session == null) {
      throw const KugouFailure('请先登录酷狗账号后再播放。');
    }

    final verified = await client.get(
      Uri.parse('$_gateway/v1/user_verify'),
      extraParams: {'module_id': _playbackModule},
      headers: _authHeaders,
    );
    _checkPlaybackSession(session);
    const verifyError = '获取酷狗账号的播放授权失败';
    _checkPlaybackResponse(verified, verifyError);
    final userAuth = _authorizationOf(verified, verifyError);

    final hash = song.hash.toLowerCase();
    final authorized = await client.get(
      Uri.parse('$_gateway/v1/authorization'),
      extraParams: {
        'authorization': userAuth,
        'module_id': _playbackModule,
        'album_audio_id': song.albumAudioId,
        'clientver': _trackerVersion,
        'hash': hash,
      },
      headers: _authHeaders,
    );
    _checkPlaybackSession(session);
    const songAuthError = '获取这首歌的播放授权失败';
    if (!_checkPlaybackResponse(authorized, songAuthError, allowUnavailable: true)) {
      return null;
    }
    final auth = _authorizationOf(authorized, songAuthError);
    final data = authorized['data'] as Map;
    final openTime = int.tryParse('${data['open_time']}');
    if (openTime == null || openTime <= 0) {
      throw const KugouFailure('酷狗未返回这首歌的授权时间，请稍后重试。');
    }

    // 请求的音质不可用时，只重试标准音质，仍使用同一次歌曲授权。
    KugouFailure? rejectedQuality;
    for (final requested in {quality, AudioQuality.standard}) {
      final json = await client.get(
        Uri.parse('$_gateway/tracker/v5/url'),
        extraParams: {
          'album_id': song.albumId,
          'area_code': 1,
          'module': '',
          'hash': hash,
          'need_m': 0,
          'ssa_flag': 'is_fromtrack',
          'version': 11430,
          'open_time': openTime,
          'ptype': 0,
          'need_ogg': 1,
          // 播放入口参数必须和当前登录的客户端版本一致。
          'page_id': session.lite ? 967177915 : 151369488,
          'auth': auth,
          'mtype': 0,
          'quality': requested.apiName,
          'album_audio_id': song.albumAudioId,
          'behavior': 'play',
          'pid': session.lite ? 411 : 2,
          'module_id': _playbackModule,
          'cmd': 26,
          'ppage_id': session.lite
              ? '356753938,823673182,967485191'
              : '463467626,350369493,788954147',
          'clientver': _trackerVersion,
          'pidversion': 3001,
          'cdnBackup': 1,
          // HTTPS 网关校验 tracker key 和通用签名，两处采用同一个小写 hash。
          'key': KugouSignature.trackerKey(
            hash: hash,
            mid: client.device.mid,
            userid: session.userid,
            lite: session.lite,
          ),
        },
      );
      _checkPlaybackSession(session);
      try {
        if (!_checkPlaybackResponse(json, '获取播放地址失败', allowUnavailable: true)) {
          continue;
        }
      } on KugouFailure catch (error) {
        // 31833 的具体含义不明。只尝试标准档，不隐藏验证要求或最终错误。
        if (requested == AudioQuality.standard ||
            _playbackErrorCode(json) != 31833 ||
            json['ssaCode'] != null) {
          rethrow;
        }
        rejectedQuality = error;
        continue;
      }
      final url = _readSongUrl(json, requested);
      if (url != null) return url;
    }
    if (rejectedQuality != null) throw rejectedQuality;
    return null;
  }

  void _checkPlaybackSession(KugouSession expected) {
    final current = client.session;
    if (current?.userid != expected.userid || current?.token != expected.token) {
      throw const KugouFailure('登录账号已变化，请重新点播。');
    }
  }

  static String _authorizationOf(Map<String, dynamic> json, String error) {
    final data = json['data'];
    final auth = data is Map ? data['auth'] : null;
    if (auth is String && auth.trim().isNotEmpty) return auth;
    throw KugouFailure('$error，酷狗未返回授权信息。');
  }

  static bool _checkPlaybackResponse(
    Map<String, dynamic> json,
    String error, {
    bool allowUnavailable = false,
  }) {
    final code = _playbackErrorCode(json);
    if (code == 20017 || code == 20018 || code == 20019 || code == 35005) {
      throw const KugouSessionExpired('酷狗登录已失效，请重新登录后再播放。');
    }
    if (code == 20028 || json['ssaCode'] != null) {
      throw const KugouFailure('酷狗要求账号验证，请在酷狗客户端完成验证后重试。');
    }
    final failed = json['status']?.toString() == '0';
    if (allowUnavailable && (code == 35104 || (failed && (code == null || code == 0)))) {
      return false;
    }
    if (failed || (code != null && code != 0)) {
      throw KugouFailure(code == null || code == 0
          ? '$error，请稍后重试。'
          : '$error（酷狗错误码 $code）。');
    }
    return true;
  }

  static int? _playbackErrorCode(Map<String, dynamic> json) =>
      int.tryParse('${json['error_code'] ?? json['errcode'] ?? json['err_code']}');

  static SongUrl? _readSongUrl(
    Object? value,
    AudioQuality quality, [
    Map<String, dynamic> metadata = const {},
  ]) {
    if (value is String) {
      final url = Uri.tryParse(value.trim());
      if (url == null || !url.hasAuthority || url.host.isEmpty ||
          url.userInfo.isNotEmpty || (url.scheme != 'http' && url.scheme != 'https')) {
        return null;
      }
      return SongUrl.fromJson({...metadata, 'url': url.toString()}, quality: quality);
    }
    const keys = ['url', 'play_url', 'playUrl', 'backupUrl', 'backup_url', 'data', 'info'];
    final fields = value is Map<String, dynamic> ? {...metadata, ...value} : metadata;
    final candidates = switch (value) {
      List items => items,
      Map<String, dynamic> data => keys.map((key) => data[key]),
      _ => const <Object?>[],
    };
    // 主地址可能是 HTTP，先检查同一份授权返回的 HTTPS 备用地址。
    SongUrl? fallback;
    for (final entry in candidates) {
      final url = _readSongUrl(entry, quality, fields);
      if (url == null) continue;
      if (url.url.startsWith('https://')) return url;
      fallback ??= url;
    }
    return fallback;
  }

  /// 根据搜索结果里的哈希选出一个「最该显示」的档位。
  ///
  /// 用户没开会员时无损大多拿不到，但搜索结果里仍然标着 `SQFileHash`，
  /// 所以不能只看哈希是否存在来判断能否播放。
  static AudioQuality bestAvailable(Song song) => song.hashFlac.isNotEmpty
      ? AudioQuality.lossless
      : song.hash320.isNotEmpty
      ? AudioQuality.high
      : AudioQuality.standard;

  /// 取歌词。
  ///
  /// 两段式，缺一步都拿不到：
  /// 1. `krcs.kugou.com/search` 按 hash + 时长查候选，返回 `id` 与 `accesskey`；
  /// 2. `lyrics.kugou.com/download` 用这对 id/accesskey 换 base64 的 LRC。
  ///
  /// 注意 `keyword` 必须传空串：传歌名会被当成关键词搜索，返回的候选
  /// 与本首对不上。另外第 2 步的签名只有一次有效，必须用同一次请求里
  /// 拿到的 accesskey，不能复用缓存。
  Future<String?> lyrics(Song song) async {
    final versions = await lyricVersions(song);
    // 首选版本偶尔没有可用文本，再试下一份匹配的歌词。
    for (final version in versions.take(3)) {
      final text = await downloadLyrics(version);
      if (text != null && parseLyrics(text).isNotEmpty) return text;
    }
    return null;
  }

  Future<List<LyricVersion>> lyricVersions(Song song) async {
    if (song.hash.isEmpty) return const [];
    final found = await client.get(
      Uri.parse('https://krcs.kugou.com/search'),
      extraParams: {
        'ver': 1,
        'man': 'yes',
        'client': 'mobi',
        'keyword': '',
        'duration': song.duration.inMilliseconds,
        'hash': song.hash,
      },
    );
    final candidates = found['candidates'];
    if (candidates is! List || candidates.isEmpty) return const [];

    // 优先取与歌曲时长最接近的候选，避免拿到同名翻唱的歌词。
    final versions = <LyricVersion>[];
    for (final entry in candidates) {
      if (entry is! Map) continue;
      final key = entry['accesskey'];
      if (entry['id'] == null || key is! String || key.isEmpty) continue;
      final duration = int.tryParse('${entry['duration']}') ?? 0;
      versions.add(LyricVersion(
        entry['id'].toString(), key, entry['song']?.toString() ?? song.title,
        entry['nickname']?.toString() ?? entry['originame']?.toString() ?? '',
        duration,
      ));
    }
    final target = song.duration.inMilliseconds;
    if (target > 0) {
      versions.sort((a, b) => (a.duration - target).abs().compareTo((b.duration - target).abs()));
    }
    return versions;
  }

  Future<String?> downloadLyrics(LyricVersion version) async {
    final result = await client.get(
      Uri.parse('https://lyrics.kugou.com/download'),
      extraParams: {
        'ver': 1,
        'client': 'pc',
        'id': version.id,
        'accesskey': version.accessKey,
        'fmt': 'krc',
        'charset': 'utf8',
      },
    );
    final content = result['content'];
    if (content is! String || content.isEmpty) return null;
    try {
      final bytes = base64Decode(content);
      final type = result['contenttype']?.toString() ?? '1';
      if (type == '0') return decodeKrc(bytes);
      if (type != '1') return null;
      final decoded = utf8.decode(bytes, allowMalformed: true);
      return decoded.trim().isEmpty ? null : decoded;
    } on FormatException {
      return null;
    }
  }

  /// 排行榜列表。
  Future<List<Playlist>> rankList({bool withSongs = true}) async {
    final json = await client.get(
      Uri.parse('$_gateway/ocean/v6/rank/list'),
      extraParams: {
        'plat': 2,
        'withsong': withSongs ? 1 : 0,
        'parentid': 0,
      },
    );
    final data = json['data'];
    if (data is! Map) return const [];
    final info = data['info'];
    if (info is! List) return const [];
    return [
      for (final entry in info)
        if (entry is Map)
          Playlist.fromJson({
            ...entry.cast<String, dynamic>(),
            // 排行榜用 rankid/rankname，没有 listid。
            'specialname': entry['rankname'],
            'name': entry['rankname'],
            'pic': entry['imgurl'],
            // songinfo 只包含榜单预览。总数由 Playlist 读取明确的计数字段。
          }),
    ]..removeWhere((item) => item.name.isEmpty);
  }

  /// 排行榜歌曲。
  Future<List<Song>> rankSongs(
    String rankId, {
    int page = 1,
    int pageSize = 30,
  }) async {
    final json = await client.post(
      Uri.parse('$_gateway/openapi/kmr/v2/rank/audio'),
      body: {
        'show_portrait_mv': 1,
        'show_type_total': 1,
        'filter_original_remarks': 1,
        'area_code': 1,
        'pagesize': pageSize,
        'rank_cid': 0,
        'type': 1,
        'page': page,
        'rank_id': rankId,
      },
      // 这个接口**不能**带 x-router：带上任何 x-router 都会被网关判成 502，
      // 只有 kg-tid 照官方客户端带。
      headers: {'kg-tid': '369'},
    );
    return _songsOf(json, const ['data', 'info']);
  }

  /// 当前用户的歌单列表。需要登录。
  ///
  /// **必须用普通 Android 签名，不要用 [KugouClient.cloudPost]。**
  /// 这一点有权威对照：直接用上游 KuGouMusicApi 的 `module/user_playlist.js`
  /// 跑一次，假 token 得到 `{"status":0,"error_code":20017}`，未登录得到
  /// `20010`，与本实现逐字一致。上游只有**写操作**（改封面、排序、改信息）
  /// 才走 cloudlist 那套 RSA+AES 协议，读取列表走的是普通签名。
  /// （我曾误判成整套协议都要加密，绕了一圈，见 tool/probe/cloud_*.mjs。）
  ///
  /// 因此 `20017` 就是纯粹的「token 校验不过」。为了能在界面上判断到底是
  /// 凭证问题还是别的，错误信息里带上 token 指纹（前 4 位、长度）——
  /// 不带完整 token，避免泄露到截图或日志里。
  ///
  /// 凭证失效时**必须抛错**而不是返回空列表：两者在界面上长得一模一样
  /// （都是「没有歌单」），用户无法判断该重新登录还是该等一等。
  Future<List<Playlist>> userPlaylists({int page = 1, int pageSize = 50}) async {
    final session = client.session;
    if (session == null) {
      debugPrint('[歌单] 未登录，直接返回空列表');
      return const [];
    }
    debugPrint(
      '[歌单] 请求中 userid=${session.userid} '
      'token=${_fingerprint(session.token)}',
    );

    final json = await client.post(
      Uri.parse('$_gateway/v7/get_all_list'),
      body: {
        'userid': session.userid,
        'token': session.token,
        'total_ver': 979,
        'type': 2,
        'page': page,
        'pagesize': pageSize,
      },
      // `token`/`userid` 由 [KugouClient] 按 session 自动注入，
      // 这里只补这个接口特有的 `plat`。
      extraParams: {'plat': 1},
      headers: {'x-router': 'cloudlist.service.kugou.com'},
    );

    final errorCode = json['error_code'];
    debugPrint(
      '[歌单] 响应 status=${json['status']} error_code=$errorCode '
      'data类型=${json['data'].runtimeType}',
    );
    if (errorCode == null || errorCode == 0) {
      final lists = _playlistsOf(json, session.userid);
      if (lists != null) {
        debugPrint('[歌单] 成功，共 ${lists.length} 个歌单');
        return lists;
      }
      debugPrint('[歌单] 响应结构不是预期的 data.info 列表');
    }

    if (errorCode == 20017) {
      throw KugouFailure(
        '酷狗不认这个登录凭证（账号 ${session.userid}，'
        'token ${_fingerprint(session.token)}）。'
        '请退出后重新登录。',
      );
    }
    throw KugouFailure(
      '读取歌单失败（${json['error_msg'] ?? json['msg'] ?? errorCode}）。',
    );
  }

  /// token 的指纹，用于排查时确认凭证形态是否异常，同时不泄露完整内容。
  static String _fingerprint(String token) {
    if (token.length <= 8) return '长度异常(${token.length})';
    return '${token.substring(0, 4)}…${token.substring(token.length - 4)}'
        '/长度${token.length}';
  }

  /// 从歌单响应里取出列表；结构不对时返回 null（表示「这条路的响应不可用」，
  /// 与「账号确实没有歌单」区分开）。
  List<Playlist>? _playlistsOf(Map<String, dynamic> json, int userid) {
    final data = json['data'];
    if (data is! Map) return null;
    final info = data['info'];
    if (info is! List) return null;
    return [
      for (final entry in info)
        if (entry is Map)
          Playlist.fromJson({
            'total_ver': data['total_ver'] ?? json['total_ver'],
            ...entry.cast<String, dynamic>(),
            'userid': userid,
          }),
    ]..removeWhere((item) => item.name.isEmpty);
  }

  /// 读取歌单中的一页歌曲。
  Future<List<Song>> playlistSongs(
    Playlist playlist, {
    int page = 1,
    int pageSize = 300,
  }) async {
    final session = client.session;
    final listId = session == null ? null : playlist.cloudListIdFor(session.userid);
    if (session != null && listId != null) {
      final json = await client.post(
        Uri.parse('$_gateway/v4/get_list_all_file_v3'),
        body: {
          'listid': listId,
          'userid': session.userid,
          'type': 0,
          'page': page,
          'pagesize': pageSize,
          'area_code': 1,
          'allplatform': 1,
          'show_cover': 1,
          'token': session.token,
        },
        headers: {'x-router': 'cloudlist.service.kugou.com'},
      );
      return _readPlaylistSongs(json);
    }

    final collectionId = playlist.trackCollectionId;
    if (collectionId.isEmpty || collectionId == '${playlist.userId}:${playlist.listId}') {
      throw const KugouFailure('缺少可用的歌单编号，请回到歌单列表刷新后重试。');
    }
    // 收藏记录的 listid 属于当前用户，公开接口需要原歌单的全局 ID。
    final json = await client.get(
      Uri.parse('$_gateway/pubsongs/v2/get_other_list_file_nofilt'),
      extraParams: {
        'area_code': 1,
        'begin_idx': (page - 1) * pageSize,
        'plat': 1,
        'type': 1,
        'mode': 1,
        'personal_switch': 1,
        'extend_fields': 'abtags,hot_cmt,popularization',
        'pagesize': pageSize,
        'global_collection_id': collectionId,
      },
    );
    return _readPlaylistSongs(json);
  }

  static List<Song> _readPlaylistSongs(Map<String, dynamic> json) {
    final code = json['error_code']?.toString();
    if (code == '20017' || code == '20018' || code == '20019') {
      throw const KugouFailure('登录已失效，请重新登录后再打开歌单。');
    }
    if ((code != null && code != '0') || json['status']?.toString() == '0') {
      final message = json['error_msg'] ?? json['message'] ?? json['msg'];
      throw KugouFailure(
        message is String && message.isNotEmpty
            ? '读取歌单歌曲失败（$message）。'
            : '读取歌单歌曲失败，请稍后重试。',
      );
    }

    final data = json['data'];
    const keys = ['info', 'songs', 'list', 'lists', 'songlist', 'items', 'data'];
    final tracks = [
      if (data is Map) for (final key in keys) data[key],
      for (final key in keys) json[key],
    ].whereType<List>().firstOrNull;
    if (tracks == null) {
      throw const KugouFailure('酷狗返回的歌单歌曲数据无法识别。');
    }
    final songs = tracks.map(Song.tryParse).whereType<Song>().toList();
    if (songs.isEmpty && tracks.isNotEmpty) {
      throw const KugouFailure('酷狗返回的歌曲缺少可识别的信息。');
    }
    return songs;
  }

  /// 每日推荐。未登录时返回公开推荐，登录后按口味推荐。
  ///
  /// `x-router` 同样只能放请求头（理由见 [userPlaylists]）。
  Future<List<Song>> dailyRecommend({int userid = 0}) async {
    final json = await client.post(
      Uri.parse('$_gateway/everyday_song_recommend'),
      body: {'platform': 'android', 'userid': '$userid'},
      headers: {'x-router': 'everydayrec.service.kugou.com'},
    );
    return _songsOf(json, const ['data', 'info']);
  }

  /// 从响应结构里挖出歌曲数组。
  ///
  /// 各家接口的列表位置不一样（`data.info` / `data.songlist` / `data.lists`），
  /// 甚至同一接口在登录前后结构也会变。所以先按调用方给的 [keys] 精确取值，
  /// 取不到再退化成「按层递归找第一个能解析出歌曲的数组」。
  static List<Song> _songsOf(
    Map<String, dynamic> json, [
    List<String> keys = const ['data.info', 'data.songlist', 'data.lists'],
  ]) {
    for (final key in keys) {
      final songs = _songsAt(json, key.split('.'));
      if (songs.isNotEmpty) return songs;
    }
    for (final list in _lists(json, 0)) {
      final songs = list.map(Song.tryParse).whereType<Song>().toList();
      if (songs.isNotEmpty) return songs;
    }
    return const [];
  }

  /// 按 `['data', 'info']` 这样的路径取数组并解析。
  static List<Song> _songsAt(Object? node, List<String> path) {
    var current = node;
    for (final segment in path) {
      if (current is Map) {
        current = current[segment];
      } else {
        return const [];
      }
    }
    if (current is! List) return const [];
    return current.map(Song.tryParse).whereType<Song>().toList();
  }

  static Iterable<List<Object?>> _lists(Object? node, int depth) {
    if (depth > 4) return const [];
    final here = <List<Object?>>[];
    final children = <Object?>[];
    void walk(Object? value) {
      if (value is List) {
        here.add(value.cast<Object?>());
        children.addAll(value);
      } else if (value is Map) {
        children.addAll(value.values);
      }
    }

    walk(node);
    return [
      ...here,
      for (final child in children) ..._lists(child, depth + 1),
    ];
  }
}

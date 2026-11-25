import '../player/track.dart';

/// 兼容酷狗的图片尺寸模板、旧域名和 Android 的 HTTPS 要求。
String resolveCoverUrl(String input, [int size = 240]) {
  final raw = input.trim().replaceAll('{size}', '$size');
  final uri = Uri.tryParse(raw.startsWith('//') ? 'https:$raw' : raw);
  if (uri == null || uri.host.isEmpty || uri.userInfo.isNotEmpty ||
      (uri.scheme != 'http' && uri.scheme != 'https')) {
    return '';
  }
  if (uri.host == 'c1.kgimg.com') {
    return uri.replace(scheme: 'https', host: 'imge.kugou.com').toString();
  }
  if (uri.scheme == 'http' &&
      (uri.host.endsWith('.kugou.com') || uri.host.endsWith('.kgimg.com'))) {
    return uri.replace(scheme: 'https').toString();
  }
  return uri.toString();
}

/// 一首酷狗歌曲。
///
/// 字段全部来自 `/v2/search/song` 的 `data.lists[]` 或歌单/排行榜接口的
/// 同名结构。`hash` 是 128k 的首选哈希（`FileHash`），`albumAudioId` 与它
/// 一起构成取播放地址的必需参数——只给 hash 拿不到地址。
class Song {
  const Song({
    required this.hash,
    required this.title,
    this.albumAudioId = 0,
    this.albumId = 0,
    this.albumName = '',
    this.albumImage = '',
    this.singers = const [],
    this.duration = Duration.zero,
    this.hash320 = '',
    this.hashFlac = '',
    this.privilege = 0,
    this.payType = 0,
    this.fileId = 0,
  });

  /// 本地文件和音频直链没有可写入酷狗收藏的歌曲标识。
  static Song? fromTrack(Track? track) {
    final hash = track?.kugouHash;
    if (track == null || hash == null) return null;
    return Song(
      hash: hash,
      title: track.title,
      albumAudioId: track.albumAudioId,
      albumId: track.albumId,
      singers: track.artist.isEmpty ? const [] : track.artist.split('、'),
      duration: track.duration,
    );
  }

  final String hash;
  final String title;

  /// 服务端里的 `AlbumAudioID`，取播放地址时当 `album_audio_id` 传。
  final int albumAudioId;
  final int albumId;
  final String albumName;

  /// 封面模板，形如 `http://imge.kugou.com/stdmusic/{size}/xx.jpg`。
  final String albumImage;

  final List<String> singers;
  final Duration duration;

  /// 更高音质的哈希，缺省为空串表示该曲目无此音质。
  final String hash320;
  final String hashFlac;

  /// 版权与付费标记，用于在界面上标注「VIP」「付费」。
  final int privilege;
  final int payType;
  final int fileId;

  String get artist => singers.isEmpty ? '未知歌手' : singers.join('、');

  /// 版权标记：`privilege <= 0` 表示没有播放权限（下架或纯付费）。
  bool get isVipOnly => privilege <= 0;

  /// 免费可听的歌曲 `PayType` 为 0；1/3 之类表示需要会员或单独付费。
  bool get isFree => payType == 0;

  /// 封面地址。[size] 是酷狗图片模板里的边长（150/240/400/480）。
  String coverUrl([int size = 240]) => resolveCoverUrl(albumImage, size);

  Song withCover(String image) => Song(
    hash: hash, title: title, albumAudioId: albumAudioId, albumId: albumId,
    albumName: albumName, albumImage: image, singers: singers, duration: duration,
    hash320: hash320, hashFlac: hashFlac, privilege: privilege, payType: payType,
    fileId: fileId,
  );

  /// 是否具备取播放地址的最低条件。
  bool get playable => hash.isNotEmpty && albumAudioId > 0;

  /// 队列里的唯一键：同一首歌可能出现在多个歌单里，但 hash 相同。
  String get id => 'kg:$hash';

  factory Song.fromJson(Map<String, dynamic> json) {
    final singers = <String>[];
    final rawSingers = json['Singers'];
    if (rawSingers is List) {
      for (final entry in rawSingers) {
        if (entry is Map) {
          final name = entry['name'];
          if (name is String && name.isNotEmpty) singers.add(name);
        }
      }
    }
    if (singers.isEmpty) {
      // 搜索结果的 SingerName 是「A、B」形式的一整串。
      final joined = json['SingerName'] as String? ?? '';
      singers.addAll(
        joined
            .split(RegExp(r'[、,，&/]'))
            .map((name) => name.trim())
            .where((name) => name.isNotEmpty),
      );
    }

    return Song(
      hash: _string(json['FileHash']).toUpperCase(),
      title: _firstNonEmpty(json, const ['SongName', 'FileName', 'OriSongName']),
      // 播放用的专辑曲目编号在搜索里叫 MixSongID。旧响应只有 Audioid/Scid 时再回退。
      albumAudioId: _firstPositiveInt(json, const ['AlbumAudioID', 'MixSongID', 'Audioid', 'Scid']),
      albumId: _firstPositiveInt(json, const ['AlbumID', 'AlbumId', 'album_id']),
      albumName: _string(json['AlbumName']),
      albumImage: _cover(json, const ['Image', 'AlbumImage', 'Pic', 'pic']),
      singers: singers,
      // 搜索接口的 `Duration` 是**秒**，而排行榜的 `duration_128` 是**毫秒**，
      // 两者混用会让歌词匹配（按毫秒比对时长）整体错位。这里显式换算。
      duration: switch (_int(json['Duration'])) {
        final seconds? => Duration(seconds: seconds),
        _ => Duration(milliseconds: _int(json['TimeLength']) ?? 0),
      },
      hash320: _normalizeHash(json['HQFileHash'] ?? json['320Hash']),
      hashFlac: _normalizeHash(json['SQFileHash'] ?? json['SQHash']),
      privilege: _int(json['Privilege']) ?? 0,
      payType: _int(json['PayType']) ?? 0,
    );
  }

  /// 排行榜/歌单接口偶尔把歌曲多包一层，这里统一拆开。
  static Song? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final audio = raw['audios'];
    final envelope = audio is Map
        ? {...raw.cast<String, dynamic>(), ...audio.cast<String, dynamic>()}
        : raw.cast<String, dynamic>();
    final base = envelope['base'];
    final json = base is Map<String, dynamic> ? {...base, ...envelope} : envelope;
    // 排行榜把哈希放在 audio_info，云歌单则常把 hash 和 mixsongid 放在外层。
    if (json['audio_info'] is Map ||
        (json['FileHash'] == null &&
            (json['hash'] != null || json['hash_128'] != null || json['songname'] != null))) {
      return _fromCatalogJson(json);
    }
    final song = Song.fromJson(json);
    return song.hash.isEmpty ? null : song;
  }

  /// 榜单、云歌单与公开歌单里的单曲。
  static Song? _fromCatalogJson(Map<String, dynamic> json) {
    final audio = json['audio_info'] is Map
        ? (json['audio_info'] as Map).cast<String, dynamic>()
        : const <String, dynamic>{};
    final rawAlbum = json['album_info'] ?? json['albuminfo'];
    final album = rawAlbum is Map
        ? rawAlbum.cast<String, dynamic>()
        : const <String, dynamic>{};
    final albumId = _firstPositiveInt(json, const ['album_id', 'albumid']);

    final hash = [json['hash_128'], json['hash'], audio['hash_128'], audio['hash']]
        .map(_normalizeHash)
        .firstWhere((value) => value.isNotEmpty, orElse: () => '');
    if (hash.isEmpty) return null;

    final singers = <String>[];
    for (final authors in [json['authors'], json['singerinfo']]) {
      if (authors is! List) continue;
      for (final author in authors.whereType<Map<String, dynamic>>()) {
        final name = _firstNonEmpty(author, const ['author_name', 'name']);
        if (name.isNotEmpty) singers.add(name);
      }
      if (singers.isNotEmpty) break;
    }

    var title = _firstNonEmpty(
      json,
      const ['songname', 'filename', 'name', 'audio_name'],
    );
    if (title.isEmpty) {
      title = _firstNonEmpty(audio, const ['songname', 'filename', 'name']);
    }
    title = title.replaceFirst(
      RegExp(r'\.(mp3|flac|wav|aac|m4a|ape)$', caseSensitive: false),
      '',
    );
    final separator = title.indexOf(' - ');
    if (singers.isEmpty) {
      final artist = _firstNonEmpty(
        json,
        const ['author_name', 'singername', 'singer'],
      );
      if (artist.isNotEmpty) {
        singers.add(artist);
      } else if (separator > 0) {
        singers.add(title.substring(0, separator));
      }
    }
    if (separator > 0 &&
        (json['songname'] == null || singers.contains(title.substring(0, separator)))) {
      title = title.substring(separator + 3);
    }

    final downloads = json['download'];
    final firstDownload = downloads is List ? downloads.firstOrNull : null;
    return Song(
      hash: hash,
      title: title.isEmpty ? '未知歌曲' : title,
      // audio_id 和 fileid 是另外的编号，不能用来替代 mixsongid。
      albumAudioId: _firstPositiveInt(json, const ['album_audio_id', 'mixsongid']),
      albumId: albumId > 0
          ? albumId
          : _firstPositiveInt(album, const ['album_id', 'id']),
      albumName: _string(json['album_name']).isNotEmpty
          ? _string(json['album_name'])
          : _firstNonEmpty(album, const ['album_name', 'name']),
      albumImage: _cover(json, const ['album_sizable_cover', 'album_cover', 'cover', 'pic', 'img']),
      singers: singers,
      // 歌单与榜单的时长是毫秒，搜索结果的 Duration 是秒。
      duration: Duration(
        milliseconds: _int(json['timelen']) ??
            _int(json['timelength']) ??
            ((_int(json['time_length']) ?? 0) > 0 ? _int(json['time_length'])! * 1000 : null) ??
            _int(audio['duration_128']) ??
            _int(json['duration_128']) ??
            _int(audio['duration']) ??
            0,
      ),
      hash320: _normalizeHash(audio['hash_320'] ?? json['hash_320']),
      hashFlac: _normalizeHash(audio['hash_flac'] ?? json['hash_flac']),
      privilege: _int(json['privilege']) ??
          _int(json['media_privilege']) ??
          _rankPrivilege(json),
      payType: (firstDownload is Map
              ? _int(firstDownload['pay_type'] ?? firstDownload['PayType'])
              : null) ??
          _int(json['pay_type']) ??
          _int(json['media_pay_type']) ??
          0,
      fileId: _firstPositiveInt(json, const ['fileid', 'file_id']),
    );
  }

  /// 不同歌曲接口把图放在专辑、音频或传输参数中。
  static String _cover(Map<String, dynamic> json, List<String> keys) {
    final album = json['album_info'] ?? json['albuminfo'] ?? json['AlbumInfo'];
    final audio = json['audio_info'];
    final transfer = json['trans_param'];
    return [
      for (final key in keys) json[key],
      if (album is Map) ...[album['sizable_cover'], album['cover']],
      if (audio is Map) ...[audio['img'], audio['cover']],
      if (transfer is Map) transfer['union_cover'],
    ].whereType<String>().firstWhere(
      (value) => resolveCoverUrl(value).isNotEmpty,
      orElse: () => '',
    );
  }

  /// 排行榜的权限信息在 `privilege_download` 里，取标准音质的档位。
  static int _rankPrivilege(Map<String, dynamic> json) {
    final privilege = json['privilege_download'];
    if (privilege is! Map) return 1;
    return _int(privilege['privilege_128']) ??
        _int(privilege['privilege']) ??
        1;
  }

  static String _string(Object? value) =>
      value is String ? value : (value?.toString() ?? '');

  static String _firstNonEmpty(Map<String, dynamic> json, List<String> keys) {
    for (final key in keys) {
      final value = _string(json[key]);
      if (value.isNotEmpty) return value;
    }
    return '';
  }

  /// `FileHash` 为 `0`/空表示该音质不存在，统一成空串方便判断。
  static String _normalizeHash(Object? value) {
    final hash = _string(value).toUpperCase();
    return hash == '0' ? '' : hash;
  }

  /// 按顺序取第一个**大于 0** 的整数字段。
  ///
  /// 不能写成 `a ?? b`：酷狗常在同一个响应里同时给出 `"AlbumAudioID": "0"`
  /// 和 `"Audioid": 20505418`，`??` 只看是否为 null，会把 "0" 当成有效值，
  /// 真正有用的那个字段就永远取不到。
  static int _firstPositiveInt(Map<String, dynamic> json, List<String> keys) {
    for (final key in keys) {
      final value = _int(json[key]);
      if (value != null && value > 0) return value;
    }
    return 0;
  }

  static int? _int(Object? value) {
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }
}

/// 歌单（含用户自建歌单、推荐歌单、排行榜）。
class Playlist {
  const Playlist({
    required this.globalCollectionId,
    required this.name,
    required this.listId,
    this.userId = 0,
    this.cover = '',
    this.songCount = 0,
    this.description = '',
    this.creator = '',
    this.creatorUserId = 0,
    this.originalCollectionId = '',
    this.source = 0,
    this.type = 0,
    this.isDefault = false,
    this.totalVersion,
    this.sort,
    this.tags,
  });

  /// 跨账号的歌单 ID。收藏条目可能有自己的 ID，原歌单另存于 originalCollectionId。
  final String globalCollectionId;

  /// 歌单在某个用户下的编号，酷狗的 `listid` 用的是这个。
  final int listId;

  final String name;
  final int userId;
  final String cover;
  final int songCount;
  final String description;
  final String creator;
  final int creatorUserId;
  final String originalCollectionId;
  final int source;
  final int type;
  final bool isDefault;
  final int? totalVersion;
  final int? sort;
  final String? tags;

  String get id => globalCollectionId.isNotEmpty
      ? globalCollectionId
      : '$userId:$listId';

  String get trackCollectionId => originalCollectionId.isNotEmpty
      ? originalCollectionId
      : globalCollectionId;

  /// 云歌单只能按当前账号的 listid 读取，收藏别人的歌单需要查询原歌单。
  int? cloudListIdFor(int userid) {
    if (source == 2 || (creatorUserId > 0 && creatorUserId != userid)) {
      return null;
    }
    final collection = RegExp(r'^collection_3_(\d+)_(\d+)_\d+$')
        .firstMatch(trackCollectionId);
    if (collection != null) {
      if (int.tryParse(collection[1]!) != userid) return null;
      final originalListId = int.tryParse(collection[2]!);
      if (originalListId != null && originalListId > 0) return originalListId;
    }
    return listId > 0 && (creatorUserId == userid || userId == userid)
        ? listId
        : null;
  }

  factory Playlist.fromJson(Map<String, dynamic> json) {
    final listId =
        _int(json['listid']) ?? _int(json['list_id']) ?? _int(json['rankid']) ?? 0;
    final userId = _int(json['userid']) ?? _int(json['user_id']) ?? 0;
    final globalId = _str(json['global_collection_id']);
    final gid = globalId.isNotEmpty ? globalId : _str(json['gid']);
    final creatorUserId = _int(json['list_create_userid']) ?? 0;
    final creatorListId = _int(json['list_create_listid']) ?? 0;
    final source = _int(json['source']) ?? 0;
    final originalGid = _str(json['list_create_gid']);
    return Playlist(
      // 自己建的歌单可能没有 global_collection_id，用 userid:listid 兜底；
      // 排行榜则用 rankid，两者都是取歌曲列表时需要的 key。
      globalCollectionId: gid.isNotEmpty
          ? gid
          : (listId == 0 ? '' : (userId == 0 ? '$listId' : '$userId:$listId')),
      listId: listId,
      name: _str(json['name']).isNotEmpty
          ? _str(json['name'])
          : _str(json['specialname']),
      userId: userId,
      cover: _str(json['pic']),
      songCount: _int(json['song_count']) ??
          _int(json['songcount']) ??
          _int(json['count']) ??
          0,
      description: _str(json['intro']),
      creator: _str(json['nickname']),
      creatorUserId: creatorUserId,
      // 旧收藏记录可能只有原创建者与列表编号，也足够组成公开歌单 ID。
      originalCollectionId: originalGid.isEmpty &&
              source != 2 &&
              creatorUserId > 0 &&
              creatorListId > 0 &&
              creatorUserId != userId
          ? 'collection_3_${creatorUserId}_${creatorListId}_0'
          : originalGid,
      source: source,
      type: _int(json['type']) ?? 0,
      isDefault: const [1, 2].contains(_int(json['is_def'])) ||
          _int(json['is_default']) == 1 ||
          json['name'] == '我喜欢',
      totalVersion: _int(json['total_ver']),
      sort: _int(json['sort']),
      tags: json['tags'] is String ? json['tags'] as String : null,
    );
  }

  static String _str(Object? value) => value is String ? value : '';

  static int? _int(Object? value) {
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }
}

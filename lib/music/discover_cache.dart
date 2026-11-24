import 'dart:convert';

import '../player/session_store.dart';
import 'song.dart';

/// 保存发现页上次成功加载的列表。私人推荐按账号隔离，离线时也能先展示。
class DiscoverCache {
  DiscoverCache(this._store);

  final SessionStore? _store;
  final _memory = <String, String>{};

  List<Song>? readFm(int? userid) => _read('fm', userid, _decodeSong);
  List<Song>? readDaily(int? userid) => _read('daily', userid, _decodeSong);
  List<Playlist>? readPlaylists(int? userid) =>
      _read('playlists', userid, Playlist.fromJson);

  void saveFm(int userid, List<Song> songs) =>
      _save('fm', userid, songs.map(_encodeSong));
  void saveDaily(int? userid, List<Song> songs) =>
      _save('daily', userid, songs.map(_encodeSong));
  void savePlaylists(int? userid, List<Playlist> lists) =>
      _save('playlists', userid, lists.map(_encodePlaylist));

  String _key(String section, int? userid) =>
      'discover.v1.$section.${userid ?? 'guest'}';

  List<T>? _read<T>(
    String section,
    int? userid,
    T Function(Map<String, dynamic>) decode,
  ) {
    final key = _key(section, userid);
    try {
      final encoded = _memory[key] ?? _store?.readPreference(key);
      if (encoded == null) return null;
      final rows = jsonDecode(encoded) as List<dynamic>;
      return [for (final row in rows) decode(row as Map<String, dynamic>)];
    } catch (_) {
      // 损坏或不可读的缓存等同于首次加载。
      return null;
    }
  }

  void _save(String section, int? userid, Iterable<Map<String, Object?>> rows) {
    final key = _key(section, userid);
    final encoded = jsonEncode(rows.toList());
    _memory[key] = encoded;
    try {
      _store?.savePreference(key, encoded);
    } catch (_) {
      // 磁盘不可写时仍可展示刚取得的数据，并保留本次运行的缓存。
    }
  }

  // 保留精确的时长和播放所需的标识，下次打开时缓存卡片也能直接点播。
  static Map<String, Object?> _encodeSong(Song song) => {
    'hash': song.hash,
    'title': song.title,
    'albumAudioId': song.albumAudioId,
    'albumId': song.albumId,
    'albumName': song.albumName,
    'albumImage': song.albumImage,
    'singers': song.singers,
    'durationUs': song.duration.inMicroseconds,
    'hash320': song.hash320,
    'hashFlac': song.hashFlac,
    'privilege': song.privilege,
    'payType': song.payType,
    'fileId': song.fileId,
  };

  static Song _decodeSong(Map<String, dynamic> row) => Song(
    hash: row['hash'] as String,
    title: row['title'] as String,
    albumAudioId: row['albumAudioId'] as int,
    albumId: row['albumId'] as int,
    albumName: row['albumName'] as String,
    albumImage: row['albumImage'] as String,
    singers: (row['singers'] as List<dynamic>).cast<String>(),
    duration: Duration(microseconds: row['durationUs'] as int),
    hash320: row['hash320'] as String,
    hashFlac: row['hashFlac'] as String,
    privilege: row['privilege'] as int,
    payType: row['payType'] as int,
    fileId: row['fileId'] as int,
  );

  // 沿用歌单接口的字段名，通过已有的 Playlist.fromJson 还原。
  static Map<String, Object?> _encodePlaylist(Playlist list) => {
    'global_collection_id': list.globalCollectionId,
    'name': list.name,
    'listid': list.listId,
    'userid': list.userId,
    'pic': list.cover,
    'song_count': list.songCount,
    'intro': list.description,
    'nickname': list.creator,
    'list_create_userid': list.creatorUserId,
    'list_create_gid': list.originalCollectionId,
    'source': list.source,
    'type': list.type,
    'is_default': list.isDefault ? 1 : 0,
    'total_ver': list.totalVersion,
    'sort': list.sort,
    'tags': list.tags,
  };
}

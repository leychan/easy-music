import '../account/kugou/kugou_auth.dart' show KugouFailure, KugouSession;
import 'kugou_music_api.dart';
import 'song.dart';

extension KugouPlaylistApi on KugouMusicApi {
  static const _gateway = 'https://gateway.kugou.com';
  static const _cloud = {'x-router': 'cloudlist.service.kugou.com'};

  Future<void> createPlaylist(String name) async {
    final session = _requirePlaylistSession();
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final result = await client.post(
      Uri.parse('$_gateway/cloudlist.service/v5/add_list'),
      extraParams: {'last_time': now, 'last_area': 'gztx'},
      body: {
        'userid': session.userid,
        'token': session.token,
        'total_ver': 0,
        'name': name,
        'type': 0,
        'source': 1,
        'is_pri': 0,
        'list_create_gid': '',
        'from_shupinmv': 0,
      },
    );
    _checkMutation(result, '新建歌单');
  }

  Future<void> addPlaylistSong(Playlist playlist, Song song) =>
      addPlaylistSongs(playlist, [song]);

  Future<void> addPlaylistSongs(Playlist playlist, List<Song> songs) async {
    final session = _requirePlaylistSession();
    final listId = _editableList(playlist, session);
    if (songs.any((song) => !song.playable)) {
      throw const KugouFailure('歌曲缺少酷狗曲目编号。');
    }
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final result = await client.post(
      Uri.parse('$_gateway/cloudlist.service/v6/add_song'),
      extraParams: {'last_time': now, 'last_area': 'gztx'},
      body: {
        'userid': session.userid,
        'token': session.token,
        'listid': listId,
        'list_ver': 0,
        'type': 0,
        'slow_upload': 1,
        'scene': 'false;null',
        'data': [
          for (final song in songs)
            {
              'number': 1,
              'name': '${song.artist} - ${song.title}',
              'hash': song.hash,
              'size': 0,
              'sort': 0,
              'timelen': 0,
              'bitrate': 0,
              'album_id': song.albumId,
              'mixsongid': song.albumAudioId,
            },
        ],
      },
    );
    _checkMutation(result, '添加歌曲');
  }

  Future<void> removePlaylistSong(Playlist playlist, Song song) async {
    final session = _requirePlaylistSession();
    final listId = _editableList(playlist, session);
    if (song.fileId <= 0) throw const KugouFailure('请刷新歌单后再移除这首歌曲。');
    final result = await client.post(
      Uri.parse('$_gateway/v4/delete_songs'),
      headers: _cloud,
      body: {
        'listid': listId,
        'userid': session.userid,
        'token': session.token,
        'type': 0,
        'list_ver': 0,
        'data': [
          {'fileid': song.fileId},
        ],
      },
    );
    _checkMutation(result, '移除歌曲');
  }

  Future<void> editPlaylist(
    Playlist playlist,
    String name,
    String description,
  ) async {
    final session = _requirePlaylistSession();
    final listId = _editableList(playlist, session);
    if (playlist.isDefault) throw const KugouFailure('系统歌单不能编辑。');
    final fresh = (await userPlaylists(pageSize: 200))
        .where((item) => item.listId == listId)
        .firstOrNull;
    if (!identical(client.session, session)) {
      throw const KugouFailure('账号已变化，请重新打开歌单。');
    }
    if (fresh == null || fresh.totalVersion == null || fresh.sort == null) {
      throw const KugouFailure('无法读取歌单版本，请刷新后重试。');
    }
    String? tags = fresh.tags;
    if (tags == null) {
      final details = await client.post(
        Uri.parse('$_gateway/v3/get_list_info'),
        body: {
          'data': [
            {'global_collection_id': fresh.trackCollectionId},
          ],
          'userid': session.userid,
          'token': session.token,
        },
        headers: {'x-router': 'pubsongs.kugou.com'},
      );
      final data = details['data'];
      final row = data is List ? data.firstOrNull : null;
      if (row is Map && row['tags'] is String) tags = row['tags'] as String;
      if (tags == null) {
        throw const KugouFailure('酷狗没有返回歌单标签，请刷新后重试。');
      }
    }
    if (!identical(client.session, session)) {
      throw const KugouFailure('账号已变化，请重新打开歌单。');
    }
    final result = await client.cloudPost(
      Uri.parse('$_gateway/v1/modify_list'),
      body: {
        'total_ver': fresh.totalVersion,
        'listid': listId,
        'type': fresh.type,
        'sort': fresh.sort,
        'tags': tags,
        'intro': description,
        'name': name,
      },
    );
    _checkMutation(result, '编辑歌单');
  }

  KugouSession _requirePlaylistSession() =>
      client.session ?? (throw const KugouFailure('请先登录酷狗账号。'));

  static int _editableList(Playlist playlist, KugouSession session) {
    final id = playlist.cloudListIdFor(session.userid);
    if (id == null || (playlist.type != 0 && !playlist.isDefault)) {
      throw const KugouFailure('请选择自己创建的酷狗歌单。');
    }
    return id;
  }

  static void _checkMutation(Map<String, dynamic> json, String action) {
    if (json['status']?.toString() == '1' &&
        (json['error_code'] == null || json['error_code'].toString() == '0')) {
      return;
    }
    final message = json['error_msg'] ?? json['message'] ?? json['msg'];
    throw KugouFailure(
      message is String && message.isNotEmpty
          ? '$action失败（$message）。'
          : '$action失败，请稍后重试。',
    );
  }
}

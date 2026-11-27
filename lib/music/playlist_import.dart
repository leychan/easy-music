import 'dart:convert';

import 'package:http/http.dart' as http;

import '../account/kugou/kugou_auth.dart';
import 'song.dart';

class ImportTrack {
  const ImportTrack(this.title, this.artists, {this.song});
  final String title;
  final String artists;
  final Song? song;
}

class ImportPreview {
  const ImportPreview(this.title, this.tracks, {this.format});
  final String title;
  final List<ImportTrack> tracks;
  final String? format;
}

/// 只读取公开歌单的曲目信息，导入时在当前酷狗曲库里匹配。
class PublicPlaylistImport {
  const PublicPlaylistImport(this._kugouTracks);
  final Future<List<Song>> Function(Playlist) _kugouTracks;
  static const _userAgent =
      'Mozilla/5.0 (X11; Linux x86_64) Chrome/120.0.0.0 Safari/537.36';

  Future<ImportPreview> read(String text) async {
    final client = http.Client();
    try {
      // 分享时通常会带上歌单名称和说明，只解析其中的公开链接。
      final links = RegExp(r'''https?://[^\s<>"“”《》【】。，；！？]+''', caseSensitive: false);
      final trailing = RegExp(r'''[)\]）』」,.;!?'’]+$''');
      var hasLink = false;
      for (final match in links.allMatches(text)) {
        final url = Uri.tryParse(match[0]!.replaceFirst(trailing, ''));
        if (url == null || url.host.isEmpty || url.userInfo.isNotEmpty) continue;
        hasLink = true;
        final preview = await _readUrl(client, url);
        if (preview != null) return preview;
      }
      if (!hasLink) throw const KugouFailure('请粘贴包含公开歌单链接的分享文字或完整链接。');
      throw const KugouFailure('无法识别歌单链接。请使用酷狗、网易云、QQ 音乐、酷我或 Spotify 的公开歌单链接。');
    } on FormatException {
      throw const KugouFailure('来源平台返回的歌单格式无法读取。');
    } finally {
      client.close();
    }
  }

  Future<ImportPreview?> _readUrl(http.Client client, Uri url) async {
    final host = url.host.toLowerCase();
    bool from(String root) => host == root || host.endsWith('.$root');
    final path = url.path;
    final fragment = Uri.tryParse(url.fragment);
    final query = {...?fragment?.queryParameters, ...url.queryParameters};
    String id(List<String> names, RegExp pattern) {
      for (final key in names) {
        final value = query[key];
        if (value != null && RegExp(r'^[a-zA-Z0-9_]+$').hasMatch(value)) {
          return value;
        }
      }
      return pattern.firstMatch(path)?[1] ?? '';
    }

    if (from('kugou.com')) {
      final gid = id([
        'global_collection_id',
        'global_specialid',
      ], RegExp(r'/special/single/([a-zA-Z0-9_]+)\.html$'));
      if (gid.isNotEmpty) {
        final tracks = await _kugouTracks(
          Playlist(globalCollectionId: gid, name: '酷狗歌单', listId: 0),
        );
        return ImportPreview('酷狗歌单', [
          for (final song in tracks)
            ImportTrack(song.title, song.artist, song: song),
        ]);
      }
    } else if (from('music.163.com')) {
      final source = id(['id'], RegExp(r'/playlist/(\d+)'));
      if (_number(source)) return await _netease(client, source);
    } else if (from('y.qq.com')) {
      final source = id(['id', 'disstid'], RegExp(r'/playlist/(\d+)'));
      if (_number(source)) return await _qq(client, source);
    } else if (host == 'open.spotify.com') {
      final source = id([], RegExp(r'/playlist/([a-zA-Z0-9]{22})(?:/|$)'));
      if (source.isNotEmpty) return await _spotify(client, source);
    } else if (from('kuwo.cn') || from('kuwo.com')) {
      final source = id([
        'pid',
      ], RegExp(r'/(?:playlist_detail|play_detail|playlist)/(\d+)'));
      if (_number(source)) return await _kuwo(client, source);
    }
    return null;
  }

  static bool _number(String id) => RegExp(r'^\d+$').hasMatch(id);

  static Future<String> _get(
    http.Client client,
    Uri uri, {
    String? referer,
  }) async {
    final result = await client
        .get(uri, headers: {'user-agent': _userAgent, 'referer': ?referer})
        .timeout(const Duration(seconds: 15));
    if (result.statusCode != 200) throw const KugouFailure('来源平台无法读取这份公开歌单。');
    return utf8.decode(result.bodyBytes, allowMalformed: true);
  }

  static Future<ImportPreview> _netease(http.Client client, String id) async {
    const referer = 'https://music.163.com/';
    final url = Uri.https('music.163.com', '/api/v6/playlist/detail', {
      'id': id,
      'n': '100000',
    });
    final body = _map(jsonDecode(await _get(client, url, referer: referer)));
    final playlist = _map(body['playlist']);
    final songs = <String, Map>{
      for (final track in _rows(playlist['tracks']))
        track['id'].toString(): track,
    };
    final order = _rows(playlist['trackIds'])
        .map((row) => row['id'].toString())
        .toList();
    final missing = order.where((id) => !songs.containsKey(id)).toList();
    for (var index = 0; index < missing.length; index += 100) {
      final batch = missing.skip(index).take(100);
      final response = await client
          .post(
            Uri.https('music.163.com', '/api/v3/song/detail'),
            headers: {'referer': referer, 'user-agent': _userAgent},
            body: {
              'c': jsonEncode([
                for (final id in batch) {'id': id},
              ]),
            },
          )
          .timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) {
        throw const KugouFailure('网易云没有返回完整的曲目列表。');
      }
      for (final row in _rows(_map(jsonDecode(response.body))['songs'])) {
        songs[row['id'].toString()] = row;
      }
    }
    final rows = order.isEmpty
        ? songs.values
        : order.map((id) => songs[id]).whereType<Map>();
    return _preview(
      playlist['name'],
      rows.map(
        (row) => ImportTrack(
          _text(row['name']),
          _names(row['ar'] ?? row['artists']),
        ),
      ),
    );
  }

  static Future<ImportPreview> _qq(http.Client client, String id) async {
    final url = Uri.https(
      'c.y.qq.com',
      '/qzone/fcg-bin/fcg_ucc_getcdinfo_byids_cp.fcg',
      {
        'type': '1',
        'disstid': id,
        'format': 'json',
        'utf8': '1',
        'outCharset': 'utf-8',
      },
    );
    final json = _map(
      jsonDecode(await _get(client, url, referer: 'https://y.qq.com/')),
    );
    final playlist = _rows(json['cdlist']).firstOrNull ?? const {};
    return _preview(
      playlist['dissname'],
      _rows(playlist['songlist']).map(
        (row) => ImportTrack(
          _text(row['songname'] ?? row['title']),
          _names(row['singer']),
        ),
      ),
    );
  }

  static Future<ImportPreview> _spotify(http.Client client, String id) async {
    final html = await _get(
      client,
      Uri.https('open.spotify.com', '/embed/playlist/$id'),
    );
    final tag = RegExp(
      r'<script[^>]*id="__NEXT_DATA__"[^>]*>([\s\S]*?)</script>',
    ).firstMatch(html);
    if (tag == null) throw const FormatException('Spotify playlist data');
    Object? entity = jsonDecode(tag[1]!);
    for (final key in ['props', 'pageProps', 'state', 'data', 'entity']) {
      entity = _map(entity)[key];
    }
    final playlist = _map(entity);
    return _preview(
      playlist['name'],
      _rows(
        playlist['trackList'],
      ).map((row) => ImportTrack(_text(row['title']), _text(row['subtitle']))),
    );
  }

  static Future<ImportPreview> _kuwo(http.Client client, String id) async {
    final collected = <ImportTrack>[];
    final seen = <String>{};
    String name = '';
    for (var page = 1; ; page++) {
      final uri = Uri.https('wapi.kuwo.cn', '/api/www/playlist/playListInfo', {
        'pid': id,
        'pn': '$page',
        'rn': '100',
      });
      final json = _map(jsonDecode(await _get(client, uri)));
      final data = _map(json['data']);
      if (json['code']?.toString() != '200') {
        throw const KugouFailure('酷我无法读取这份公开歌单。');
      }
      name = _text(data['title'] ?? data['name']);
      final items = _rows(data['musicList']).toList();
      if (items.isNotEmpty &&
          !seen.add(
            items.first['rid']?.toString() ?? _text(items.first['name']),
          )) {
        break;
      }
      collected.addAll(
        items.map(
          (row) => ImportTrack(
            _text(row['name'] ?? row['songName']),
            _text(row['artist'] ?? row['singer']),
          ),
        ),
      );
      final total = int.tryParse(_text(data['total'])) ?? 0;
      if (items.length < 100 || (total > 0 && collected.length >= total)) break;
    }
    return _preview(name, collected);
  }

  static Map _map(Object? value) => value is Map ? value : const {};
  static Iterable<Map> _rows(Object? value) =>
      value is List ? value.whereType<Map>() : const [];
  static String _text(Object? value) => value?.toString().trim() ?? '';
  static String _names(Object? value) =>
      _rows(value)
          .map((row) => _text(row['name']))
          .where((name) => name.isNotEmpty)
          .join('、');

  static ImportPreview _preview(Object? name, Iterable<ImportTrack> tracks) {
    final items = tracks.where((track) => track.title.isNotEmpty).toList();
    if (items.isEmpty) throw const KugouFailure('来源歌单为空或无法公开读取。');
    final title = _text(name);
    return ImportPreview(title.isEmpty ? '外部歌单' : title, items);
  }
}

import 'song.dart';

enum SearchType {
  song('song', '歌曲'),
  artist('author', '歌手'),
  album('album', '专辑'),
  playlist('special', '歌单'),
  lyric('lyric', '歌词'),
  video('mv', 'MV');

  const SearchType(this.apiName, this.label);
  final String apiName;
  final String label;
}

typedef CatalogSearchResult<T> = ({T hits, bool hasMore});

CatalogSearchResult<List<T>> parseCatalogSearch<T>(
  Object? data,
  T? Function(Map<String, dynamic>) parse, {
  required int page,
  required int pageSize,
}) {
  final rows = data is Map ? data['lists'] : data;
  if (rows is! List || rows.isEmpty) return (hits: <T>[], hasMore: false);
  final total = data is Map ? int.tryParse('${data['total']}') : null;
  return (
    hits: rows.whereType<Map<String, dynamic>>().map(parse).whereType<T>().toList(),
    // 用原始结果数判断翻页，避免跳过不可解析的条目后提前结束。
    hasMore: total != null ? page * pageSize < total : rows.length >= pageSize,
  );
}

class CatalogHit {
  const CatalogHit({
    required this.id,
    required this.title,
    this.subtitle = '',
    this.cover = '',
    this.description = '',
    this.song,
    this.playlist,
  });

  final String id;
  final String title;
  final String subtitle;
  final String cover;
  final String description;
  final Song? song;
  final Playlist? playlist;

  factory CatalogHit.track(Song song, {String description = ''}) => CatalogHit(
    id: song.id,
    title: song.title,
    subtitle: song.artist,
    cover: song.coverUrl(),
    description: description,
    song: song,
  );

  static CatalogHit? fromJson(SearchType type, Map<String, dynamic> row) {
    String field(String key) => row[key]?.toString().trim() ?? '';
    final hit = switch (type) {
      SearchType.artist => CatalogHit(
        id: field('AuthorId'),
        title: field('AuthorName'),
        subtitle: field('AudioCount').isEmpty ? '' : "${field('AudioCount')} 首",
        cover: field('Avatar'),
      ),
      SearchType.album => CatalogHit(
        id: field('albumid'),
        title: field('albumname'),
        subtitle: field('singer'),
        cover: field('img'),
        description: field('intro'),
      ),
      SearchType.playlist => CatalogHit(
        id: field('gid').isNotEmpty ? field('gid') : field('specialid'),
        title: field('specialname'),
        subtitle: field('nickname'),
        cover: field('img'),
        description: field('intro'),
        playlist: Playlist.fromJson({
          ...row,
          'global_collection_id': field('gid').isNotEmpty
              ? field('gid')
              : field('specialid'),
          'pic': field('img'),
        }),
      ),
      SearchType.video => CatalogHit(
        id: field('MvHash'),
        title: field('MvName').isNotEmpty ? field('MvName') : field('FileName'),
        subtitle: field('SingerName'),
        cover: _videoCover(field('Pic')),
        description: field('Description'),
      ),
      SearchType.song || SearchType.lyric => switch (Song.tryParse(row)) {
        final song? => CatalogHit.track(song, description: field('Lyric')),
        _ => null,
      },
    };
    return hit == null || hit.id.isEmpty || hit.title.isEmpty ? null : hit;
  }

  static String _videoCover(String pic) => pic.isEmpty || pic.startsWith('http')
      ? pic
      : 'https://imge.kugou.com/mvhdpic/400/$pic';
}

class CloudTrack {
  const CloudTrack(this.song, this.fileName, this.audioId, this.userid, {this.fileId});
  final Song song;
  final String fileName;
  final int audioId;
  final int userid;
  final Object? fileId;
  String get id => 'cloud:$userid:${song.hash}';

  static CloudTrack? tryParse(Map<String, dynamic> row, int userid) {
    final audio = row['audio_info'] is Map ? row['audio_info'] as Map : const {};
    String firstText(Iterable<Object?> values) => values
        .whereType<String>().map((value) => value.trim())
        .firstWhere((value) => value.isNotEmpty && value != '0', orElse: () => '');
    int positiveInt(Iterable<Object?> values) => values
        .map((value) => int.tryParse('$value') ?? 0)
        .firstWhere((value) => value > 0, orElse: () => 0);

    // 播放云盘原文件使用上传哈希；曲库 hash_std 和高低音质哈希可能指向其他文件。
    final hash = firstText([row['hash'], audio['hash'], row['hash_128'], audio['hash_128'], row['FileHash']]);
    final albumAudioId = positiveInt([row['album_audio_id'], row['mixsongid'], audio['album_audio_id']]);
    final millis = positiveInt([row['timelen'], row['timelength'], audio['duration_128']]);
    final seconds = positiveInt([row['duration'], audio['duration']]);
    final song = Song.tryParse({
      ...row,
      if (hash.isNotEmpty) ...{'hash': hash, 'hash_128': hash},
      if (albumAudioId > 0) 'album_audio_id': albumAudioId,
      if (millis > 0 || seconds > 0) 'timelen': millis > 0 ? millis : seconds * 1000,
    });
    if (song == null) return null;
    final fileName = firstText([row['filename'], row['name'], row['songname'], audio['filename']]);
    final fileId = [row['kv_id'], row['kvid'], row['cloud_file_id']]
        .where((value) => (value is String && value.trim().isNotEmpty && value != '0') ||
            (value is int && value > 0))
        .firstOrNull;
    return CloudTrack(
      song, fileName.isEmpty ? song.title : fileName,
      positiveInt([row['audio_id'], row['audioid'], audio['audio_id'], audio['audioid']]),
      userid, fileId: fileId,
    );
  }
}

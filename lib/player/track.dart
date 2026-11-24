import 'package:path/path.dart' as p;

import 'audio_quality.dart';

class Track {
  const Track({
    required this.id,
    required this.title,
    required this.source,
    this.lyrics,
    this.duration = Duration.zero,
    this.artist = '',
    this.artUri,
    this.albumAudioId = 0,
    this.albumId = 0,
    this.audioQuality,
  });

  final String id;
  final String title;
  final Uri source;
  final String? lyrics;

  /// 时长在进队列时就已知（酷狗接口会给），本地文件则要等解码后才有。
  final Duration duration;

  /// 歌手。本地文件通常拿不到，留空。
  final String artist;

  /// 封面图地址。
  final Uri? artUri;

  /// 酷狗曲目重播时用这两个编号申请新的播放地址。
  final int albumAudioId;
  final int albumId;
  final AudioQuality? audioQuality;

  bool get isCloud => id.startsWith('cloud:');

  bool get isLocal => !isCloud &&
      kugouHash == null && source.scheme != 'http' && source.scheme != 'https';

  /// 酷狗曲目的队列 ID 已包含歌词查询所需的哈希，旧队列也可以直接使用。
  String? get kugouHash =>
      id.startsWith('kg:') && id.length > 3 ? id.substring(3) : null;

  /// 云盘曲目的 ID 末尾也保存了原始音频哈希。
  String? get lyricHash {
    final cloudHash = isCloud ? id.split(':').elementAtOrNull(2) : null;
    return cloudHash == null || cloudHash.isEmpty ? kugouHash : cloudHash;
  }

  Track copyWith({
    Uri? source,
    Uri? artUri,
    String? lyrics,
    Duration? duration,
    int? albumAudioId,
    int? albumId,
    AudioQuality? audioQuality,
  }) => Track(
    id: id,
    title: title,
    source: source ?? this.source,
    lyrics: lyrics ?? this.lyrics,
    duration: duration ?? this.duration,
    artist: artist,
    artUri: artUri ?? this.artUri,
    albumAudioId: albumAudioId ?? this.albumAudioId,
    albumId: albumId ?? this.albumId,
    audioQuality: audioQuality ?? this.audioQuality,
  );

  factory Track.online(String id, String input) {
    final uri = Uri.tryParse(input.trim());
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      throw const FormatException('请输入有效的 HTTPS 音频直链。');
    }
    final name = uri.pathSegments.where((segment) => segment.isNotEmpty);
    return Track(
      id: id,
      title: name.isEmpty ? uri.host : p.basenameWithoutExtension(name.last),
      source: uri,
    );
  }
}

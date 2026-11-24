import 'dart:convert';

import 'package:audio_service/audio_service.dart' show AudioServiceRepeatMode;
import 'package:sqlite3/sqlite3.dart';

import '../music/song.dart' show resolveCoverUrl;
import 'audio_quality.dart';
import 'track.dart';

class SavedSession {
  const SavedSession(this.tracks, this.index, this.position);

  final List<Track> tracks;
  final int index;
  final Duration position;
}

class PlayedTrack {
  const PlayedTrack(this.track, this.playedAt);

  final Track track;
  final DateTime playedAt;
}

class ListeningCount {
  const ListeningCount(this.title, this.artist, this.count);
  final String title;
  final String artist;
  final int count;
}

class SessionStore {
  SessionStore(String path) : _database = sqlite3.open(path) {
    _database.execute('''
      CREATE TABLE IF NOT EXISTS queue (
        slot INTEGER PRIMARY KEY,
        id TEXT NOT NULL UNIQUE,
        title TEXT NOT NULL,
        source TEXT NOT NULL,
        lyrics TEXT
      );
      CREATE TABLE IF NOT EXISTS playback (
        singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
        queue_index INTEGER NOT NULL,
        position_ms INTEGER NOT NULL
      );
      CREATE TABLE IF NOT EXISTS playback_settings (
        singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
        repeat_mode TEXT NOT NULL,
        speed REAL NOT NULL,
        volume REAL NOT NULL DEFAULT 1,
        audio_quality TEXT NOT NULL DEFAULT '128'
      );
      CREATE TABLE IF NOT EXISTS playback_history (
        id TEXT PRIMARY KEY,
        title TEXT NOT NULL,
        source TEXT NOT NULL,
        lyrics TEXT,
        artist TEXT,
        art_uri TEXT,
        duration_ms INTEGER,
        album_audio_id INTEGER NOT NULL,
        album_id INTEGER NOT NULL,
        played_at_us INTEGER NOT NULL
      );
      CREATE TABLE IF NOT EXISTS playback_stats (
        id TEXT PRIMARY KEY,
        title TEXT NOT NULL,
        artist TEXT NOT NULL,
        play_count INTEGER NOT NULL,
        played_at_us INTEGER NOT NULL
      );
      CREATE TABLE IF NOT EXISTS app_preferences (
        name TEXT PRIMARY KEY,
        value TEXT NOT NULL
      );
    ''');
    // 后加的列：老库没有它们，按需补上，否则升级后插不进去。
    _addColumn('queue', 'artist', 'TEXT');
    _addColumn('queue', 'art_uri', 'TEXT');
    _addColumn('queue', 'duration_ms', 'INTEGER');
    _addColumn('queue', 'album_audio_id', 'INTEGER NOT NULL DEFAULT 0');
    _addColumn('queue', 'album_id', 'INTEGER NOT NULL DEFAULT 0');
    _addColumn('queue', 'audio_quality', 'TEXT');
    _addColumn('playback_settings', 'volume', 'REAL NOT NULL DEFAULT 1');
    _addColumn('playback_settings', 'audio_quality', "TEXT NOT NULL DEFAULT '128'");
  }

  final Database _database;
  static const _historyLimit = 100;

  String? readPreference(String name) =>
      _database.select('SELECT value FROM app_preferences WHERE name = ?', [name])
          .firstOrNull?['value'] as String?;

  void savePreference(String name, String value) => _database.execute(
    'INSERT INTO app_preferences (name, value) VALUES (?, ?) '
    'ON CONFLICT(name) DO UPDATE SET value = excluded.value',
    [name, value],
  );

  void _addColumn(String table, String column, String type) {
    final columns = _database.select('PRAGMA table_info($table)');
    final exists = columns.any((row) => row['name'] == column);
    if (exists) return;
    _database.execute('ALTER TABLE $table ADD COLUMN $column $type');
  }

  SavedSession read() {
    final rows = _database.select('SELECT * FROM queue ORDER BY slot');
    final tracks = rows.map(_trackFromRow).toList();
    final state = _database.select('SELECT * FROM playback').firstOrNull;
    return SavedSession(
      tracks,
      (state?['queue_index'] as int?) ?? 0,
      Duration(milliseconds: (state?['position_ms'] as int?) ?? 0),
    );
  }

  static Track _trackFromRow(Row row) => Track(
    id: row['id'] as String,
    title: row['title'] as String,
    source: Uri.parse(row['source'] as String),
    lyrics: row['lyrics'] as String?,
    artist: (row['artist'] as String?) ?? '',
    duration: Duration(milliseconds: (row['duration_ms'] as int?) ?? 0),
    artUri: switch (resolveCoverUrl(row['art_uri'] as String? ?? '')) {
      final value when value.isNotEmpty => Uri.tryParse(value),
      _ => null,
    },
    albumAudioId: (row['album_audio_id'] as int?) ?? 0,
    albumId: (row['album_id'] as int?) ?? 0,
    audioQuality: row.containsKey('audio_quality')
        ? AudioQuality.fromApiName(row['audio_quality'])
        : null,
  );

  List<String>? readOriginalQueueOrder() {
    final raw = readPreference('shuffle_original');
    if (raw == null) return null;
    try {
      final decoded = jsonDecode(raw);
      return decoded is List ? decoded.whereType<String>().toList() : null;
    } on FormatException {
      return null;
    }
  }

  void replaceQueue(SavedSession session, {List<String>? originalOrder}) {
    // 队列和播放位置一起提交，避免重启时位置指向旧队列。
    _database.execute('BEGIN');
    try {
      _database.execute('DELETE FROM queue');
      final insert = _database.prepare(
        'INSERT INTO queue (slot, id, title, source, lyrics, artist, art_uri, duration_ms, album_audio_id, album_id, audio_quality) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
      );
      try {
        for (final (slot, track) in session.tracks.indexed) {
          insert.execute([
            slot,
            track.id,
            track.title,
            track.source.toString(),
            track.lyrics,
            track.artist,
            track.artUri?.toString(),
            track.duration.inMilliseconds,
            track.albumAudioId,
            track.albumId,
            track.audioQuality?.apiName,
          ]);
        }
      } finally {
        insert.close();
      }
      savePosition(session.index, session.position);
      savePreference('shuffle_original', jsonEncode(originalOrder));
      _database.execute('COMMIT');
    } catch (_) {
      _database.execute('ROLLBACK');
      rethrow;
    }
  }

  void savePosition(int index, Duration position) {
    _database.execute(
      '''
      INSERT INTO playback VALUES (1, ?, ?)
      ON CONFLICT (singleton) DO UPDATE SET
        queue_index = excluded.queue_index,
        position_ms = excluded.position_ms
    ''',
      [index, position.inMilliseconds],
    );
  }

  ({
    AudioServiceRepeatMode repeatMode,
    double speed,
    double volume,
    AudioQuality preferredQuality,
  }) readSettings() {
    final row = _database.select('SELECT * FROM playback_settings').firstOrNull;
    return (
      repeatMode: switch (row?['repeat_mode']) {
        'one' => AudioServiceRepeatMode.one,
        'all' => AudioServiceRepeatMode.all,
        _ => AudioServiceRepeatMode.none,
      },
      speed: switch (row?['speed']) {
        final num value when value >= 0.5 && value <= 2 => value.toDouble(),
        _ => 1.0,
      },
      volume: switch (row?['volume']) {
        final num value when value >= 0 && value <= 1 => value.toDouble(),
        _ => 1.0,
      },
      preferredQuality:
          AudioQuality.fromApiName(row?['audio_quality']) ?? AudioQuality.standard,
    );
  }

  void saveSettings(
    AudioServiceRepeatMode repeatMode,
    double speed, {
    required double volume,
    required AudioQuality preferredQuality,
  }) {
    _database.execute(
      '''
      INSERT INTO playback_settings (singleton, repeat_mode, speed, volume, audio_quality)
      VALUES (1, ?, ?, ?, ?)
      ON CONFLICT (singleton) DO UPDATE SET
        repeat_mode = excluded.repeat_mode,
        speed = excluded.speed,
        volume = excluded.volume,
        audio_quality = excluded.audio_quality
      ''',
      [repeatMode.name, speed, volume, preferredQuality.apiName],
    );
  }

  List<PlayedTrack> readHistory() => [
    for (final row in _database.select(
      'SELECT * FROM playback_history ORDER BY played_at_us DESC, rowid DESC',
    ))
      PlayedTrack(
        _trackFromRow(row),
        DateTime.fromMicrosecondsSinceEpoch(row['played_at_us'] as int),
      ),
  ];

  /// 补写封面和歌词，保留原来的播放时间与统计次数。
  void updateHistoryDetails(Track track) => _database.execute(
    'UPDATE playback_history SET lyrics = COALESCE(?, lyrics), '
    'art_uri = COALESCE(?, art_uri) WHERE id = ?',
    [track.lyrics, track.artUri?.toString(), track.id],
  );

  void recordPlayed(Track track, DateTime playedAt) {
    // 在线歌曲历史保留曲目身份，重播时重新取地址。
    final hash = track.kugouHash;
    final source = track.isCloud
        ? Uri(scheme: 'kugou-cloud', path: track.id)
        : (hash == null ? track.source : Uri(scheme: 'kugou', path: hash));
    _database.execute('BEGIN');
    try {
      _database.execute(
        '''
        INSERT INTO playback_history
          (id, title, source, lyrics, artist, art_uri, duration_ms, album_audio_id, album_id, played_at_us)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT (id) DO UPDATE SET
          title = excluded.title,
          source = excluded.source,
          lyrics = COALESCE(excluded.lyrics, playback_history.lyrics),
          artist = excluded.artist,
          art_uri = COALESCE(excluded.art_uri, playback_history.art_uri),
          duration_ms = excluded.duration_ms,
          album_audio_id = COALESCE(NULLIF(excluded.album_audio_id, 0), playback_history.album_audio_id),
          album_id = COALESCE(NULLIF(excluded.album_id, 0), playback_history.album_id),
          played_at_us = excluded.played_at_us
        ''',
        [
          track.id, track.title, source.toString(), track.lyrics, track.artist,
          track.artUri?.toString(), track.duration.inMilliseconds,
          track.albumAudioId, track.albumId, playedAt.microsecondsSinceEpoch,
        ],
      );
      _database.execute(
        '''
        INSERT INTO playback_stats (id, title, artist, play_count, played_at_us)
        VALUES (?, ?, ?, 1, ?)
        ON CONFLICT(id) DO UPDATE SET
          title = excluded.title,
          artist = excluded.artist,
          play_count = playback_stats.play_count + 1,
          played_at_us = excluded.played_at_us
        ''',
        [track.id, track.title, track.artist, playedAt.microsecondsSinceEpoch],
      );
      _database.execute(
        '''
        DELETE FROM playback_history WHERE id IN (
          SELECT id FROM playback_history
          ORDER BY played_at_us DESC, rowid DESC LIMIT -1 OFFSET ?
        )
        ''',
        [_historyLimit],
      );
      _database.execute('COMMIT');
    } catch (_) {
      _database.execute('ROLLBACK');
      rethrow;
    }
  }

  void removeHistory(String id) {
    _database.execute('DELETE FROM playback_history WHERE id = ?', [id]);
  }

  ({int plays, int songs, List<ListeningCount> top}) readListeningStats() {
    final totals = _database.select(
      'SELECT COALESCE(SUM(play_count), 0) AS plays, COUNT(*) AS songs FROM playback_stats',
    ).single;
    final top = _database.select(
      'SELECT title, artist, play_count FROM playback_stats '
      'ORDER BY play_count DESC, played_at_us DESC LIMIT 10',
    );
    return (
      plays: totals['plays'] as int,
      songs: totals['songs'] as int,
      top: [
        for (final row in top)
          ListeningCount(row['title'] as String, row['artist'] as String, row['play_count'] as int),
      ],
    );
  }

  void close() => _database.close();
}

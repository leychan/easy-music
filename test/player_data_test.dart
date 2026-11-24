import 'dart:io';

import 'package:audio_service/audio_service.dart' show AudioServiceRepeatMode, AudioServiceShuffleMode;
import 'package:easy_music/player/audio_quality.dart';
import 'package:easy_music/player/lyrics.dart';
import 'package:easy_music/player/playback.dart';
import 'package:easy_music/player/session_store.dart';
import 'package:easy_music/player/track.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  test('LRC 支持偏移、重复时间标签和向前拖动', () {
    final lines = parseLrc('''
[ti:示例]
[00:03.50]第二句
[00:01.2][00:05.025]第一句
[offset:+100]
''');
    expect(lines.map((line) => line.start.inMilliseconds), [1100, 3400, 4925]);
    expect(lines.map((line) => line.text), ['第一句', '第二句', '第一句']);
    expect(activeLyricIndex(lines, const Duration(seconds: 5)), 2);
    expect(activeLyricIndex(lines, const Duration(milliseconds: 1100)), 0);
    expect(activeLyricIndex(lines, const Duration(seconds: 1)), -1);
  });

  test('重新打开数据库时恢复队列、进度和歌词', () {
    final directory = Directory.systemTemp.createTempSync('easy-music-test-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final path = '${directory.path}/player.sqlite3';
    final online = Track.online('online', 'https://example.org/song.mp3');
    final local = Track(
      id: 'local',
      title: '示例',
      source: Uri.parse('content://documents/music'),
      lyrics: '[00:01]示例歌词',
    );

    final store = SessionStore(path);
    store.replaceQueue(SavedSession([online, local], 0, Duration.zero));
    store.savePosition(1, const Duration(seconds: 12));
    store.close();

    final reopened = SessionStore(path);
    addTearDown(reopened.close);
    final saved = reopened.read();
    expect(saved.tracks.map((track) => track.id), ['online', 'local']);
    expect(saved.tracks.last.lyrics, local.lyrics);
    expect(saved.tracks.last.source, local.source);
    expect(saved.index, 1);
    expect(saved.position, const Duration(seconds: 12));
  });

  test('写入失败时保留旧队列和播放位置', () {
    final store = SessionStore(':memory:');
    addTearDown(store.close);
    final track = Track.online('one', 'https://example.org/one.mp3');
    store.replaceQueue(SavedSession([track], 0, const Duration(seconds: 5)));
    expect(
      () => store.replaceQueue(SavedSession([track, track], 1, Duration.zero)),
      throwsException,
    );
    final saved = store.read();
    expect(saved.tracks.single.id, 'one');
    expect(saved.index, 0);
    expect(saved.position, const Duration(seconds: 5));
  });

  test('旧数据库保留模式和倍速，新增音量可保存并恢复', () async {
    final directory = Directory.systemTemp.createTempSync('easy-music-test-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final path = '${directory.path}/player.sqlite3';
    final old = sqlite3.open(path);
    old.execute('''
      CREATE TABLE playback_settings (
        singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
        repeat_mode TEXT NOT NULL,
        speed REAL NOT NULL
      );
      INSERT INTO playback_settings VALUES (1, 'all', 1.25);
    ''');
    old.close();
    final store = SessionStore(path);
    expect(
      store.readSettings(),
      (
        repeatMode: AudioServiceRepeatMode.all,
        speed: 1.25,
        volume: 1.0,
        preferredQuality: AudioQuality.standard,
      ),
    );
    TestWidgetsFlutterBinding.ensureInitialized();
    final player = Playback(store);
    await player.setRepeatMode(AudioServiceRepeatMode.one);
    await player.setSpeed(1.5);
    await player.setVolume(0.35);
    await player.setPreferredQuality(AudioQuality.lossless);
    expect(player.playbackState.value.repeatMode, AudioServiceRepeatMode.one);
    expect(player.playbackState.value.speed, 1.5);
    expect(player.volume, 0.35);
    store.close();

    final reopened = SessionStore(path);
    addTearDown(reopened.close);
    expect(
      reopened.readSettings(),
      (
        repeatMode: AudioServiceRepeatMode.one,
        speed: 1.5,
        volume: 0.35,
        preferredQuality: AudioQuality.lossless,
      ),
    );
  });

  testWidgets('定时暂停可以取消和重新计时', (tester) async {
    final store = SessionStore(':memory:');
    addTearDown(store.close);
    final player = Playback(store);

    player.startSleepTimer(const Duration(seconds: 1));
    await tester.pump(const Duration(milliseconds: 500));
    player.startSleepTimer(const Duration(seconds: 2));
    final replacement = player.sleepDeadline.value;
    await tester.pump(const Duration(seconds: 1));
    expect(player.sleepDeadline.value, replacement);
    await tester.pump(const Duration(seconds: 1));
    expect(player.sleepDeadline.value, isNull);

    player.startSleepTimer(const Duration(seconds: 1));
    player.cancelSleepTimer();
    await tester.pump(const Duration(seconds: 1));
    expect(player.sleepDeadline.value, isNull);
  });

  test('切换音源保持暂停进度，并且拒绝已过期的切换请求', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final store = SessionStore(':memory:');
    addTearDown(store.close);
    final track = Track.online('kg:track', 'https://example.org/old.mp3')
        .copyWith(lyrics: '[00:01]试听');
    const position = Duration(seconds: 12);
    store.replaceQueue(SavedSession([track], 0, position));
    final player = Playback(store);
    await player.restore();

    final source = Uri.parse('https://example.org/new.flac');
    expect(await player.replaceCurrentSource(track, source, AudioQuality.lossless), isTrue);
    expect(player.position, position);
    expect(player.playbackState.value.playing, isFalse);
    expect(player.tracks.value.single.source, source);
    expect(player.tracks.value.single.lyrics, track.lyrics);
    expect(store.read().tracks.single.audioQuality, AudioQuality.lossless);
    expect(store.read().position, position);
    expect(await player.replaceCurrentSource(track, track.source, AudioQuality.standard), isFalse);
  });

  test('拖动队列保持当前选曲和已保存进度', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final store = SessionStore(':memory:');
    addTearDown(store.close);
    final tracks = [
      for (final id in ['a', 'b', 'c'])
        Track.online(id, 'https://example.org/$id.mp3'),
    ];
    const position = Duration(seconds: 12);
    store.replaceQueue(SavedSession(tracks, 1, position));
    final player = Playback(store);
    await player.restore();

    await player.moveTrack('a', 'c');
    expect(player.tracks.value.map((track) => track.id), ['b', 'c', 'a']);
    expect(player.index, 0);
    expect(player.position, position);
    final saved = store.read();
    expect(saved.tracks[saved.index].id, 'b');
    expect(saved.position, position);
  });

  test('随机播放保留选曲，并且可以恢复原顺序', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final store = SessionStore(':memory:');
    addTearDown(store.close);
    final tracks = [
      for (final id in ['a', 'b', 'c', 'd'])
        Track.online(id, 'https://example.org/$id.mp3'),
    ];
    const position = Duration(seconds: 12);
    store.replaceQueue(SavedSession(tracks, 1, position));
    final player = Playback(store);
    await player.restore();
    await player.setShuffleMode(AudioServiceShuffleMode.all);
    expect(player.playbackState.value.shuffleMode, AudioServiceShuffleMode.all);
    expect(player.tracks.value[player.index].id, 'b');
    expect(player.position, position);
    expect(store.readOriginalQueueOrder(), ['a', 'b', 'c', 'd']);
    expect(player.tracks.value.map((track) => track.id).toSet(), {'a', 'b', 'c', 'd'});
    await player.setShuffleMode(AudioServiceShuffleMode.none);
    expect(player.tracks.value.map((track) => track.id), ['a', 'b', 'c', 'd']);
    expect(player.tracks.value[player.index].id, 'b');
    expect(store.readOriginalQueueOrder(), isNull);
  });

  test('最近播放按时间排序，同曲只留一条并保留重播所需数据', () {
    final directory = Directory.systemTemp.createTempSync('easy-music-test-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final path = '${directory.path}/player.sqlite3';
    final online = Track.online('kg:song', 'https://example.org/song.mp3?token=test')
        .copyWith(albumAudioId: 123, albumId: 456);
    final local = Track(id: 'local', title: '示例', source: Uri.file('/music/song.wav'));
    final first = DateTime(2026, 11, 22, 12);
    final second = first.add(const Duration(minutes: 1));
    final latest = first.add(const Duration(minutes: 2));

    final store = SessionStore(path);
    store.recordPlayed(online, first);
    store.recordPlayed(local, second);
    store.recordPlayed(online, latest);
    store.close();

    final reopened = SessionStore(path);
    addTearDown(reopened.close);
    final records = reopened.readHistory();
    expect(records.map((entry) => entry.track.id), ['kg:song', 'local']);
    expect(records.first.playedAt, latest);
    expect(records.first.track.source.toString(), 'kugou:song');
    expect(records.first.track.albumAudioId, 123);
    expect(records.first.track.albumId, 456);
    expect(records.last.track.source, local.source);
    expect(reopened.readListeningStats().plays, 3);
    expect(reopened.readListeningStats().songs, 2);
    expect(reopened.readListeningStats().top.first.count, 2);

    reopened.removeHistory('kg:song');
    expect(reopened.readHistory().single.track.id, 'local');
  });

  test('同一曲目重复加入时仍能保存队列', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final store = SessionStore(':memory:');
    addTearDown(store.close);
    final player = Playback(store);
    final first = Track.online('kg:first', 'https://example.org/first.mp3');
    final second = Track.online('kg:second', 'https://example.org/second.mp3');
    await player.addTracks([first, first]);
    await player.addTracks([first, second]);

    expect(player.tracks.value.map((track) => track.id), [first.id, second.id]);
    expect(store.read().tracks.map((track) => track.id), [first.id, second.id]);
  });

  test('音频地址要求 HTTPS 并保留查询参数', () {
    expect(
      () => Track.online('one', 'http://example.org/a.mp3'),
      throwsFormatException,
    );
    final track = Track.online('two', 'https://example.org/a.mp3?token=123');
    expect(track.title, 'a');
    expect(track.source.query, 'token=123');
  });
}

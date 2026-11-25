import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:easy_music/player/playback.dart';
import 'package:easy_music/player/session_store.dart';
import 'package:easy_music/player/track.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Track track(String id) => Track.online(id, 'https://example.org/$id.mp3');

  test('清空队列同时清掉播放状态和持久化数据，较早的整单请求不会恢复队列', () async {
    final store = SessionStore(':memory:');
    addTearDown(store.close);
    final player = Playback(store);
    await player.addTracks([track('old')]);
    final pending = Completer<List<Track>>();
    const preview = MediaItem(id: 'late', title: '新歌单首曲');
    final replacing = player.replaceTracks(pending.future, preview: preview);
    expect(player.queuePreparation.value?.preview, same(preview));
    await player.clearQueue();
    expect(player.queuePreparation.value, isNull);
    pending.complete([track('late')]);
    expect(await replacing, isFalse);
    expect(player.tracks.value, isEmpty);
    expect(player.queue.value, isEmpty);
    expect(player.mediaItem.value, isNull);
    expect(player.position, Duration.zero);
    expect(player.playbackState.value.playing, isFalse);
    expect(store.read().tracks, isEmpty);
  });

  test('通知栏退出先保存并停止播放，在途的换队列请求不会重新播放', () async {
    final native = _NativePlayer();
    final store = SessionStore(':memory:');
    addTearDown(store.close);
    final player = Playback(store);
    final ready = player.playbackState.firstWhere(
      (state) => state.processingState == AudioProcessingState.ready && state.playing,
    );
    await player.replaceTracks([track('current')]);
    await ready.timeout(const Duration(seconds: 2));
    await native.emit(index: 0, position: const Duration(milliseconds: 500));
    player.startSleepTimer(const Duration(minutes: 1));
    final pending = Completer<List<Track>>();
    final replacing = player.replaceTracks(pending.future);

    var exited = false;
    player.onExit = () async {
      expect(player.playbackState.value.processingState, AudioProcessingState.idle);
      expect(player.playbackState.value.playing, isFalse);
      expect(player.sleepDeadline.value, isNull);
      expect(store.read().position, greaterThanOrEqualTo(const Duration(milliseconds: 500)));
      exited = true;
    };
    await player.customAction('dev.easymusic.easy_music.EXIT');
    expect(exited, isTrue);

    pending.complete([track('late')]);
    expect(await replacing, isFalse);
    expect(store.read().tracks.map((item) => item.id), ['current']);
  });

  test('播放全部清除旧队列的随机模式，按列表顺序开始并保存', () async {
    _NativePlayer();
    final store = SessionStore(':memory:');
    addTearDown(store.close);
    final player = Playback(store);
    await player.addTracks([track('old')]);
    await player.setShuffleMode(AudioServiceShuffleMode.all);
    expect(player.playbackState.value.shuffleMode, AudioServiceShuffleMode.all);

    final ids = ['c', 'a', 'd', 'b'];
    final ready = player.playbackState.firstWhere(
      (state) => state.processingState == AudioProcessingState.ready,
    );
    expect(await player.replaceTracks(ids.map(track).toList()), isTrue);
    await ready.timeout(const Duration(seconds: 2));

    expect(player.tracks.value.map((item) => item.id), ids);
    expect(player.queue.value.map((item) => item.id), ids);
    expect(player.index, 0);
    expect(player.playbackState.value.shuffleMode, AudioServiceShuffleMode.none);
    expect(store.read().tracks.map((item) => item.id), ids);
    expect(store.readOriginalQueueOrder(), isNull);
    await player.clearQueue();
  });

  test('重复点播会更新已有酷狗歌曲的专辑曲目编号', () async {
    _NativePlayer();
    final store = SessionStore(':memory:');
    addTearDown(store.close);
    final player = Playback(store);
    final old = track('kg:abc').copyWith(albumAudioId: 17);
    await player.addTracks([old]);

    await player.playTracks([old.copyWith(albumAudioId: 42)]);

    expect(player.tracks.value.single.albumAudioId, 42);
    expect(store.read().tracks.single.albumAudioId, 42);
    await player.clearQueue();
  });

  test('点播新歌后插到当前曲目下一位，已有歌曲沿用原位置', () async {
    _NativePlayer();
    final store = SessionStore(':memory:');
    addTearDown(store.close);
    final player = Playback(store);
    addTearDown(player.clearQueue);
    await player.addTracks(['a', 'b', 'c', 'd'].map(track).toList());
    await player.skipToQueueItem(1);

    await player.playTracks([track('new')]);

    final order = ['a', 'b', 'new', 'c', 'd'];
    expect(player.queue.value.map((item) => item.id), order);
    expect(player.mediaItem.value?.id, 'new');
    expect(store.read().tracks.map((item) => item.id), order);
    expect(store.read().index, 2);
    await player.skipToNext();
    expect(player.mediaItem.value?.id, 'c');
    await player.playTracks([track('a')]);
    expect(player.mediaItem.value?.id, 'a');
    expect(player.queue.value.map((item) => item.id), order);
  });

  test('随机播放时点播新歌，关闭随机后仍排在当时的曲目后面', () async {
    _NativePlayer();
    final store = SessionStore(':memory:');
    addTearDown(store.close);
    final player = Playback(store);
    addTearDown(player.clearQueue);
    await player.addTracks(['a', 'b', 'c'].map(track).toList());
    await player.skipToQueueItem(1);
    await player.setShuffleMode(AudioServiceShuffleMode.all);
    final order = player.queue.value.map((item) => item.id).toList()..insert(1, 'new');

    await player.playTracks([track('new')]);

    expect(player.queue.value.map((item) => item.id), order);
    expect(player.mediaItem.value?.id, 'new');
    await player.setShuffleMode(AudioServiceShuffleMode.none);
    expect(player.queue.value.map((item) => item.id), ['a', 'b', 'new', 'c']);
    expect(player.mediaItem.value?.id, 'new');
  });

  test('FM 播完前一批后接上下一首，清空后丢弃在途推荐', () async {
    final native = _NativePlayer();
    final store = SessionStore(':memory:');
    addTearDown(store.close);
    final player = Playback(store);
    final requested = Completer<void>();
    final requestedAgain = Completer<void>();
    final firstBatch = Completer<List<Track>>();
    final secondBatch = Completer<List<Track>>();
    var requests = 0;

    await player.addTracks([track('old')]);
    await player.setRepeatMode(AudioServiceRepeatMode.all);
    expect(
      await player.replaceTracks(
        [track('fm1')],
        loadMore: () {
          if (requests++ == 0) {
            requested.complete();
            return firstBatch.future;
          }
          requestedAgain.complete();
          return secondBatch.future;
        },
      ),
      isTrue,
    );
    await requested.future.timeout(const Duration(seconds: 2));
    expect(player.tracks.value.map((item) => item.id), ['fm1']);
    expect(player.playbackState.value.repeatMode, AudioServiceRepeatMode.none);
    expect(store.readSettings().repeatMode, AudioServiceRepeatMode.all);

    final completed = player.playbackState.firstWhere(
      (state) => state.processingState == AudioProcessingState.completed,
    );
    await native.emit(index: 0, completed: true);
    await completed.timeout(const Duration(seconds: 2));
    firstBatch.complete([track('fm2')]);
    await requestedAgain.future.timeout(const Duration(seconds: 2));
    expect(player.tracks.value.map((item) => item.id), ['fm1', 'fm2']);
    expect(player.index, 1);
    expect(player.playbackState.value.playing, isTrue);

    await player.clearQueue();
    secondBatch.complete([track('fm3')]);
    await Future<void>.delayed(Duration.zero);
    expect(player.tracks.value, isEmpty);
    expect(player.playbackState.value.repeatMode, AudioServiceRepeatMode.all);
    expect(requests, 2);
  });

  test('播放从零淡入，暂停淡出后恢复设定音量', () async {
    final native = _NativePlayer();
    final store = SessionStore(':memory:');
    addTearDown(store.close);
    final player = Playback(store);
    await player.setVolume(0.6);
    await player.setFadeMilliseconds(100);
    final levels = <double>[];
    final subscription = player.volumeStream.listen(levels.add);
    addTearDown(subscription.cancel);

    final fadeIn = native.volumes.stream.firstWhere((level) => level == 0.6);
    await player.replaceTracks([track('fade')]);
    await fadeIn.timeout(const Duration(seconds: 2));
    expect(native.volumeWrites.first, 0);
    expect(native.volumeWrites, contains(inExclusiveRange(0, 0.6)));
    final afterStart = native.volumeWrites.length;
    await player.pause();
    final pauseVolumes = native.volumeWrites.skip(afterStart).toList();
    expect(pauseVolumes.first, inExclusiveRange(0, 0.6));
    expect(pauseVolumes, contains(0));
    expect(pauseVolumes.last, 0.6);
    expect(levels, everyElement(0.6));
    expect(store.readSettings().volume, 0.6);
    expect(player.playbackState.value.playing, isFalse);
    await player.clearQueue();
  });
}

/// 发送原生播放器的就绪和结束事件，测试实际的续播和队列逻辑。
class _NativePlayer {
  _NativePlayer() {
    _messenger.setMockMethodCallHandler(_main, (call) async {
      if (call.method == 'init') {
        _id = (call.arguments as Map)['id'] as String;
        final methods = MethodChannel('${_main.name}.$_id');
        final events = MethodChannel('$_eventPrefix.$_id');
        final data = MethodChannel('com.ryanheise.just_audio.data.$_id');
        _messenger.setMockMethodCallHandler(events, (_) async => null);
        _messenger.setMockMethodCallHandler(data, (_) async => null);
        _messenger.setMockMethodCallHandler(methods, (call) async {
          if (call.method == 'setVolume') {
            final level = (call.arguments as Map)['volume'] as double;
            volumeWrites.add(level);
            volumes.add(level);
          }
          if (call.method == 'load') {
            await emit(
              index: (call.arguments as Map)['initialIndex'] as int? ?? 0,
            );
            return {'duration': 1000000};
          }
          if (call.method == 'seek') {
            await emit(index: (call.arguments as Map)['index'] as int? ?? 0);
          }
          return <String, Object>{};
        });
        return null;
      }
      return <String, Object>{};
    });
    addTearDown(() => _messenger.setMockMethodCallHandler(_main, null));
    addTearDown(volumes.close);
  }

  static const _main = MethodChannel('com.ryanheise.just_audio.methods');
  static const _eventPrefix = 'com.ryanheise.just_audio.events';
  final volumes = StreamController<double>.broadcast();
  final volumeWrites = <double>[];
  final _messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late String _id;

  Future<void> emit({
    required int index,
    bool completed = false,
    Duration position = Duration.zero,
  }) async {
    await _messenger.handlePlatformMessage(
      '$_eventPrefix.$_id',
      const StandardMethodCodec().encodeSuccessEnvelope({
        'processingState': completed ? 4 : 3,
        'currentIndex': index,
        'updateTime': DateTime.now().millisecondsSinceEpoch,
        'updatePosition': completed ? 1000000 : position.inMicroseconds,
        'bufferedPosition': 1000000,
        'duration': 1000000,
      }),
      null,
    );
  }
}

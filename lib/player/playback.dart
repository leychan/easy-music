import 'dart:async';
import 'dart:io' show Platform;

import 'package:android_file_picker/android_file_picker.dart' show FilePickerAndroid;
import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:just_audio/just_audio.dart' as audio;
import 'package:synchronized/synchronized.dart';

import 'audio_cache.dart';
import 'audio_quality.dart';
import 'session_store.dart';
import 'stem_mixer.dart';
import 'track.dart';

enum SleepAction { pause, exit }

typedef TrackPlayback = ({String? trackId, bool playing});

class QueuePreparation {
  const QueuePreparation(this.preview);

  final MediaItem? preview;
}

/// 界面与系统媒体控制共用这个队列和播放器。
class Playback extends BaseAudioHandler {
  Playback(this._store, {this.audioCache}) {
    // playerEvent 同时包含播放状态与引擎的进度、曲目变更。
    _player.playerEventStream.listen((_) => _publish());
    _player.errorStream.listen(_reportPlayerError);
    if (Platform.isAndroid) {
      _player.positionStream.listen((value) {
        if (_mixPlayback == null && !_updatingQueue) _androidPositions.add(value);
      });
    }
  }

  final SessionStore _store;
  final AudioCache? audioCache;
  final _player = audio.AudioPlayer();
  final _commands = Lock();
  final _androidPositions = StreamController<Duration>.broadcast();
  late final _showStemMixButton = ValueNotifier(
    _store.readPreference(_stemButtonPreference) == 'true',
  );
  late final _experimentalKaraoke = ValueNotifier(
    _store.readPreference(_karaokePreference) == 'true',
  );
  late final StemMixer? stemMixer = Platform.isAndroid
      ? StemMixer(
          onPlayback: _onStemPlayback, onError: _onStemError,
          allowKaraoke: () => experimentalKaraoke.value,
        )
      : null;
  final tracks = ValueNotifier<List<Track>>(const []);
  final history = ValueNotifier<List<PlayedTrack>>(const []);
  final preferredQuality = ValueNotifier(AudioQuality.standard);
  final sleepDeadline = ValueNotifier<DateTime?>(null);
  final fadeMilliseconds = ValueNotifier(0);
  final _queuePreparation = ValueNotifier<QueuePreparation?>(null);
  Future<void> Function()? onExit;
  bool Function(Track)? isNotificationFavorite;
  Future<void> Function(Track)? onToggleNotificationFavorite;
  final message = ValueNotifier<String?>(null);

  static const _stemButtonPreference = 'show_stem_mix_button';
  static const _karaokePreference = 'experimental_karaoke';
  static const _toggleFavoriteAction = 'dev.easymusic.easy_music.TOGGLE_FAVORITE';
  static const _previousAction = 'dev.easymusic.easy_music.PREVIOUS';
  static const _exitAction = 'dev.easymusic.easy_music.EXIT';
  MediaItem? _publishedItem;
  bool _updatingQueue = false;
  bool _queueDirty = false;
  int _selectedIndex = 0;
  Duration _savedPosition = Duration.zero;
  String? _lastPlayedId;
  Timer? _sleepTimer;
  SleepAction _sleepAction = SleepAction.pause;
  List<String>? _originalQueueOrder;
  _QueueContinuation? _continuation;
  AudioServiceRepeatMode _preferredRepeatMode = AudioServiceRepeatMode.none;
  int _queueReplacement = 0;
  double _volume = 1;
  int _fadeGeneration = 0;
  int? _pendingFadeIn;
  int _stemSelection = 0;
  (String, Uri)? _lastSource;
  int? _endingStemId;

  /// 等待新队列时给界面展示「全部播放」的首曲，实际播放状态由媒体会话报告。
  ValueListenable<QueuePreparation?> get queuePreparation => _queuePreparation;

  int get _originalIndex => _player.processingState == audio.ProcessingState.idle
      ? _selectedIndex
      : _player.currentIndex ?? _selectedIndex;
  int get index {
    final mixedId = stemMixer?.trackId;
    if (mixedId != null) {
      final slot = tracks.value.indexWhere((track) => track.id == mixedId);
      if (slot >= 0) return slot;
    }
    return _originalIndex;
  }

  Duration get _originalPosition => _player.processingState == audio.ProcessingState.idle
      ? _savedPosition
      : _player.position;
  StemPlayback? get _mixPlayback => stemMixer?.playback;
  audio.ProcessingState get _processingState => _mixPlayback?.state ?? _player.processingState;
  bool get _playing => _mixPlayback?.playing ?? _player.playing;
  double get _engineVolume => stemMixer?.active == true ? stemMixer!.masterVolume : _player.volume;
  Duration? get _duration => _mixPlayback?.duration ?? _player.duration;
  Duration get position => _mixPlayback?.position ?? _originalPosition;
  Stream<Duration> get positionStream => Platform.isAndroid ? _androidPositions.stream : _player.positionStream;
  double get volume => _volume;
  Stream<double> get volumeStream => _player.volumeStream.map((_) => volume).distinct();
  ({int plays, int songs, List<ListeningCount> top}) get listeningStats =>
      _store.readListeningStats();
  bool get hasNext => _neighborIndex(1) != null || _continuation?.exhausted == false;
  bool get hasPrevious => _neighborIndex(-1) != null;

  TrackPlayback get trackPlayback => _trackPlayback(playbackState.value);

  // 歌曲列表只关心当前曲目和播放状态，进度更新无需重绘列表。
  late final Stream<TrackPlayback> trackPlaybackStream = playbackState.map(_trackPlayback).distinct();

  TrackPlayback _trackPlayback(PlaybackState state) {
    final slot = state.queueIndex;
    return (trackId: slot == null ? null : tracks.value.elementAtOrNull(slot)?.id, playing: state.playing);
  }

  bool canResumeTrack(String trackId) {
    final state = playbackState.value;
    return _trackPlayback(state).trackId == trackId && switch (state.processingState) {
      AudioProcessingState.idle || AudioProcessingState.completed || AudioProcessingState.error => false,
      _ => true,
    };
  }

  AudioServiceRepeatMode get _repeatMode => switch (_player.loopMode) {
    audio.LoopMode.off => AudioServiceRepeatMode.none,
    audio.LoopMode.one => AudioServiceRepeatMode.one,
    audio.LoopMode.all => AudioServiceRepeatMode.all,
  };

  Future<void> restore() async {
    final saved = _store.read();
    _originalQueueOrder = _store.readOriginalQueueOrder();
    final fade = int.tryParse(_store.readPreference('manual_fade_ms') ?? '');
    if (fade != null) fadeMilliseconds.value = fade.clamp(0, 1000);
    final settings = _store.readSettings();
    _preferredRepeatMode = settings.repeatMode;
    preferredQuality.value = settings.preferredQuality;
    history.value = List.unmodifiable(_store.readHistory());
    await _player.setLoopMode(_loopMode(settings.repeatMode));
    await _player.setSpeed(settings.speed);
    _volume = settings.volume;
    await _player.setVolume(volume);
    if (saved.tracks.isNotEmpty) {
      _selectedIndex = saved.index.clamp(0, saved.tracks.length - 1);
      _savedPosition = saved.position.isNegative
          ? Duration.zero
          : saved.position;
      await _setSources(saved.tracks, _selectedIndex, _savedPosition);
      _publishQueue(saved.tracks);
    }
    _publish(offerResume: true);
    Timer.periodic(const Duration(seconds: 5), (_) {
      if (_playing || _queueDirty) saveProgress();
    });
  }

  Future<void> _setSources(
    List<Track> tracks,
    int index,
    Duration position, {
    bool preload = false,
  }) =>
      _player.setAudioSources(
        tracks.map(_audioSource).toList(),
        preload: preload,
        initialIndex: index,
        initialPosition: position,
      );

  bool canMixStems(Track track) => stemMixer != null && _stemSourceAvailable(track);

  ValueListenable<bool> get showStemMixButton => _showStemMixButton;

  void setShowStemMixButton(bool show) {
    _store.savePreference(_stemButtonPreference, '$show');
    _showStemMixButton.value = show;
  }

  ValueListenable<bool> get experimentalKaraoke => _experimentalKaraoke;

  Future<void> setExperimentalKaraoke(bool enabled) async {
    _store.savePreference(_karaokePreference, '$enabled');
    _experimentalKaraoke.value = enabled;
    if (!enabled) await stemMixer?.setKaraoke(false);
  }

  Future<bool> hasStemMixResources(Track track) async {
    final mixer = stemMixer;
    if (mixer == null || !canMixStems(track)) return false;
    if (mixer.trackId == track.id) return true;
    final onlineCache = track.isLocal ? null : audioCache;
    try {
      return await mixer.hasResources(
        onlineCache?.cachedPlaybackUri(track) ?? track.source,
        cacheKey: onlineCache?.stemCacheKey(track),
      );
    } on Exception {
      return false;
    }
  }

  bool _stemSourceAvailable(Track track) => switch (track.source.scheme) {
    'file' || 'content' => track.isLocal,
    'http' || 'https' => audioCache?.canProxyTrack(track) ?? false,
    _ => false,
  };

  Future<void> enableStemMix(Track track) async {
    final mixer = stemMixer;
    if (mixer == null || !canMixStems(track) || !_isOriginalTrack(track)) return;
    if (mixer.active) return;
    final selection = _stemSelection;
    final request = mixer.begin();
    if (request == null) return;
    message.value = null;
    try {
      // 在线音源和原播放器共用回环缓存，原始地址只由缓存代理处理。
      final source = audioCache?.playbackUri(track) ?? track.source;
      final path = await mixer.prepare(
        request, source,
        cacheKey: track.isLocal ? null : audioCache?.stemCacheKey(track),
      );
      await _commands.synchronized(() async {
        if (request.cancelled || selection != _stemSelection || !_isOriginalTrack(track)) return;
        await _activateStemMix(mixer, request, track, path);
      });
    } on PlatformException catch (error) {
      if (!request.cancelled && selection == _stemSelection) {
        message.value = error.message ?? '无法启用人声 / 伴奏，请重试。';
      }
    } on Exception {
      if (!request.cancelled && selection == _stemSelection) {
        message.value = '无法启用人声 / 伴奏，请重试。';
      }
    } finally {
      mixer.finish(request);
    }
  }

  bool _isOriginalTrack(Track track) {
    final current = tracks.value.elementAtOrNull(_originalIndex);
    return current?.id == track.id && current?.source == track.source;
  }

  Future<void> _activateStemMix(
    StemMixer mixer,
    StemPreparation request,
    Track track,
    String path,
  ) async {
    final previous = _updatingQueue;
    _updatingQueue = true;
    var pausedOriginal = false;
    var wasPlaying = false;
    try {
      await mixer.load(
        request: request, sourceTrackId: track.id, path: path, position: Duration.zero,
        volume: volume, speed: _player.speed, repeatOne: _player.loopMode == audio.LoopMode.one,
      );
      // 准备双轨时原播放器可能已自然播到下一首。
      if (request.cancelled || !_isOriginalTrack(track)) {
        await mixer.close();
        return;
      }
      _cancelFade();
      final completed = _player.processingState == audio.ProcessingState.completed;
      wasPlaying = _player.playing && !completed;
      final initialPosition = _originalPosition;
      await _player.pause();
      pausedOriginal = true;
      if (!completed) {
        final currentPosition = _player.processingState == audio.ProcessingState.idle
            ? initialPosition : _originalPosition;
        await mixer.seek(currentPosition);
      }
      await _restoreVolume();
      if (wasPlaying) await mixer.play();
    } catch (_) {
      await mixer.close();
      await _restoreVolume();
      if (pausedOriginal && wasPlaying) await _start();
      rethrow;
    } finally {
      _updatingQueue = previous;
      _onStemPlayback(false);
    }
  }

  Future<void> disableStemMix() => _commands.synchronized(_resumeOriginalFromMix);

  Future<void> _resumeOriginalFromMix() async {
    final mixer = stemMixer;
    if (mixer == null || !mixer.active) return;
    final slot = index;
    final wasPlaying = playbackState.value.playing;
    final previous = _updatingQueue;
    _updatingQueue = true;
    try {
      _cancelFade();
      final mixed = (await mixer.close())!;
      _selectedIndex = slot;
      _savedPosition = mixed.position;
      if (_player.processingState == audio.ProcessingState.idle) {
        await _setSources(tracks.value, slot, mixed.position);
      } else {
        final originalDuration = _player.duration;
        await _player.seek(originalDuration != null && mixed.position > originalDuration
            ? originalDuration : mixed.position, index: slot);
      }
      await _restoreVolume();
      if (wasPlaying) await _start();
    } finally {
      _updatingQueue = previous;
      _onStemPlayback(false);
      saveProgress();
    }
  }

  Future<void> _closeMix() async {
    final mixer = stemMixer;
    if (mixer == null || !mixer.active) return;
    _cancelFade();
    await mixer.close();
  }

  void _onStemPlayback(bool positionOnly) {
    if (_updatingQueue) return;
    _androidPositions.add(position);
    if (positionOnly) return;
    _publish();
    final mixer = stemMixer;
    final id = mixer?.playbackId;
    // 双轨引擎只装载当前歌曲，播完后把队列的后续播放交还现有播放器。
    if (id == null || id == _endingStemId ||
        mixer!.playback?.state != audio.ProcessingState.completed || !_playing) {
      return;
    }
    _endingStemId = id;
    unawaited(_commands.synchronized(() async {
      try {
        if (mixer.playbackId != id || !_playing ||
            _processingState != audio.ProcessingState.completed) {
          return;
        }
        final next = _neighborIndex(1);
        if (next != null) await _selectAndPlay(next);
      } on Exception {
        message.value = '无法播放下一首，请重试。';
      } finally {
        if (_endingStemId == id) _endingStemId = null;
      }
    }));
  }

  void _onStemError(int id) => unawaited(_commands.synchronized(() async {
    if (stemMixer?.playbackId != id) return;
    try {
      await _resumeOriginalFromMix();
      message.value = '分轨播放中断，已切回原声。';
    } on Exception {
      message.value = '分轨播放中断，无法恢复原声。';
    }
  }));

  void startSleepTimer(Duration duration, {SleepAction action = SleepAction.pause}) {
    if (duration <= Duration.zero) return;
    _sleepTimer?.cancel();
    final deadline = DateTime.now().add(duration);
    _sleepAction = action;
    sleepDeadline.value = deadline;
    _sleepTimer = Timer(duration, () => unawaited(_pauseForSleepTimer(deadline)));
  }

  void cancelSleepTimer() {
    _sleepTimer?.cancel();
    _sleepTimer = null;
    sleepDeadline.value = null;
  }

  /// 回到前台时也检查截止时间，覆盖系统暂缓执行后台计时器的情况。
  void checkSleepTimer() {
    final deadline = sleepDeadline.value;
    if (deadline != null && !DateTime.now().isBefore(deadline)) {
      unawaited(_pauseForSleepTimer(deadline));
    }
  }

  Future<void> _pauseForSleepTimer(DateTime deadline) =>
      _commands.synchronized(() async {
        if (sleepDeadline.value != deadline) return;
        final action = _sleepAction;
        cancelSleepTimer();
        try {
          final exit = onExit;
          if (action == SleepAction.exit && exit != null) {
            await _stopAndExit(exit);
          } else {
            await _pauseAndSave();
          }
        } on Exception {
          message.value = '定时操作失败，请重试。';
        }
      });

  /// 队列里可能有拿不到地址的占位条目（`kugou.invalid`），把它们包装成
  /// 必然失败的音频源，只影响那一首，不会让整个队列建立不起来。
  audio.AudioSource _audioSource(Track track) => audio.AudioSource.uri(
    audioCache?.playbackUri(track) ?? track.source,
    tag: track.artist.isEmpty ? null : MediaItem(
      id: track.id,
      title: track.title,
      artist: track.artist,
    ),
  );

  /// 追加到队尾，至少加入一首新歌时返回 true。
  Future<bool> addTracks(List<Track> added) =>
      _commands.synchronized(() => _addTracks(added));

  Future<void> playTracks(List<Track> items, {bool resumeCurrent = false}) => _commands.synchronized(() async {
    if (items.isEmpty) return;
    await _addTracks(items, after: tracks.value.elementAtOrNull(index));
    // 重复点播直接定位已有条目，队列和数据库共用同一个唯一 ID。
    final incoming = items.first;
    final slot = tracks.value.indexWhere((track) => track.id == incoming.id);
    final existing = tracks.value[slot];
    // 曲库完成本次取址后才进入这里，并在命令锁内确认当前歌曲仍可续播。
    final resume = resumeCurrent && canResumeTrack(incoming.id);
    if ((incoming.kugouHash != null || incoming.isCloud) &&
        (existing.source != incoming.source || existing.albumAudioId != incoming.albumAudioId)) {
      // 更新播放地址或专辑曲目编号时，保留已补齐的封面和歌词。
      final updated = [...tracks.value];
      updated[slot] = incoming.copyWith(
        artUri: incoming.artUri ?? existing.artUri,
        lyrics: existing.lyrics,
      );
      final startPosition = resume ? position : Duration.zero;
      await _changeQueue(updated, () async {
        await _fadeOut();
        await _closeMix();
        await _player.stop();
        _selectedIndex = slot;
        _savedPosition = startPosition;
        await _setSources(updated, slot, startPosition);
      });
      await _start();
    } else {
      if (existing.artUri == null && incoming.artUri != null) {
        _updateTrackDetails(existing.id, (item) => item.copyWith(artUri: incoming.artUri));
      }
      if (resume) {
        if (!_playing) await _start();
      } else {
        await _playAt(slot);
      }
    }
  });

  /// 用一份新列表替换整个队列，避免旧歌曲排在新列表中间。
  Future<bool> replaceTracks(
    FutureOr<List<Track>> items, {
    MediaItem? preview,
    Future<List<Track>> Function()? loadMore,
  }) async {
    final request = ++_queueReplacement;
    _queuePreparation.value = QueuePreparation(preview);
    try {
      final ready = await items;
      return await _commands.synchronized(() async {
        // 取地址期间如果点了清空或另一份列表，丢弃这次较早的请求。
        if (request != _queueReplacement || ready.isEmpty) return false;
        if (preview != null) _queuePreparation.value = QueuePreparation(_mediaItem(ready.first));
        await _replaceQueue(ready, loadMore: loadMore);
        return true;
      });
    } finally {
      // 较早的请求结束时，较新的请求可能还在取地址。
      if (request == _queueReplacement) _queuePreparation.value = null;
    }
  }

  Future<void> clearQueue() {
    _queueReplacement++;
    _queuePreparation.value = null;
    return _commands.synchronized(() => _replaceQueue(const []));
  }

  Future<void> _replaceQueue(
    List<Track> items, {
    Future<List<Track>> Function()? loadMore,
  }) async {
    final previous = tracks.value;
    final ids = <String>{};
    final updated = items.where((track) => ids.add(track.id)).toList();
    final previousLoop = _player.loopMode;
    await _changeQueue(updated, () async {
      try {
        if (updated.isEmpty) {
          _cancelFade();
        } else {
          await _fadeOut();
        }
        _stemSelection++;
        await _closeMix();
        await _player.stop();
        await _restoreVolume();
        _selectedIndex = 0;
        _savedPosition = Duration.zero;
        await _setSources(updated, 0, Duration.zero);
        // FM 从顺序播放开始，给下一批推荐留出接续机会。
        await _player.setLoopMode(loadMore == null ? _loopMode(_preferredRepeatMode) : audio.LoopMode.off);
      } catch (_) {
        if (_player.loopMode != previousLoop) await _player.setLoopMode(previousLoop);
        rethrow;
      }
      _continuation = loadMore == null ? null : _QueueContinuation(loadMore);
      // 播放全部时按新列表的顺序开始，随机模式属于之前的队列。
      if (updated.isNotEmpty) _originalQueueOrder = null;
      message.value = null;
    });
    if (updated.isNotEmpty) await _start();
    if (!_queueDirty) {
      for (final source in previous.map((track) => track.source).toSet()) {
        await _releaseUnusedFile(source);
      }
    }
  }

  Future<bool> _addTracks(List<Track> items, {Track? after}) async {
    final old = tracks.value;
    final ids = old.map((track) => track.id).toSet();
    final added = items.where((track) => ids.add(track.id)).toList();
    if (added.isEmpty) return false;
    // 只有本次点播的第一首是新歌时，才将它排到当前曲目后面。
    final anchor = added.first.id == items.first.id ? after : null;
    final slot = anchor == null ? old.length : old.indexOf(anchor) + 1;
    final previousOrder = _originalQueueOrder;
    if (previousOrder != null) {
      final restoredOrder = [...previousOrder, ...added.map((track) => track.id)];
      final anchorSlot = anchor == null ? -1 : previousOrder.indexOf(anchor.id);
      if (anchorSlot >= 0) {
        restoredOrder.insert(anchorSlot + 1, restoredOrder.removeAt(previousOrder.length));
      }
      _originalQueueOrder = restoredOrder;
      final rest = added.sublist(1)..shuffle();
      added.replaceRange(1, added.length, rest);
    }
    final updated = [...old, ...added];
    if (slot < old.length) updated.insert(slot, updated.removeAt(old.length));
    try {
      await _changeQueue(updated, () async {
        if (old.isEmpty) {
          await _setSources(added, 0, Duration.zero);
        } else {
          // Linux 后端直接插入可能移动到越界索引，逐首追加后再移动点播曲目。
          for (final track in added) {
            await _player.addAudioSource(_audioSource(track));
          }
          if (slot < old.length) await _player.moveAudioSource(old.length, slot);
        }
      });
    } catch (_) {
      _originalQueueOrder = previousOrder;
      rethrow;
    }
    return true;
  }

  Future<bool> remove(Track track) => _commands.synchronized(() async {
    final old = tracks.value;
    final slot = old.indexWhere((item) => item.id == track.id);
    if (slot == -1) return false;
    final remaining = [...old]..removeAt(slot);
    if (remaining.isEmpty) {
      await _replaceQueue(remaining);
      return !_queueDirty;
    }
    final removingMix = old[slot].id == stemMixer?.trackId;
    final resumeAfterRemove = removingMix && playbackState.value.playing;
    await _changeQueue(remaining, () async {
      if (removingMix) await _closeMix();
      if (_player.processingState == audio.ProcessingState.idle) {
        final current = index;
        _selectedIndex = (slot < current ? current - 1 : current).clamp(
          0,
          remaining.length - 1,
        );
        if (slot == current) _savedPosition = Duration.zero;
        await _setSources(remaining, _selectedIndex, _savedPosition);
      } else {
        await _player.removeAudioSourceAt(slot);
      }
    });
    if (resumeAfterRemove) await _start();
    final saved = !_queueDirty;
    if (saved) await _releaseUnusedFile(old[slot].source);
    return saved;
  });

  /// 按曲目 ID 计算当前位置，拖动时即使队列又增删过也能定位原曲目。
  Future<void> moveTrack(String id, String destinationId) =>
      _commands.synchronized(() async {
        final old = tracks.value;
        final from = old.indexWhere((track) => track.id == id);
        final to = old.indexWhere((track) => track.id == destinationId);
        if (from < 0 || to < 0 || from == to) return;
        final updated = [...old];
        final moved = updated.removeAt(from);
        updated.insert(to, moved);
        // newIndex 是移动后的索引。当前歌曲还在，就跟着它保留选择和进度。
        final selectedId = old.elementAtOrNull(index)?.id;
        final selectedIndex = updated.indexWhere((track) => track.id == selectedId);
        final beforeMove = position;
        await _changeQueue(updated, () async {
          _selectedIndex = selectedIndex < 0 ? 0 : selectedIndex;
          if (_player.processingState == audio.ProcessingState.idle) {
            await _setSources(updated, _selectedIndex, _savedPosition);
          } else {
            await _player.moveAudioSource(from, to);
            // Linux 会先报告更新后的列表，再报告当前索引。等索引同步后再发布，
            // 避免瞬间把旧索引对应的另一首歌记入历史。
            if (_player.currentIndex != _selectedIndex) {
              await _player.currentIndexStream
                  .where((index) => index == _selectedIndex)
                  .timeout(const Duration(seconds: 2))
                  .first;
            }
          }
        }, minimumPosition: beforeMove);
      });

  Future<void> setLyrics(Track track, String lyrics, {bool onlyIfMissing = false}) =>
      _commands.synchronized(() async {
        _updateTrackDetails(track.id, (item) {
          // 自动下载可能比用户选择的版本更晚返回，保留已经写入的歌词。
          if (onlyIfMissing && item.lyrics?.trim().isNotEmpty == true) return item;
          return item.copyWith(lyrics: lyrics);
        });
      });

  Future<void> setArtwork(Track track, Uri cover) => _commands.synchronized(() async {
    _updateTrackDetails(track.id, (item) =>
      item.artUri == null ? item.copyWith(artUri: cover) : item,
    );
  });

  /// 元数据回填只更新队列和历史，无需重建音源或打断正在播放的歌曲。
  void _updateTrackDetails(String id, Track Function(Track) update) {
    final slot = tracks.value.indexWhere((item) => item.id == id);
    if (slot < 0) return;
    final updated = [...tracks.value];
    final track = update(updated[slot]);
    if (identical(track, updated[slot])) return;
    updated[slot] = track;
    _publishQueue(updated);
    _queueDirty = true;
    saveProgress();
    if (history.value.any((entry) => entry.track.id == id)) {
      try {
        _store.updateHistoryDetails(track);
        history.value = List.unmodifiable(_store.readHistory());
      } on Exception catch (error) {
        debugPrint('Cannot update playback history details: ${error.runtimeType}');
      }
    }
  }

  Future<void> _changeQueue(
    List<Track> updated,
    Future<void> Function() updatePlayer, {
    Duration? minimumPosition,
  }) async {
    final previous = SavedSession(tracks.value, index, position);
    final wasPlaying = playbackState.value.playing;
    _updatingQueue = true;
    try {
      await updatePlayer();
    } catch (_) {
      // 播放库可能先改变内存中的队列，再报告原生更新失败。
      await _closeMix();
      await _player.stop();
      _selectedIndex = previous.index;
      _savedPosition = previous.position;
      await _setSources(previous.tracks, previous.index, previous.position);
      audioCache?.retainTracks(previous.tracks);
      if (wasPlaying) await _start();
      rethrow;
    } finally {
      _updatingQueue = false;
    }
    _publishQueue(updated);
    _queueDirty = true;
    saveProgress(minimumPosition: minimumPosition);
  }

  void _publishQueue(List<Track> updated) {
    audioCache?.retainTracks(updated);
    if (_originalQueueOrder case final order?) {
      final ids = updated.map((track) => track.id).toSet();
      _originalQueueOrder = order.where(ids.contains).toList();
    }
    tracks.value = List.unmodifiable(updated);
    queue.add(updated.map(_mediaItem).toList());
    _publish();
  }

  MediaItem _mediaItem(Track track, [Duration? duration]) => MediaItem(
    id: track.id,
    title: track.title,
    artist: track.artist.isEmpty ? null : track.artist,
    duration: duration,
    artUri: track.artUri,
  );

  /// 权限开启后重送当前歌曲，促使系统重新发布原本被拦截的通知。
  void refreshMediaNotification() {
    final item = mediaItem.value;
    if (item != null && playbackState.value.processingState != AudioProcessingState.idle) {
      mediaItem.add(item);
    }
  }

  /// 只更新按钮，让收藏变化保留原来的媒体进度和播放状态。
  void refreshNotificationFavorite() {
    final state = playbackState.value;
    if (state.queueIndex == null) return;
    final current = tracks.value.elementAtOrNull(index);
    if (current?.id != mediaItem.value?.id) return;
    final controls = _mediaControls(state.playing, current);
    if (!listEquals(state.controls, controls)) {
      playbackState.add(state.copyWith(controls: controls));
    }
  }

  List<MediaControl> _mediaControls(bool playing, Track? current) {
    final favorite = isNotificationFavorite;
    final liked = current == null ? false : favorite?.call(current) ?? false;
    return [
      MediaControl.skipToPrevious,
      playing ? MediaControl.pause : MediaControl.play,
      MediaControl.skipToNext,
      if (Platform.isAndroid && current != null && current.kugouHash != null && favorite != null)
        MediaControl.custom(
          androidIcon: liked ? 'drawable/ic_notification_liked' : 'drawable/ic_notification_like',
          label: liked ? '取消喜欢' : '喜欢',
          name: _toggleFavoriteAction,
          extras: {'trackId': current.id},
        ),
      if (Platform.isAndroid && current != null)
        MediaControl.custom(
          androidIcon: 'drawable/ic_notification_close',
          label: '退出应用',
          name: _exitAction,
        ),
    ];
  }

  @override
  Future<dynamic> customAction(String name, [Map<String, dynamic>? extras]) async {
    if (name == _previousAction) {
      await skipToPrevious();
      return null;
    }
    if (name == _exitAction) {
      final exit = onExit;
      if (exit != null) {
        await _commands.synchronized(() async {
          cancelSleepTimer();
          await _stopAndExit(exit);
        });
      }
      return null;
    }
    if (name != _toggleFavoriteAction) return super.customAction(name, extras);
    final current = tracks.value.elementAtOrNull(index);
    // 通知点击和切歌可能同时发生，忽略旧曲目的按钮事件。
    if (current != null && current.id == extras?['trackId']) {
      await onToggleNotificationFavorite?.call(current);
    }
  }

  void _publish({bool offerResume = false}) {
    if (_updatingQueue) return;
    final current = tracks.value.elementAtOrNull(index);
    final source = current == null ? null : (current.id, current.source);
    if (source != _lastSource) {
      _lastSource = source;
      _stemSelection++;
    }
    final item = current == null ? null : _mediaItem(current, _duration);
    if (item?.id != _publishedItem?.id ||
        item?.duration != _publishedItem?.duration ||
        item?.artUri != _publishedItem?.artUri) {
      _publishedItem = item;
      mediaItem.add(item);
    }

    final state = _processingState;
    final playing = _playing && state != audio.ProcessingState.completed;
    if (current?.id != _lastPlayedId ||
        state == audio.ProcessingState.idle ||
        state == audio.ProcessingState.completed) {
      _lastPlayedId = null;
    }
    if (current != null && playing && state == audio.ProcessingState.ready &&
        _lastPlayedId == null) {
      _lastPlayedId = current.id;
      _rememberPlayed(current);
    }
    playbackState.add(
      PlaybackState(
        controls: _mediaControls(playing, current),
        androidCompactActionIndices: const [0, 1, 2],
        systemActions: const {
          MediaAction.seek,
          MediaAction.skipToQueueItem,
          MediaAction.setRepeatMode,
          MediaAction.setShuffleMode,
          MediaAction.setSpeed,
        },
        processingState: switch (state) {
          // 切歌或重载音源时引擎可能短暂回到 idle。Android 会把 idle 当成
          // 停止服务并移除媒体卡片，因此有当前曲目时保留会话，显式停止由 stop() 处理。
          audio.ProcessingState.idle when Platform.isAndroid && current != null && playing =>
            AudioProcessingState.loading,
          audio.ProcessingState.idle when Platform.isAndroid && current != null &&
              (offerResume || playbackState.value.processingState != AudioProcessingState.idle) =>
            AudioProcessingState.ready,
          audio.ProcessingState.idle => AudioProcessingState.idle,
          audio.ProcessingState.loading => AudioProcessingState.loading,
          audio.ProcessingState.buffering => AudioProcessingState.buffering,
          audio.ProcessingState.ready => AudioProcessingState.ready,
          audio.ProcessingState.completed => AudioProcessingState.completed,
        },
        playing: playing,
        updatePosition: position,
        bufferedPosition: _mixPlayback?.buffered ?? _player.bufferedPosition,
        queueIndex: current == null ? null : index,
        repeatMode: _repeatMode,
        shuffleMode: _originalQueueOrder == null
            ? AudioServiceShuffleMode.none
            : AudioServiceShuffleMode.all,
        speed: _player.speed,
      ),
    );
    _fadeInWhenReady();
    final continuation = _continuation;
    if (continuation != null && !continuation.failed && _playing &&
        (state == audio.ProcessingState.ready || state == audio.ProcessingState.completed) &&
        current != null && index == tracks.value.length - 1) {
      _requestMoreTracks(continuation);
    }
  }

  void _requestMoreTracks(_QueueContinuation continuation) {
    if (continuation.loading || continuation.exhausted) return;
    continuation.loading = true;
    continuation.failed = false;
    unawaited(_loadMoreTracks(continuation));
  }

  Future<void> _loadMoreTracks(_QueueContinuation continuation) async {
    try {
      // 网络请求不占播放器的锁，等待时仍可暂停、切歌或清空队列。
      final more = await continuation.loadMore();
      await _commands.synchronized(() async {
        if (!identical(_continuation, continuation)) return;
        final previousLength = tracks.value.length;
        final current = index;
        final advanceFrom = continuation.advanceFrom;
        final advance = advanceFrom != null && advanceFrom == tracks.value.elementAtOrNull(current)?.id;
        continuation.advanceFrom = null;
        final finished = _processingState == audio.ProcessingState.completed;
        await _addTracks(more);
        continuation.exhausted = tracks.value.length == previousLength;
        final next = current + 1;
        if (index == current && next < tracks.value.length &&
            (advance || (_playing &&
                (finished || _processingState == audio.ProcessingState.completed)))) {
          // 等推荐时可能已手动入队，接当前曲目的下一首，避免跳过队尾新歌。
          if (advance) {
            await _playAt(next);
          } else {
            await _selectAndPlay(next);
          }
        }
      });
    } catch (_) {
      if (identical(_continuation, continuation)) {
        continuation.failed = true;
        continuation.advanceFrom = null;
        message.value = '无法加载更多私人 FM，点击下一首可重试。';
      }
    } finally {
      continuation.loading = false;
      if (identical(_continuation, continuation)) _publish();
    }
  }

  static audio.LoopMode _loopMode(AudioServiceRepeatMode mode) => switch (mode) {
    AudioServiceRepeatMode.none => audio.LoopMode.off,
    AudioServiceRepeatMode.one => audio.LoopMode.one,
    AudioServiceRepeatMode.all || AudioServiceRepeatMode.group => audio.LoopMode.all,
  };

  @override
  Future<void> setRepeatMode(AudioServiceRepeatMode repeatMode) =>
      _commands.synchronized(() => _setRepeatMode(repeatMode));

  /// 在队列中读取模式，连续点击时每次都从最新状态切换。
  Future<void> cycleRepeatMode() => _commands.synchronized(() {
    final next = switch (_repeatMode) {
      AudioServiceRepeatMode.none => AudioServiceRepeatMode.all,
      AudioServiceRepeatMode.all || AudioServiceRepeatMode.group =>
        AudioServiceRepeatMode.one,
      AudioServiceRepeatMode.one => AudioServiceRepeatMode.none,
    };
    return _setRepeatMode(next);
  });

  Future<void> _setRepeatMode(AudioServiceRepeatMode mode) async {
    await _player.setLoopMode(_loopMode(mode));
    if (stemMixer?.active == true) await stemMixer!.setRepeatOne(mode == AudioServiceRepeatMode.one);
    _preferredRepeatMode = _repeatMode;
    _saveSettings();
    _publish();
  }

  @override
  Future<void> setShuffleMode(AudioServiceShuffleMode shuffleMode) =>
      _commands.synchronized(() async {
        final enabled = shuffleMode != AudioServiceShuffleMode.none;
        final previousOrder = _originalQueueOrder;
        if (enabled == (previousOrder != null)) return;

        final old = tracks.value;
        final selected = old.elementAtOrNull(index);
        final savedPosition = position;
        final wasPlaying = playbackState.value.playing;
        final List<Track> updated;
        if (enabled) {
          _originalQueueOrder = old.map((track) => track.id).toList();
          final shuffled = old.where((track) => track.id != selected?.id).toList()
            ..shuffle();
          updated = [?selected, ...shuffled];
        } else {
          _originalQueueOrder = null;
          final byId = {for (final track in old) track.id: track};
          updated = [
            for (final id in previousOrder!) ?byId.remove(id),
            ...byId.values,
          ];
        }
        if (listEquals(updated, old)) {
          _queueDirty = true;
          saveProgress();
          _publish();
          return;
        }
        final slot = updated.indexWhere((track) => track.id == selected?.id);
        try {
          // 随机顺序交给现有队列自动播放，避免 Linux 原生随机打乱逻辑索引。
          await _changeQueue(updated, () async {
            await _player.stop();
            _selectedIndex = slot < 0 ? 0 : slot;
            _savedPosition = savedPosition;
            await _setSources(updated, _selectedIndex, savedPosition, preload: wasPlaying && _mixPlayback == null);
          }, minimumPosition: savedPosition);
        } catch (_) {
          _originalQueueOrder = previousOrder;
          _publish();
          rethrow;
        }
        if (wasPlaying && _mixPlayback == null) await _start();
      });

  @override
  Future<void> setSpeed(double speed) => _commands.synchronized(() async {
    if (!speed.isFinite || speed < 0.5 || speed > 2) return;
    await _player.setSpeed(speed);
    if (stemMixer?.active == true) await stemMixer!.setSpeed(speed);
    _saveSettings();
    _publish();
  });

  Future<void> setVolume(double volume) => _commands.synchronized(() async {
    if (!volume.isFinite) return;
    _cancelFade();
    _volume = volume.clamp(0, 1);
    await _player.setVolume(_volume);
    if (stemMixer?.active == true) await stemMixer!.setVolume(_volume);
    _saveSettings();
    _publish();
  });

  Future<void> setFadeMilliseconds(int value) => _commands.synchronized(() async {
    final duration = value.clamp(0, 1000);
    _store.savePreference('manual_fade_ms', '$duration');
    fadeMilliseconds.value = duration;
    if (duration == 0) {
      _cancelFade();
      await _restoreVolume();
    }
  });

  Future<void> setPreferredQuality(AudioQuality quality) =>
      _commands.synchronized(() async {
        preferredQuality.value = quality;
        _saveSettings();
      });

  /// 地址请求完成时只替换仍处在同一首歌、同一个音源的条目。
  Future<bool> replaceCurrentSource(
    Track expected,
    Uri source,
    AudioQuality actualQuality,
  ) => _commands.synchronized(() async {
    final slot = index;
    final current = tracks.value.elementAtOrNull(slot);
    if (current == null || current.id != expected.id ||
        current.source != expected.source) {
      return false;
    }
    final updated = [...tracks.value];
    updated[slot] = current.copyWith(source: source, audioQuality: actualQuality);
    if (current.source == source) {
      _publishQueue(updated);
      _queueDirty = true;
      saveProgress();
      return true;
    }

    final positionBeforeSwitch = position;
    final wasPlaying = playbackState.value.playing;
    await _changeQueue(updated, () async {
      await _closeMix();
      await _player.stop();
      _selectedIndex = slot;
      _savedPosition = positionBeforeSwitch;
      // 正在播放时先确认新音源可读取。读取失败由 _changeQueue 恢复旧音源。
      await _setSources(updated, slot, positionBeforeSwitch, preload: wasPlaying);
    }, minimumPosition: positionBeforeSwitch);
    if (wasPlaying) await _start();
    return true;
  });

  void _saveSettings() {
    try {
      _store.saveSettings(
        _preferredRepeatMode,
        _player.speed,
        volume: volume,
        preferredQuality: preferredQuality.value,
      );
    } on Exception {
      message.value = '无法保存播放设置。';
    }
  }

  void _rememberPlayed(Track track) {
    try {
      final previous = history.value;
      final duration = _duration ?? track.duration;
      _store.recordPlayed(track.copyWith(duration: duration), DateTime.now());
      final updated = List<PlayedTrack>.unmodifiable(_store.readHistory());
      history.value = updated;
      if (Platform.isAndroid) {
        final remaining = updated.map((entry) => entry.track.id).toSet();
        for (final entry in previous) {
          final source = entry.track.source;
          if (source.scheme == 'content' && !remaining.contains(entry.track.id)) {
            unawaited(_commands.synchronized(() => _releaseUnusedFile(source)));
          }
        }
      }
    } on Exception {
      message.value = '无法保存播放历史。';
    }
  }

  Future<void> removeHistoryEntry(String id) => _commands.synchronized(() async {
    final removed = history.value.where((entry) => entry.track.id == id).firstOrNull;
    if (removed == null) return;
    _store.removeHistory(id);
    history.value = List.unmodifiable(
      history.value.where((entry) => entry.track.id != id),
    );
    await _releaseUnusedFile(removed.track.source);
  });

  Future<void> _releaseUnusedFile(Uri source) async {
    // 队列和最近播放共用 Android 文件读取授权，最后一处引用删除后再释放。
    if (!Platform.isAndroid || source.scheme != 'content' || _queueDirty ||
        tracks.value.any((track) => track.source == source) ||
        history.value.any((entry) => entry.track.source == source)) {
      return;
    }
    try {
      await FilePickerAndroid().releaseSAFGrant(source.toString());
    } on Exception catch (error) {
      debugPrint('Cannot release music file grant: ${error.runtimeType}');
    }
  }

  void saveProgress({Duration? minimumPosition}) {
    if (_updatingQueue) return;
    final currentPosition = position;
    final savedPosition = minimumPosition != null && currentPosition < minimumPosition
        ? minimumPosition
        : currentPosition;
    try {
      if (_queueDirty) {
        _store.replaceQueue(
          SavedSession(tracks.value, index, savedPosition),
          originalOrder: _originalQueueOrder,
        );
        _queueDirty = false;
      } else if (tracks.value.isNotEmpty) {
        _store.savePosition(index, savedPosition);
      }
    } on Exception catch (error) {
      debugPrint('Cannot save playback session: ${error.runtimeType}');
      message.value = '无法保存播放状态。';
    }
  }

  Future<void> _start({bool switchedTrack = false}) async {
    message.value = null;
    try {
      final mixer = stemMixer;
      final restart = _processingState == audio.ProcessingState.completed;
      final duration = fadeMilliseconds.value;
      final fadeIn = duration > 0 && volume > 0 && (switchedTrack || restart || !_playing);
      if (fadeIn) {
        _cancelFade();
        if (_engineVolume != 0) await _setEngineVolume(0);
      }
      if (restart) {
        if (mixer?.active == true) {
          await mixer!.seek(Duration.zero);
        } else {
          await _player.seek(Duration.zero);
        }
      }
      if (fadeIn) _pendingFadeIn = duration;
      if (mixer?.active == true) {
        await mixer!.play();
      } else {
        // play() 会等到暂停或播完，不能占住处理切歌、暂停的锁。
        unawaited(_playUntilPaused());
      }
      _fadeInWhenReady();
    } on Exception {
      _cancelFade();
      await _restoreVolume();
      message.value = '无法开始播放，请检查文件或链接。';
    }
  }

  Future<void> _playUntilPaused() async {
    try {
      await _player.play();
    } on audio.PlayerInterruptedException {
      // 用户切歌或停止时，正在加载的播放请求会被取消。
    } catch (error) {
      await _player.pause();
      _cancelFade();
      await _restoreVolume();
      if (error is audio.PlayerException) {
        _reportPlayerError(error);
      } else {
        message.value = '无法开始播放，请检查文件或链接。';
      }
    }
  }

  void _reportPlayerError(audio.PlayerException error) {
    // 保留 Android 播放器的错误码，日志和界面不暴露带授权的音频链接。
    final notice = !Platform.isAndroid ? '播放失败，请检查文件或链接。' : switch (error.code) {
      2007 => 'Android 拦截了这首歌的 HTTP 播放地址（错误码 2007）。',
      _ => '播放失败，请检查文件或链接（错误码 ${error.code}）。',
    };
    if (message.value == notice) return;
    message.value = notice;
    debugPrint('Audio error code: ${error.code}');
  }

  @override
  Future<void> play() => _commands.synchronized(() async {
    if (tracks.value.isNotEmpty) await _start();
  });

  @override
  Future<void> pause() => _commands.synchronized(_pauseAndSave);

  /// 切歌可能先一步拿到命令锁，列表按钮只暂停它对应的歌曲。
  Future<void> pauseTrack(String trackId) => _commands.synchronized(() async {
    if (tracks.value.elementAtOrNull(index)?.id == trackId) await _pauseAndSave();
  });

  Future<void> _pauseAndSave() async {
    _continuation?.advanceFrom = null;
    try {
      await _fadeOut();
      final mixer = stemMixer;
      if (mixer?.active == true) {
        await mixer!.pause();
      } else {
        await _player.pause();
      }
    } finally {
      await _restoreVolume();
    }
    saveProgress();
  }

  @override
  Future<void> stop() => _commands.synchronized(_stopAndSave);

  Future<void> _stopAndExit(Future<void> Function() exit) async {
    // 作废正在取播放地址的换队列请求，避免退出时又开始播放。
    _queueReplacement++;
    _queuePreparation.value = null;
    await _stopAndSave();
    await exit();
  }

  Future<void> _stopAndSave() async {
    _continuation?.advanceFrom = null;
    _cancelFade();
    saveProgress();
    _selectedIndex = index;
    _savedPosition = position;
    final wasMixed = stemMixer?.active == true;
    _stemSelection++;
    await _closeMix();
    await _player.stop();
    if (wasMixed) await _setSources(tracks.value, _selectedIndex, _savedPosition);
    await _restoreVolume();
    await super.stop();
  }

  @override
  Future<void> seek(Duration position) => _commands.synchronized(() async {
    if (_duration == null) return;
    final mixer = stemMixer;
    if (mixer?.active == true) {
      await mixer!.seek(position);
    } else {
      await _player.seek(position);
    }
    saveProgress();
  });

  @override
  Future<void> skipToQueueItem(int index) =>
      _commands.synchronized(() => _playAt(index));

  @override
  Future<void> skipToNext() =>
      _commands.synchronized(() async {
        final continuation = _continuation;
        if (continuation != null && !continuation.exhausted &&
            tracks.value.isNotEmpty && index == tracks.value.length - 1) {
          continuation.advanceFrom = tracks.value[index].id;
          _requestMoreTracks(continuation);
          return;
        }
        await _playAt(_neighborIndex(1));
      });

  @override
  Future<void> skipToPrevious() =>
      _commands.synchronized(() => _playAt(_neighborIndex(-1)));

  int? _neighborIndex(int step) {
    final length = tracks.value.length;
    if (length == 0) return null;
    final next = index + step;
    if (next >= 0 && next < length) return next;
    // 单曲循环只影响自然播完，手动切歌仍能选相邻曲目。
    return _player.loopMode == audio.LoopMode.all ? next % length : null;
  }

  Future<void> _playAt(int? slot) async {
    if (slot == null || slot < 0 || slot >= tracks.value.length) return;
    if (fadeMilliseconds.value == 0 || !_playing || slot == index || volume == 0) {
      await _selectAndPlay(slot);
      return;
    }
    try {
      await _fadeOut();
      await _selectAndPlay(slot, switchedTrack: true);
    } catch (_) {
      await _restoreVolume();
      rethrow;
    }
  }

  void _cancelFade() {
    _fadeGeneration++;
    _pendingFadeIn = null;
  }

  Future<void> _restoreVolume() async {
    if (_engineVolume != volume) await _setEngineVolume(volume);
  }

  Future<void> _setEngineVolume(double level) {
    final mixer = stemMixer;
    return mixer?.active == true ? mixer!.setVolume(level) : _player.setVolume(level);
  }

  Future<void> _fadeOut() async {
    _cancelFade();
    final duration = fadeMilliseconds.value;
    if (duration > 0 && _engineVolume > 0 && _playing &&
        _processingState == audio.ProcessingState.ready) {
      await _rampVolume(_engineVolume, 0, duration, _fadeGeneration);
    }
  }

  void _fadeInWhenReady() {
    final duration = _pendingFadeIn;
    if (duration == null || !_playing ||
        _processingState != audio.ProcessingState.ready) {
      return;
    }
    // 音源就绪后才计时，加载慢时也能听到完整的淡入。
    _pendingFadeIn = null;
    unawaited(_fadeToPlaybackVolume(duration, _fadeGeneration));
  }

  Future<void> _fadeToPlaybackVolume(int duration, int generation) async {
    try {
      await _rampVolume(_engineVolume, volume, duration, generation);
    } on Exception {
      if (generation == _fadeGeneration) message.value = '无法调整播放音量。';
    }
  }

  Future<void> _rampVolume(double start, double end, int milliseconds, int generation) async {
    final steps = (milliseconds ~/ 20).clamp(1, 50);
    for (var step = 1; step <= steps; step++) {
      await Future<void>.delayed(Duration(microseconds: milliseconds * 1000 ~/ steps));
      if (generation != _fadeGeneration) return;
      final level = step == steps ? end : start + (end - start) * step / steps;
      await _setEngineVolume(level);
    }
  }

  Future<void> _selectAndPlay(int slot, {bool switchedTrack = false}) async {
    _savedPosition = Duration.zero;
    final mixer = stemMixer;
    if (mixer?.active == true) {
      if (slot == index) {
        await mixer!.seek(Duration.zero);
        await _start(switchedTrack: switchedTrack);
        saveProgress();
        return;
      }
      await _closeMix();
    }
    if (_player.processingState == audio.ProcessingState.loading ||
        _player.processingState == audio.ProcessingState.idle) {
      await _player.stop();
      _selectedIndex = slot;
      await _setSources(tracks.value, slot, Duration.zero);
    } else {
      // 使用新曲目的默认起点，避免 Linux 后端切歌时对旧曲目执行拖动。
      await _player.seek(null, index: slot);
    }
    await _start(switchedTrack: switchedTrack);
    saveProgress();
  }
}

class _QueueContinuation {
  _QueueContinuation(this.loadMore);

  final Future<List<Track>> Function() loadMore;
  bool loading = false;
  bool exhausted = false;
  bool failed = false;
  String? advanceFrom;
}

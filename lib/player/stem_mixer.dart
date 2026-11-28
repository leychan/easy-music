import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart' as audio;

class StemPreparation {
  StemPreparation(this.id);

  final int id;
  String stage = 'reading';
  double? fraction;
  bool hasSourceProgress = false;
  bool cancelled = false;
}

class StemPlayback {
  StemPlayback(Map<Object?, Object?> values)
    : state = switch (values['state']) {
        2 => audio.ProcessingState.buffering,
        3 => audio.ProcessingState.ready,
        4 => audio.ProcessingState.completed,
        _ => audio.ProcessingState.idle,
      },
      playing = values['playing'] == true,
      position = Duration(milliseconds: values['position'] as int),
      duration = Duration(milliseconds: values['duration'] as int),
      buffered = Duration(milliseconds: values['buffered'] as int);

  final audio.ProcessingState state;
  final bool playing;
  final Duration position;
  final Duration duration;
  final Duration buffered;
}

typedef KaraokeInput = ({
  double level,
  String route,
  String state,
  bool bluetoothOutput,
});

/// Android 播放引擎与分轨任务通过同一个 FlutterEngine 跨界面和锁屏使用。
class StemMixer extends ChangeNotifier {
  StemMixer({
    required this.onPlayback,
    required this.onError,
    this.allowKaraoke,
  });

  final void Function(bool positionOnly) onPlayback;
  final void Function(int id) onError;
  final bool Function()? allowKaraoke;

  static const _methods = MethodChannel('dev.easymusic.easy_music/stems');
  static const _events = EventChannel('dev.easymusic.easy_music/stem_events');
  static const _external = MethodChannel('dev.easymusic.easy_music/external');

  StreamSubscription<dynamic>? _subscription;
  int _nextId = 0;
  StemPreparation? preparation;
  StemPlayback? playback;
  int? playbackId;
  String? trackId;
  String? _gainTrackId;
  double vocals = 1;
  double accompaniment = 1;
  double microphone = 0.5;
  double reverb = 0.18;
  double masterVolume = 1;
  bool karaokeEnabled = false;
  String? karaokeError;
  final _microphoneInput = ValueNotifier<KaraokeInput?>(null);
  int? _karaokeRequest;
  bool clearing = false;

  bool get active => playbackId != null;
  bool get changingKaraoke => active && _karaokeRequest == playbackId;
  ValueListenable<KaraokeInput?> get microphoneInput => _microphoneInput;
  double vocalsFor(String id) => _gainTrackId == id ? vocals : 1;
  double accompanimentFor(String id) => _gainTrackId == id ? accompaniment : 1;

  Future<bool> hasResources(Uri source, {String? cacheKey}) async =>
      await _methods.invokeMethod<bool>('hasResources', {
        'uri': source.toString(),
        'cacheKey': ?cacheKey,
      }) ??
      false;

  StemPreparation? begin() {
    if (preparation != null || clearing) return null;
    _subscription ??= _events.receiveBroadcastStream().listen(
      _onEvent,
      onError: (Object error) {
        final type = error.runtimeType;
        debugPrint('Cannot receive stem events: $type');
      },
    );
    final request = preparation = StemPreparation(++_nextId);
    notifyListeners();
    return request;
  }

  Future<String> prepare(
    StemPreparation request,
    Uri source, {
    String? cacheKey,
  }) async {
    return (await _methods.invokeMethod<String>('prepare', {
      'id': request.id,
      'uri': source.toString(),
      'cacheKey': ?cacheKey,
    }))!;
  }

  Future<void> cancel() async {
    final request = preparation;
    if (request == null || request.cancelled) return;
    request.cancelled = true;
    notifyListeners();
    await _methods.invokeMethod<void>('cancel', {'id': request.id});
  }

  void finish(StemPreparation request) {
    if (!identical(preparation, request)) return;
    preparation = null;
    notifyListeners();
  }

  Future<void> load({
    required StemPreparation request,
    required String sourceTrackId,
    required String path,
    required Duration position,
    required double volume,
    required double speed,
    required bool repeatOne,
  }) async {
    request.stage = 'loading';
    request.fraction = null;
    notifyListeners();
    final voice = vocalsFor(sourceTrackId);
    final music = accompanimentFor(sourceTrackId);
    final state = await _methods
        .invokeMapMethod<Object?, Object?>('load', {
          'id': request.id,
          'path': path,
          'position': position.inMilliseconds,
          'vocals': voice,
          'accompaniment': music,
          'volume': volume,
          'speed': speed,
          'repeatOne': repeatOne,
        })
        .timeout(const Duration(seconds: 10));
    playbackId = request.id;
    trackId = sourceTrackId;
    _gainTrackId = sourceTrackId;
    playback = StemPlayback(state!);
    vocals = voice;
    accompaniment = music;
    microphone = 0.5;
    reverb = 0.18;
    karaokeEnabled = false;
    karaokeError = null;
    _microphoneInput.value = null;
    masterVolume = volume;
    notifyListeners();
  }

  Future<StemPlayback?> close() async {
    playbackId = null;
    trackId = null;
    final previous = playback;
    playback = null;
    karaokeEnabled = false;
    karaokeError = null;
    _microphoneInput.value = null;
    notifyListeners();
    final state = await _methods.invokeMapMethod<Object?, Object?>('close');
    return state == null ? previous : StemPlayback(state);
  }

  Future<void> play() => _transport('play');
  Future<void> pause() => _transport('pause');
  Future<void> seek(Duration position) =>
      _transport('seek', {'position': position.inMilliseconds});
  Future<void> setSpeed(double speed) => _transport('speed', {'speed': speed});

  Future<void> setRepeatOne(bool enabled) =>
      _methods.invokeMethod<void>('repeatOne', {'enabled': enabled});

  Future<void> setVolume(double volume) async {
    masterVolume = volume;
    await _methods.invokeMethod<void>('volume', {'volume': volume});
  }

  Future<void> setKaraoke(bool enabled) async {
    final id = playbackId;
    if (id == null) return;
    if (!enabled) {
      if (karaokeEnabled || changingKaraoke) {
        await _transport('karaoke', {'enabled': false});
      }
      return;
    }
    if (changingKaraoke || karaokeEnabled || allowKaraoke?.call() == false) {
      return;
    }
    _karaokeRequest = id;
    karaokeError = null;
    notifyListeners();
    try {
      final granted = await _external.invokeMethod<bool>(
        'karaokeMicrophonePermission',
      );
      if (id != playbackId || allowKaraoke?.call() == false) return;
      if (granted != true) {
        throw PlatformException(
          code: 'microphone',
          message: '请允许麦克风权限后开启 K 歌。',
        );
      }
      await _transport('karaoke', {'enabled': true});
    } finally {
      if (_karaokeRequest == id) _karaokeRequest = null;
      if (id == playbackId) notifyListeners();
    }
  }

  Future<void> setGains({
    double? voice,
    double? music,
    double? mic,
    double? room,
  }) async {
    if (!active) return;
    vocals = voice ?? vocals;
    accompaniment = music ?? accompaniment;
    microphone = mic ?? microphone;
    reverb = room ?? reverb;
    notifyListeners();
    await _methods.invokeMethod<void>('mix', {
      'vocals': vocals,
      'accompaniment': accompaniment,
      'microphone': microphone,
      'reverb': reverb,
    });
  }

  Future<void> clear() async {
    if (active || preparation != null || clearing) return;
    clearing = true;
    notifyListeners();
    try {
      await _methods.invokeMethod<void>('clear');
    } finally {
      clearing = false;
      notifyListeners();
    }
  }

  Future<void> _transport(String method, [Map<String, Object?>? args]) async {
    final id = playbackId;
    final state = await _methods.invokeMapMethod<Object?, Object?>(
      method,
      args,
    );
    if (id != null && id == playbackId && state != null) {
      playback = StemPlayback(state);
      _updateKaraoke(state);
      onPlayback(false);
    }
  }

  void _onEvent(dynamic data) {
    final event = data as Map<Object?, Object?>;
    final id = event['id'] as int;
    if (event['event'] == 'progress') {
      final request = preparation;
      if (request == null || request.id != id || request.cancelled) return;
      request.hasSourceProgress = true;
      request.stage = event['stage'] as String;
      request.fraction = event['fraction'] as double?;
      notifyListeners();
    } else if (id == playbackId) {
      if (event['event'] == 'error') {
        onError(id);
      } else if (event['event'] == 'karaokeError') {
        karaokeError = '无法读取麦克风，请检查录音权限后重试。';
        karaokeEnabled = false;
        _microphoneInput.value = null;
        notifyListeners();
      } else {
        playback = StemPlayback(event);
        _updateKaraoke(event);
        onPlayback(event['event'] == 'position');
      }
    }
  }

  void _updateKaraoke(Map<Object?, Object?> state) {
    final enabled = state['karaoke'] == true;
    final input = state['microphoneInput'];
    _microphoneInput.value = enabled && input is Map
        ? (
            level: (input['level'] as num).toDouble(),
            route: input['route'] as String,
            state: input['state'] as String,
            bluetoothOutput: input['bluetoothOutput'] == true,
          )
        : null;
    if (karaokeEnabled == enabled) return;
    karaokeEnabled = enabled;
    notifyListeners();
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    _microphoneInput.dispose();
    super.dispose();
  }
}

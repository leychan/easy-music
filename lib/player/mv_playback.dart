import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart' as media;
import 'package:media_kit_video/media_kit_video.dart' as media_video;
import 'package:video_player/video_player.dart' as video;
import 'package:wakelock_plus/wakelock_plus.dart';

typedef MvTimeline = ({Duration position, Duration duration});

/// 两个平台共用播放页和进度条，底层各自提供画面和播放状态。
abstract class MvPlayback {
  factory MvPlayback(Uri source, {required VoidCallback onError}) =>
      Platform.isAndroid
      ? _ExoPlayerPlayback(source, onError)
      : _MediaKitPlayback(source, onError);

  MvPlayback._();

  static const emptyTimeline = (
    position: Duration.zero,
    duration: Duration.zero,
  );
  final _timeline = ValueNotifier<MvTimeline>(emptyTimeline);

  ValueListenable<MvTimeline> get timeline => _timeline;

  Future<void> initialize();
  Future<void> play();
  Future<void> togglePlayback();
  Future<void> seek(Duration position);
  Widget buildVideo();

  Future<void> dispose() async => _timeline.dispose();
}

class _ExoPlayerPlayback extends MvPlayback with WidgetsBindingObserver {
  _ExoPlayerPlayback(Uri source, this._onError)
    : _controller = video.VideoPlayerController.networkUrl(
        source,
        // MV 退到后台时暂停，回前台时由用户决定是否继续。
        videoPlayerOptions: video.VideoPlayerOptions(
          allowBackgroundPlayback: true,
        ),
      ),
      super._() {
    _controller.addListener(_update);
    WidgetsBinding.instance.addObserver(this);
  }

  final video.VideoPlayerController _controller;
  final VoidCallback _onError;
  bool _keepsScreenOn = false;

  void _update() {
    final value = _controller.value;
    if (value.hasError) {
      _onError();
      return;
    }
    _timeline.value = (position: value.position, duration: value.duration);
    _keepScreenOn(value.isPlaying);
  }

  void _keepScreenOn(bool enable) {
    if (_keepsScreenOn == enable) return;
    _keepsScreenOn = enable;
    unawaited(
      WakelockPlus.toggle(enable: enable).catchError((Object error) {
        debugPrint('Could not update MV wakelock: ${error.runtimeType}');
      }),
    );
  }

  @override
  Future<void> initialize() => _controller.initialize();

  @override
  Future<void> play() async {
    final state = WidgetsBinding.instance.lifecycleState;
    if (state != AppLifecycleState.paused &&
        state != AppLifecycleState.detached) {
      await _controller.play();
    }
  }

  @override
  Future<void> togglePlayback() async {
    if (!_controller.value.isInitialized) return;
    await (_controller.value.isPlaying ? _controller.pause() : play());
  }

  @override
  Future<void> seek(Duration position) => _controller.seekTo(position);

  @override
  Widget buildVideo() => ValueListenableBuilder<video.VideoPlayerValue>(
    valueListenable: _controller,
    child: video.VideoPlayer(_controller),
    builder: (context, value, child) => Center(
      child: value.isInitialized
          ? AspectRatio(aspectRatio: value.aspectRatio, child: child)
          : const CircularProgressIndicator(semanticsLabel: '正在加载 MV'),
    ),
  );

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if ((state == AppLifecycleState.paused ||
            state == AppLifecycleState.detached) &&
        _controller.value.isPlaying) {
      unawaited(_controller.pause().catchError((Object _) => _onError()));
    }
  }

  @override
  Future<void> dispose() async {
    WidgetsBinding.instance.removeObserver(this);
    _controller.removeListener(_update);
    _keepScreenOn(false);
    try {
      await _controller.dispose();
    } finally {
      await super.dispose();
    }
  }
}

class _MediaKitPlayback extends MvPlayback {
  _MediaKitPlayback(this._source, VoidCallback onError) : super._() {
    media.MediaKit.ensureInitialized();
    _player = media.Player();
    _controller = media_video.VideoController(_player);
    _subscriptions = [
      _player.stream.error.listen((_) => onError()),
      _player.stream.position.listen((position) {
        _timeline.value = (
          position: position,
          duration: _timeline.value.duration,
        );
      }),
      _player.stream.duration.listen((duration) {
        _timeline.value = (
          position: _timeline.value.position,
          duration: duration,
        );
      }),
    ];
  }

  final Uri _source;
  late final media.Player _player;
  late final media_video.VideoController _controller;
  late final List<StreamSubscription<dynamic>> _subscriptions;

  @override
  Future<void> initialize() async => _controller.platform.future;

  @override
  Future<void> play() => _player.open(media.Media(_source.toString()));

  @override
  Future<void> togglePlayback() async {
    if (_player.state.playlist.medias.isNotEmpty) await _player.playOrPause();
  }

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  Widget buildVideo() => media_video.Video(
    controller: _controller,
    controls: media_video.NoVideoControls,
  );

  @override
  Future<void> dispose() async {
    try {
      await Future.wait(
        _subscriptions.map((subscription) => subscription.cancel()),
      );
      await _player.dispose();
    } finally {
      await super.dispose();
    }
  }
}

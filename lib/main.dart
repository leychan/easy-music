import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart' show SystemNavigator;
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'player/audio_cache.dart';
import 'player/playback.dart';
import 'player/session_store.dart';
import 'ui/app_background.dart';
import 'ui/appearance.dart';
import 'ui/external_actions.dart';
import 'ui/player_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  Playback? playback;
  Appearance? appearance;
  SessionStore? sessionStore;
  String? errorMessage;
  try {
    if (Platform.isLinux) {
      try {
        JustAudioMediaKit.ensureInitialized();
      } catch (_) {
        errorMessage = '无法加载 libmpv。请安装发行版的 mpv 或 libmpv 包后重启应用。';
        rethrow;
      }
    }

    final support = await getApplicationSupportDirectory();
    await support.create(recursive: true);
    final session = SessionStore(p.join(support.path, 'player.sqlite3'));
    sessionStore = session;
    appearance = Appearance(session);
    AudioCache? audioCache;
    try {
      final cache = await getApplicationCacheDirectory();
      audioCache = await AudioCache.open(Directory(p.join(cache.path, 'music-audio')), session);
    } on Exception catch (error) {
      // 缓存目录不可用时，播放器仍然可以直接播放在线音源。
      debugPrint('Cannot start audio cache: ${error.runtimeType}');
    }
    final handler = await AudioService.init(
      builder: () => Playback(session, audioCache: audioCache),
      config: const AudioServiceConfig(
        androidNotificationChannelId: 'dev.easymusic.player',
        androidNotificationChannelName: 'Easy Music',
        androidNotificationIcon: 'drawable/ic_music_notification',
        // 暂停时继续保留媒体服务，锁屏后可通过耳机或通知恢复播放。
        androidStopForegroundOnPause: false,
      ),
    );
    handler.onExit = Platform.isLinux
        ? quitDesktopApp
        : Platform.isAndroid
        ? quitAndroidApp
        : SystemNavigator.pop;
    await handler.restore();
    if (Platform.isLinux) _bindTrayPlayback(handler);
    playback = handler;
  } catch (error, stack) {
    debugPrint('Easy Music failed to start: $error\n$stack');
    errorMessage ??= '无法启动播放器。请重新打开应用。';
  }
  runApp(EasyMusicApp(
    playback: playback, startupError: errorMessage, appearance: appearance, sessionStore: sessionStore,
  ));
}

void _bindTrayPlayback(Playback player) {
  // 托盘和播放器同生命周期，隐藏主窗口后也能继续控制同一条播放队列。
  bindDesktopActions((method, argument) async {
    switch (method) {
      case 'trayPlayPause':
        await (player.playbackState.value.playing ? player.pause() : player.play());
      case 'trayPrevious':
        await player.skipToPrevious();
      case 'trayNext':
        await player.skipToNext();
      case 'trayVolume' when argument is int:
        await player.setVolume(player.volume + argument * 0.05);
      case 'trayQuit':
        try {
          await player.stop();
        } finally {
          await quitDesktopApp();
        }
    }
  });
  // 进度变化也会发布播放状态，只在菜单内容变化时通知桌面。
  player.playbackState.map((state) => (
    title: player.mediaItem.value?.title,
    playing: state.playing,
    hasPrevious: player.hasPrevious,
    hasNext: player.hasNext,
  )).distinct().listen((state) {
    unawaited(updateTrayPlayback(
      title: state.title,
      playing: state.playing,
      hasPrevious: state.hasPrevious,
      hasNext: state.hasNext,
    ));
  });
}

class EasyMusicApp extends StatelessWidget {
  const EasyMusicApp({super.key, this.playback, this.startupError, this.appearance, this.sessionStore});

  final Playback? playback;
  final String? startupError;
  final Appearance? appearance;
  final SessionStore? sessionStore;

  @override
  Widget build(BuildContext context) {
    final preferences = appearance;
    return preferences == null
        ? _buildApp(Appearance.defaults)
        : ValueListenableBuilder(
            valueListenable: preferences,
            builder: (context, options, _) => _buildApp(options),
          );
  }

  Widget _buildApp(AppearanceOptions options) {
    ThemeData theme(Brightness brightness) {
      final dark = brightness == Brightness.dark;
      return ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: options.color,
          brightness: brightness,
          surface: dark ? Appearance.nightSurface : Appearance.daySurface,
          surfaceContainerLowest: dark ? const Color(0xFF18131C) : const Color(0xFFFFFCF7),
          surfaceContainerLow: dark ? const Color(0xFF231B27) : const Color(0xFFF9F2E9),
          surfaceContainer: dark ? const Color(0xFF2A2130) : const Color(0xFFF4EBE0),
          surfaceContainerHigh: dark ? const Color(0xFF302737) : const Color(0xFFF0E5D8),
          surfaceContainerHighest: dark ? const Color(0xFF392F40) : const Color(0xFFEBDFD2),
        ),
      );
    }
    final player = playback;
    return MaterialApp(
      title: 'Easy Music',
      debugShowCheckedModeBanner: false,
      theme: theme(Brightness.light),
      darkTheme: theme(Brightness.dark),
      themeMode: options.mode,
      builder: (context, child) => BackgroundStyleScope(style: options.background, child: child!),
      home: player != null
          ? PlayerPage(player: player, appearance: appearance, sessionStore: sessionStore)
          : AppBackground(
              child: Scaffold(
                backgroundColor: Colors.transparent,
                body: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(startupError ?? '无法启动播放器。'),
                  ),
                ),
              ),
            ),
    );
  }
}

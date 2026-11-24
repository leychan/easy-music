import 'dart:io';

import 'package:flutter/services.dart';

const _external = MethodChannel('dev.easymusic.easy_music/external');
const _desktop = MethodChannel('dev.easymusic.easy_music/desktop');

Future<void> setMiniWindow(bool enabled) =>
    _desktop.invokeMethod<void>('mini', enabled);

Future<void> setDesktopLyricsVisible(bool visible) =>
    _desktop.invokeMethod<void>('lyricsVisible', visible);

Future<void> setDesktopLyricText(String text) =>
    _desktop.invokeMethod<void>('lyrics', text);

Future<void> quitDesktopApp() => _desktop.invokeMethod<void>('quit');

Future<void> updateTrayPlayback({
  required String? title,
  required bool playing,
  required bool hasPrevious,
  required bool hasNext,
}) => _desktop.invokeMethod<void>('trayPlayback', {
  'title': title,
  'playing': playing,
  'hasPrevious': hasPrevious,
  'hasNext': hasNext,
});

void bindDesktopActions(Future<void> Function(String, Object?) handler) {
  _desktop.setMethodCallHandler((call) => handler(call.method, call.arguments));
}

Future<bool> managePlaybackNotifications({bool automatic = false}) async =>
    await _external.invokeMethod<bool>('playbackNotifications', automatic) ?? false;

/// 从通知操作时界面可能在后台，由 Android 显示提示。
Future<void> showPlaybackNotificationNotice(String message) =>
    _external.invokeMethod<void>('playbackNotificationNotice', message);

Future<void> openWebAddress(Uri uri) async {
  if ((uri.scheme != 'https' && uri.scheme != 'http') ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty) {
    throw ArgumentError.value(uri.scheme, 'scheme');
  }
  if (Platform.isAndroid) {
    await _external.invokeMethod<void>('open', uri.toString());
  } else {
    final result = await Process.run('xdg-open', [uri.toString()]);
    if (result.exitCode != 0) throw StateError('无法打开链接。');
  }
}

/// Android 打开系统分享面板，桌面返回是否已复制到剪贴板。
Future<bool> shareText(String text) async {
  if (Platform.isAndroid) {
    await _external.invokeMethod<void>('share', text);
    return false;
  }
  await Clipboard.setData(ClipboardData(text: text));
  return true;
}

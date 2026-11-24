import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 轻量诊断日志。
///
/// 为什么不用 `debugPrint` 就够：桌面应用通常从图标启动，标准输出被丢弃，
/// 用户根本拿不到日志。这里额外写一份到文件，出问题时可以直接把文件发出来。
///
/// 约定：
/// - 只记录诊断信息，**绝不写 token 全文、密码、设备指纹**。
/// - 写文件失败一律吞掉——日志不能影响主流程。
class Diagnostics {
  Diagnostics._();

  static IOSink? _sink;
  static File? _file;
  static bool _opened = false;

  /// 日志文件位置。打开失败时为 null。
  static Future<File?> file() async {
    if (_opened) return _file;
    _opened = true;
    try {
      final dir = await getApplicationSupportDirectory();
      final logDir = Directory(p.join(dir.path, 'logs'));
      await logDir.create(recursive: true);
      final target = File(p.join(logDir.path, 'easy_music.log'));
      // 单文件超过 2MB 时轮转一次，避免无限增长。
      if (await target.exists() && await target.length() > 2 * 1024 * 1024) {
        final rotated = File('${target.path}.1');
        if (await rotated.exists()) await rotated.delete();
        await target.rename(rotated.path);
      }
      _file = target;
      _sink = target.openWrite(mode: FileMode.append);
    } on Object {
      _file = null;
      _sink = null;
    }
    return _file;
  }

  /// 写一条日志。`tag` 会被方括号包起来，便于 grep。
  static void log(String tag, String message) {
    final line = '[${DateTime.now().toIso8601String()}] [$tag] $message';
    debugPrint(line);
    final sink = _sink;
    if (sink == null) {
      // 尚未初始化时补一次，保证最早的启动日志也不丢。
      _opened = false;
      unawaited(file().then((_) {
        try {
          _sink?.writeln(line);
        } on Object {
          // 忽略。
        }
      }));
      return;
    }
    try {
      sink.writeln(line);
    } on Object {
      // 忽略：日志写入失败不影响功能。
    }
  }
}

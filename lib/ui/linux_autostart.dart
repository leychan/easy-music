import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;

import 'music_toast.dart';

class LinuxAutostart extends StatefulWidget {
  const LinuxAutostart({super.key});

  @override
  State<LinuxAutostart> createState() => _LinuxAutostartState();
}

class _LinuxAutostartState extends State<LinuxAutostart> {
  static const _marker = 'X-EasyMusic-Managed=true';
  bool? _enabled;
  bool _busy = false;

  File get _entry {
    final config = Platform.environment['XDG_CONFIG_HOME'];
    final base = config != null && p.isAbsolute(config)
        ? config
        : p.join(Platform.environment['HOME'] ?? '', '.config');
    if (!p.isAbsolute(base)) throw StateError('无法定位用户配置目录。');
    return File(p.join(base, 'autostart', 'dev.easymusic.easy_music.desktop'));
  }

  @override
  void initState() {
    super.initState();
    _read();
  }

  Future<void> _read() async {
    try {
      final entry = _entry;
      final exists = await entry.exists();
      final file = exists ? await entry.readAsString() : '';
      if (mounted) setState(() => _enabled = file.contains(_marker));
    } catch (_) {
      if (mounted) showMusicNotice(context, '无法读取自启动设置。');
    }
  }

  Future<void> _change(bool enabled) async {
    setState(() => _busy = true);
    try {
      final entry = _entry;
      if (await entry.exists() &&
          !(await entry.readAsString()).contains(_marker)) {
        throw StateError('已有由系统管理的自启动项。');
      }
      if (enabled) {
        final executable = Platform.resolvedExecutable;
        if (RegExp(r'[\r\n=]').hasMatch(executable)) {
          throw StateError('无效的程序路径。');
        }
        final argument = executable
            .replaceAll(r'\', r'\\\\')
            .replaceAll('"', r'\\"')
            .replaceAll(r'$', r'\\$')
            .replaceAll(
              String.fromCharCode(96),
              r'\\' + String.fromCharCode(96),
            )
            .replaceAll('%', '%%');
        await entry.parent.create(recursive: true);
        final temp = File('${entry.path}.tmp');
        await temp.writeAsString(
          '[Desktop Entry]\nType=Application\nName=Easy Music\n'
          'Exec="$argument"\nTerminal=false\n$_marker\n',
          flush: true,
        );
        await temp.rename(entry.path);
      } else if (await entry.exists()) {
        await entry.delete();
      }
      if (mounted) setState(() => _enabled = enabled);
    } catch (_) {
      if (mounted) showMusicNotice(context, '无法更改自启动设置。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => SwitchListTile(
    contentPadding: EdgeInsets.zero,
    title: const Text('登录桌面时启动'),
    value: _enabled ?? false,
    onChanged: _busy || _enabled == null ? null : _change,
  );
}

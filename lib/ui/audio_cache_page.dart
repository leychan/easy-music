import 'package:material_ui/material_ui.dart';

import '../player/audio_cache.dart';
import 'app_dialog.dart';
import 'music_toast.dart';
import 'workspace_page.dart';

String formatCacheSize(int bytes) {
  if (bytes == 0) return '0 MB';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).ceil()} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

class AudioCachePage extends StatefulWidget {
  const AudioCachePage({super.key, required this.cache});

  final AudioCache cache;

  @override
  State<AudioCachePage> createState() => _AudioCachePageState();
}

class _AudioCachePageState extends State<AudioCachePage> {
  bool _busy = false;

  String _limitLabel(int limit) => limit == 0 ? '关闭缓存' : '$limit MB';

  Future<void> _changeLimit(int current) async {
    final selected = await showDialog<int>(
      context: context,
      builder: (_) => AppChoiceDialog(
        title: '缓存上限',
        options: [
          for (final limit in AudioCache.limitsMiB)
            (limit, limit == 0 ? '关闭并清空缓存' : _limitLabel(limit)),
        ],
        selected: current,
      ),
    );
    if (!mounted || selected == null || selected == current) return;
    await _run(() => widget.cache.setLimit(selected), '无法更新缓存上限。');
  }

  Future<void> _clear() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AppDialog(
        title: const Text('清空音频缓存？'),
        content: const Text('清空后，再次播放这些在线歌曲时会重新获取音频。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;
    await _run(widget.cache.clear, '无法清空音频缓存。', success: '已清空音频缓存。');
  }

  Future<void> _run(
    Future<void> Function() action,
    String failure, {
    String? success,
  }) async {
    setState(() => _busy = true);
    try {
      await action();
      if (mounted && success != null) showMusicNotice(context, success);
    } on Exception {
      if (mounted) showMusicNotice(context, failure);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => WorkspacePage(
    title: const Text('音频缓存'),
    body: SafeArea(
      child: ValueListenableBuilder(
        valueListenable: widget.cache.usage,
        builder: (context, usage, _) => ListView(
          padding: DesktopPageScope.bodyPadding(
            context,
            const EdgeInsets.fromLTRB(20, 16, 20, 24),
          ),
          children: [
            ListTile(
              leading: const Icon(Icons.storage_outlined),
              title: Text('已使用 ${formatCacheSize(usage.bytes)}'),
              subtitle: Text('已缓存 ${usage.tracks} 个音频文件'),
            ),
            ListTile(
              leading: const Icon(Icons.tune_rounded),
              title: const Text('缓存上限'),
              subtitle: Text(
                usage.limitMiB == 0 ? '已关闭' : _limitLabel(usage.limitMiB),
              ),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: _busy ? null : () => _changeLimit(usage.limitMiB),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline_rounded),
              title: const Text('清空缓存'),
              enabled: !_busy && usage.limitMiB > 0,
              onTap: _busy || usage.limitMiB == 0 ? null : _clear,
            ),
          ],
        ),
      ),
    ),
  );
}

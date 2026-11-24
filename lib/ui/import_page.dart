import 'package:material_ui/material_ui.dart';

import '../account/kugou/kugou_auth.dart';
import '../music/music_library.dart';
import '../music/playlist_import.dart';
import '../music/song.dart';
import 'music_toast.dart';
import 'workspace_page.dart';

class ImportPlaylistPage extends StatefulWidget {
  const ImportPlaylistPage({super.key, required this.library});
  final MusicLibrary library;

  @override
  State<ImportPlaylistPage> createState() => _ImportPlaylistPageState();
}

class _ImportPlaylistPageState extends State<ImportPlaylistPage> {
  final _link = TextEditingController();
  ImportPreview? _preview;
  List<Playlist> _targets = const [];
  Playlist? _target;
  bool _busy = false;
  String? _progress;

  @override
  void dispose() {
    _link.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } on KugouFailure catch (error) {
      if (mounted) showMusicNotice(context, error.message);
    } catch (_) {
      if (mounted) showMusicNotice(context, '歌单导入失败，请稍后重试。');
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _progress = null;
        });
      }
    }
  }

  Future<void> _load() => _run(() async {
    setState(() {
      _preview = null;
      _target = null;
    });
    final results = await widget.library.previewPlaylistImport(_link.text);
    final targets = (await widget.library.myPlaylists())
        .where(widget.library.canEditPlaylist)
        .toList();
    if (!mounted) return;
    setState(() {
      _preview = results;
      _targets = targets;
    });
  });

  Future<void> _import(ImportPreview source, Playlist target) => _run(() async {
    final result = await widget.library.importPlaylist(
      source,
      target,
      isOpen: () => mounted,
      onProgress: (done, total) {
        if (mounted) setState(() => _progress = '已匹配 $done / $total 首');
      },
    );
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('导入结果'),
        content: Text(
          '已添加 ${result.added} 首\n未匹配 ${result.unmatched} 首\n重复 ${result.duplicates} 首',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('完成'),
          ),
        ],
      ),
    );
  });

  @override
  Widget build(BuildContext context) {
    final preview = _preview;
    final target = _target;
    return WorkspacePage(
      title: const Text('导入公开歌单'),
      body: SafeArea(
        child: ListView(
          padding: DesktopPageScope.bodyPadding(context, const EdgeInsets.all(20)),
          children: [
            TextField(
              controller: _link,
              enabled: !_busy,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(labelText: '公开歌单链接'),
              onSubmitted: (_) => _load(),
            ),
            const SizedBox(height: 12),
            FilledButton.tonal(
              onPressed: _busy ? null : _load,
              child: const Text('读取歌单'),
            ),
            if (_busy) ...[
              const LinearProgressIndicator(),
              if (_progress != null) Text(_progress!),
            ],
            if (preview != null) ...[
              ListTile(
                title: Text(preview.title),
                subtitle: Text('${preview.tracks.length} 首'),
              ),
              if (_targets.isEmpty)
                const Text('请先登录并创建一个酷狗歌单。')
              else
                DropdownButton<Playlist>(
                  value: target,
                  isExpanded: true,
                  hint: const Text('选择导入目标'),
                  items: [
                    for (final item in _targets)
                      DropdownMenuItem(value: item, child: Text(item.name)),
                  ],
                  onChanged: _busy
                      ? null
                      : (item) => setState(() => _target = item),
                ),
              FilledButton(
                onPressed: _busy || target == null || preview.tracks.isEmpty
                    ? null
                    : () => _import(preview, target),
                child: const Text('开始导入'),
              ),
              for (final track in preview.tracks.take(12))
                ListTile(
                  dense: true,
                  title: Text(track.title),
                  subtitle: Text(track.artists),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

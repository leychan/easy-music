import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';

import '../account/kugou/kugou_auth.dart';
import '../music/music_library.dart';
import '../music/playlist_file_import.dart';
import '../music/playlist_import.dart';
import '../music/song.dart';
import 'music_toast.dart';
import 'playlist_actions.dart';
import 'workspace_page.dart';

class ImportPlaylistPage extends StatefulWidget {
  const ImportPlaylistPage({super.key, required this.library});
  final MusicLibrary library;

  @override
  State<ImportPlaylistPage> createState() => _ImportPlaylistPageState();
}

class _ImportPlaylistPageState extends State<ImportPlaylistPage> {
  final _link = TextEditingController();
  List<ImportPreview> _sources = const [];
  int _sourceIndex = 0;
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

  void _clearPreview() {
    setState(() {
      _sources = const [];
      _target = null;
    });
  }

  Future<List<Playlist>> _loadTargets() async =>
      (await widget.library.myPlaylists())
          .where(widget.library.canEditPlaylist)
          .toList();

  Future<void> _showSources(List<ImportPreview> sources) async {
    if (!mounted) return;
    final targets = await _loadTargets();
    if (!mounted) return;
    setState(() {
      _sources = sources;
      _sourceIndex = 0;
      _targets = targets;
    });
  }

  Future<void> _load() => _run(() async {
    _clearPreview();
    await _showSources([
      await widget.library.previewPlaylistImport(_link.text),
    ]);
  });

  Future<void> _pickFile() => _run(() async {
    // 不限制扩展名，这样改名或没有扩展名的歌单也能交给解析器识别。
    final file = await FilePicker.pickFile(dialogTitle: '选择歌单文件');
    if (!mounted || file == null) return;
    _clearPreview();
    await _showSources(
      await PlaylistFileImport.read(file.name, file.readAsByteStream()),
    );
  });

  Future<void> _createTarget() => _run(() async {
    if (!await showPlaylistEditor(context, widget.library) || !mounted) return;
    final knownIds = _targets.map((item) => item.id).toSet();
    final targets = await _loadTargets();
    if (!mounted) return;
    final newTargets = targets.where((item) => !knownIds.contains(item.id));
    setState(() {
      _target = newTargets.length == 1
          ? newTargets.single
          : targets.where((item) => item.id == _target?.id).firstOrNull;
      _targets = targets;
    });
  });

  Future<void> _import(ImportPreview source, Playlist target) => _run(() async {
    final result = await widget.library.importPlaylist(
      source,
      target,
      isOpen: () => mounted,
      onProgress: (done, total) {
        if (mounted) setState(() => _progress = '已检查 $done / $total 首');
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
    final preview = _sources.elementAtOrNull(_sourceIndex);
    final target = _target;
    return WorkspacePage(
      title: const Text('导入歌单'),
      body: SafeArea(
        child: ListView(
          padding: DesktopPageScope.bodyPadding(
            context,
            const EdgeInsets.all(20),
          ),
          children: [
            TextField(
              controller: _link,
              enabled: !_busy,
              keyboardType: TextInputType.url,
              textInputAction: TextInputAction.go,
              minLines: 1,
              maxLines: 3,
              decoration: const InputDecoration(labelText: '公开歌单链接或分享文字'),
              onSubmitted: (_) => _load(),
            ),
            const SizedBox(height: 12),
            FilledButton.tonal(
              onPressed: _busy ? null : _load,
              child: const Text('读取链接'),
            ),
            OutlinedButton.icon(
              onPressed: _busy ? null : _pickFile,
              icon: const Icon(Icons.file_open_outlined),
              label: const Text('选择歌单文件'),
            ),
            if (_busy) ...[
              const LinearProgressIndicator(),
              if (_progress != null) Text(_progress!),
            ],
            if (preview != null) ...[
              if (_sources.length > 1)
                DropdownButtonFormField<int>(
                  initialValue: _sourceIndex,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: '从备份中选择歌单'),
                  items: [
                    for (final (index, source) in _sources.indexed)
                      DropdownMenuItem(
                        value: index,
                        child: Text(
                          source.title,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: _busy
                      ? null
                      : (index) {
                          if (index != null) {
                            setState(() => _sourceIndex = index);
                          }
                        },
                ),
              ListTile(
                title: Text(preview.title),
                subtitle: Text(
                  [?preview.format, '${preview.tracks.length} 首'].join(' · '),
                ),
              ),
              if (_targets.isNotEmpty)
                DropdownButton<Playlist>(
                  value: target,
                  isExpanded: true,
                  hint: const Text('选择导入目标'),
                  items: [
                    for (final item in _targets)
                      DropdownMenuItem(
                        value: item,
                        child: Text(item.name, overflow: TextOverflow.ellipsis),
                      ),
                  ],
                  onChanged: _busy
                      ? null
                      : (item) => setState(() => _target = item),
                ),
              TextButton(
                onPressed: _busy ? null : _createTarget,
                child: const Text('新建目标歌单'),
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
                  subtitle: track.artists.isEmpty ? null : Text(track.artists),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

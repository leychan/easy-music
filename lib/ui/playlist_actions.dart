import 'package:material_ui/material_ui.dart';

import '../account/kugou/kugou_auth.dart';
import '../music/music_library.dart';
import '../music/song.dart';
import '../player/playback.dart';
import 'app_dialog.dart';
import 'external_actions.dart';
import 'diffuse_menu.dart';
import 'music_toast.dart';

Future<bool> showPlaylistEditor(
  BuildContext context,
  MusicLibrary library, {
  Playlist? playlist,
}) async {
  final notify = musicNoticeFor(context);
  final draft = await showDialog<({String name, String description})>(
    context: context,
    builder: (_) => _PlaylistEditor(playlist: playlist),
  );
  if (draft == null || !context.mounted) return false;
  try {
    if (playlist == null) {
      await library.createPlaylist(draft.name);
    } else {
      await library.editPlaylist(playlist, draft.name, draft.description);
    }
    notify(playlist == null ? '已创建歌单。' : '已更新歌单。');
    return true;
  } on KugouFailure catch (error) {
    notify(error.message);
  } catch (_) {
    notify('保存歌单失败，请稍后重试。');
  }
  return false;
}

class _PlaylistEditor extends StatefulWidget {
  const _PlaylistEditor({this.playlist});
  final Playlist? playlist;
  @override
  State<_PlaylistEditor> createState() => _PlaylistEditorState();
}

class _PlaylistEditorState extends State<_PlaylistEditor> {
  late final _name = TextEditingController(text: widget.playlist?.name);
  late final _description = TextEditingController(
    text: widget.playlist?.description,
  );

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AppDialog(
    title: Text(widget.playlist == null ? '新建歌单' : '编辑歌单'),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        TextField(
          controller: _name,
          autofocus: true,
          decoration: const InputDecoration(labelText: '名称'),
          onChanged: (_) => setState(() {}),
        ),
        if (widget.playlist != null)
          TextField(
            controller: _description,
            minLines: 2,
            maxLines: 4,
            decoration: const InputDecoration(labelText: '简介'),
          ),
      ],
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: _name.text.trim().isEmpty
            ? null
            : () => Navigator.pop(context, (
                name: _name.text.trim(),
                description: _description.text.trim(),
              )),
        child: const Text('保存'),
      ),
    ],
  );
}

Future<void> sharePlaylist(BuildContext context, Playlist playlist) async {
  final id = playlist.trackCollectionId;
  final link = Uri.https('www.kugou.com', '/yy/special/single/$id.html');
  await _share(musicNoticeFor(context), '${playlist.name}\n$link');
}

bool canSharePlaylist(Playlist playlist) =>
    RegExp(r'^[a-zA-Z0-9_]+$').hasMatch(playlist.trackCollectionId);

Future<void> _share(void Function(String) notify, String text) async {
  try {
    if (await shareText(text)) notify('已复制分享链接。');
  } catch (_) {
    notify('无法分享，请稍后重试。');
  }
}

enum _SongAction { details, queue, favorite, unfavorite, add, remove, share }

class SongMenu extends StatelessWidget {
  const SongMenu({
    super.key,
    required this.song,
    required this.library,
    required this.player,
    required this.onDetails,
    this.playlist,
    this.onChanged,
  });
  final Song song;
  final MusicLibrary library;
  final Playback player;
  final VoidCallback onDetails;
  final Playlist? playlist;
  final VoidCallback? onChanged;

  Future<void> _handle(BuildContext context, _SongAction action) async {
    final notify = musicNoticeFor(context);
    try {
      switch (action) {
        case _SongAction.details:
          onDetails();
        case _SongAction.queue:
          final added = await library.addSongToQueue(song, player);
          notify(added ? '已添加到播放队列。' : '这首歌已在播放队列中。');
        case _SongAction.favorite:
        case _SongAction.unfavorite:
          await library.toggleFavorite(song, favorite: action == _SongAction.favorite);
          if (context.mounted) onChanged?.call();
        case _SongAction.add:
          final lists = (await library.myPlaylists())
              .where(library.canEditPlaylist)
              .toList();
          if (!context.mounted) return;
          if (lists.isEmpty) {
            notify('请先登录并创建歌单。');
            return;
          }
          final target = await showDiffuseMenuSheet<Playlist>(
            context: context,
            builder: (context) => SafeArea(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final item in lists)
                    ListTile(
                      title: Text(item.name),
                      onTap: () => Navigator.pop(context, item),
                    ),
                ],
              ),
            ),
          );
          if (target == null) return;
          await library.addPlaylistSong(target, song);
          notify('已添加到「${target.name}」。');
          if (context.mounted) onChanged?.call();
        case _SongAction.remove:
          await library.removePlaylistSong(playlist!, song);
          notify('已从歌单移除。');
          if (context.mounted) onChanged?.call();
        case _SongAction.share:
          final link = Uri.https(
            'www.kugou.com',
            '/song/',
          ).replace(fragment: 'hash=${song.hash}&album_id=${song.albumId}');
          await _share(notify, '${song.title} · ${song.artist}\n$link');
      }
    } on KugouFailure catch (error) {
      notify(error.message);
    } catch (_) {
      notify('操作失败，请稍后重试。');
    }
  }

  @override
  Widget build(BuildContext context) => DiffuseMenuButton<_SongAction>(
    tooltip: '歌曲操作',
    onSelected: (action) => _handle(context, action),
    itemBuilder: (_) => [
      const DiffuseMenuItem(value: _SongAction.details, child: Text('歌曲详情')),
      const DiffuseMenuItem(value: _SongAction.queue, child: Text('添加到队列')),
      DiffuseMenuItem(
        value: library.isFavorite(song) ? _SongAction.unfavorite : _SongAction.favorite,
        enabled: !library.favoriteBusy(song),
        child: Text(library.isFavorite(song) ? '取消收藏' : '收藏歌曲'),
      ),
      const DiffuseMenuItem(value: _SongAction.add, child: Text('添加到歌单')),
      if (playlist case final list?
          when library.canEditPlaylist(list) && song.fileId > 0)
        const DiffuseMenuItem(value: _SongAction.remove, child: Text('从当前歌单移除')),
      const DiffuseMenuItem(value: _SongAction.share, child: Text('分享歌曲')),
    ],
  );
}

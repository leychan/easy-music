import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';

import '../account/kugou/kugou_auth.dart';
import '../music/catalog.dart';
import '../music/music_library.dart';
import '../music/song.dart';
import '../player/playback.dart';
import 'app_dialog.dart';
import 'catalog_pages.dart';
import 'cover.dart';
import 'discover_page.dart';
import 'music_toast.dart';
import 'now_playing.dart';
import 'player_controls.dart' show runPlayerAction;
import 'song_tile.dart';
import 'workspace_page.dart';

class PersonalMusicPage extends StatefulWidget {
  const PersonalMusicPage({
    super.key,
    required this.library,
    required this.player,
    this.cloud = false,
  });
  final MusicLibrary library;
  final Playback player;
  final bool cloud;

  @override
  State<PersonalMusicPage> createState() => _PersonalMusicPageState();
}

class _PersonalMusicPageState extends State<PersonalMusicPage> {
  bool _albums = false;
  bool _loading = false;
  bool _more = true;
  int _page = 0;
  int _attempt = 0;
  List<Object> _items = const [];
  String? _error;
  String? _pendingSongId;
  bool _uploading = false;
  double? _uploadProgress;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool reset = false}) async {
    if (_loading && !reset) return;
    final attempt = ++_attempt;
    final page = reset ? 1 : _page + 1;
    setState(() {
      if (reset) {
        _items = const [];
        _page = 0;
      }
      _loading = true;
      _error = null;
    });
    try {
      final items = widget.cloud
          ? await widget.library.cloudTracks(page)
          : _albums
          ? await widget.library.purchasedAlbums(page)
          : await widget.library.purchasedSongs(page);
      if (!mounted || attempt != _attempt) return;
      setState(() {
        _items = [..._items, ...items];
        _more = items.length == 30;
        _page = page;
      });
    } on KugouFailure catch (error) {
      if (mounted && attempt == _attempt) {
        setState(() => _error = error.message);
      }
    } catch (_) {
      if (mounted && attempt == _attempt) {
        setState(() => _error = '读取失败，请稍后重试。');
      }
    } finally {
      if (mounted && attempt == _attempt) setState(() => _loading = false);
    }
  }

  Future<void> _play(Object item, String trackId, {bool openPlayer = false}) async {
    if (_pendingSongId != null) return;
    setState(() => _pendingSongId = trackId);
    try {
      await playSongFromList(
        context,
        trackId: trackId,
        player: widget.player,
        library: widget.library,
        play: () async => switch (item) {
          CloudTrack track => widget.library.playCloud(track, widget.player, resumeCurrent: true),
          Song song => widget.library.playSong(song, widget.player, resumeCurrent: true),
          _ => const PlaybackOutcome.unavailable(),
        },
        openPlayer: openPlayer,
      );
    } finally {
      if (mounted) setState(() => _pendingSongId = null);
    }
  }

  // 云盘里同名的文件用云盘队列 ID 匹配，和曲库里的歌曲分开。
  String? _trackId(Object item) => switch (item) {
    CloudTrack track => track.id,
    Song song => song.id,
    _ => null,
  };

  Future<void> _upload() async {
    if (_uploading) return;
    setState(() {
      _uploading = true;
      _uploadProgress = null;
    });
    try {
      final file = await FilePicker.pickFile(
        dialogTitle: '选择上传到酷狗云盘的音频',
        type: FileType.audio,
      );
      if (!mounted || file == null) return;
      await widget.library.uploadCloudFile(file.name, file.readAsByteStream, (
        done,
        total,
      ) {
        if (mounted) setState(() => _uploadProgress = done / total);
      });
      if (!mounted) return;
      showMusicNotice(context, '已上传到音乐云盘。');
      await _load(reset: true);
    } on KugouFailure catch (error) {
      if (mounted) showMusicNotice(context, error.message);
    } catch (_) {
      if (mounted) showMusicNotice(context, '无法上传此音频，请稍后重试。');
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  Future<void> _remove(CloudTrack track) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AppDialog(
        title: const Text('移除云盘文件'),
        content: Text('从酷狗云盘移除「${track.song.title}」？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('移除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await widget.library.deleteCloudTrack(track);
      if (mounted) await _load(reset: true);
    } on KugouFailure catch (error) {
      if (mounted) showMusicNotice(context, error.message);
    } catch (_) {
      if (mounted) showMusicNotice(context, '无法移除云盘文件。');
    }
  }

  @override
  Widget build(BuildContext context) => StreamBuilder<TrackPlayback>(
    stream: widget.player.trackPlaybackStream,
    initialData: widget.player.trackPlayback,
    builder: (context, snapshot) => _buildPage(context, snapshot.requireData),
  );

  Widget _buildPage(BuildContext context, TrackPlayback playback) => WorkspacePage(
    title: Text(widget.cloud ? '音乐云盘' : '已购音乐'),
    actions: [
      if (widget.cloud)
        IconButton(
          tooltip: '上传本地音频',
          icon: const Icon(Icons.cloud_upload_outlined),
          onPressed: _uploading ? null : _upload,
        ),
    ],
    body: SafeArea(
      child: Column(
        children: [
          if (_uploading) LinearProgressIndicator(value: _uploadProgress),
          if (!widget.cloud)
            Wrap(
              spacing: 8,
              children: [
                for (final (albums, label) in [(false, '单曲'), (true, '专辑')])
                  ChoiceChip(
                    label: Text(label),
                    selected: _albums == albums,
                    onSelected: (selected) {
                      if (!selected || albums == _albums) return;
                      _albums = albums;
                      _load(reset: true);
                    },
                  ),
              ],
            ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: () => _load(reset: true),
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                children: [
                  for (final item in _items)
                    if (item is CatalogHit)
                      ListTile(
                        title: Text(item.title),
                        subtitle: Text(item.subtitle),
                        leading: Cover(
                          url: item.cover.replaceAll('{size}', '150'),
                          size: 44,
                        ),
                        onTap: () => Navigator.of(context).push<void>(
                          MaterialPageRoute(
                            builder: (_) => SongListPage(
                              title: item.title,
                              subtitle: item.subtitle,
                              cover: item.cover,
                              loader: () => widget.library.albumTracks(
                                item.id,
                                purchased: true,
                              ),
                              player: widget.player,
                              library: widget.library,
                            ),
                          ),
                        ),
                      )
                    else if (_trackId(item) case final trackId?)
                      SongTile(
                        song: item is CloudTrack ? item.song : item as Song,
                        selected: trackId == playback.trackId,
                        loading: _pendingSongId == trackId,
                        onTap: () => _play(item, trackId, openPlayer: true),
                        onPlay: () => _play(item, trackId),
                        onPause: playback.playing && trackId == playback.trackId
                            ? () => runPlayerAction(context, () => widget.player.pauseTrack(trackId))
                            : null,
                        trailing: item is CloudTrack && item.fileId != null
                            ? IconButton(
                                tooltip: '移除云盘文件',
                                icon: const Icon(Icons.delete_outline_rounded),
                                onPressed: () => _remove(item),
                              )
                            : null,
                        onLongPress: item is Song
                            ? () => openCatalogHit(
                                context,
                                CatalogHit.track(item),
                                SearchType.song,
                                widget.library,
                                widget.player,
                              )
                            : null,
                      ),
                  if (_loading)
                    const Center(
                      child: Padding(
                        padding: EdgeInsets.all(20),
                        child: CircularProgressIndicator(),
                      ),
                    )
                  else if (_error case final error?)
                    ListTile(
                      title: Text(error),
                      trailing: TextButton(
                        onPressed: _load,
                        child: const Text('重试'),
                      ),
                    )
                  else if (_items.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(20),
                      child: Center(child: Text('这里还没有音乐。')),
                    )
                  else if (_more)
                    TextButton(onPressed: _load, child: const Text('加载更多')),
                ],
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

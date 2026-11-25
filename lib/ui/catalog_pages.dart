import 'package:material_ui/material_ui.dart';

import '../account/kugou/kugou_auth.dart';
import '../music/catalog.dart';
import '../music/music_library.dart';
import '../music/song.dart';
import '../player/playback.dart';
import 'cover.dart';
import 'discover_page.dart';
import 'music_toast.dart';
import 'mv_player_page.dart';
import 'workspace_page.dart';

Future<void> openCatalogHit(
  BuildContext context,
  CatalogHit hit,
  SearchType type,
  MusicLibrary library,
  Playback player,
) => Navigator.of(context).push<void>(
  MaterialPageRoute(
    builder: (context) => switch (type) {
      SearchType.album => SongListPage(
        title: hit.title,
        subtitle: hit.subtitle,
        cover: hit.cover,
        description: hit.description,
        loader: () => library.albumTracks(hit.id),
        library: library,
        player: player,
      ),
      SearchType.artist => SongListPage(
        title: hit.title,
        subtitle: hit.subtitle,
        cover: hit.cover,
        loader: () => library.artistTracks(hit.id),
        library: library,
        player: player,
      ),
      SearchType.playlist when hit.playlist != null => SongListPage(
        title: hit.title,
        subtitle: hit.subtitle,
        cover: hit.cover,
        description: hit.description,
        loader: () => library.playlistSongs(hit.playlist!),
        library: library,
        player: player,
        playlist: hit.playlist,
      ),
      SearchType.video => MvPlayerPage(hit: hit, library: library, player: player),
      _ => _CatalogDetail(hit: hit, library: library, player: player),
    },
  ),
);

class _CatalogDetail extends StatefulWidget {
  const _CatalogDetail({
    required this.hit,
    required this.library,
    required this.player,
  });

  final CatalogHit hit;
  final MusicLibrary library;
  final Playback player;

  @override
  State<_CatalogDetail> createState() => _CatalogDetailState();
}

class _CatalogDetailState extends State<_CatalogDetail> {
  bool _busy = false;

  Future<void> _play(Song song) async {
    setState(() => _busy = true);
    try {
      final outcome = await widget.library.playSong(song, widget.player);
      if (outcome.notice case final notice?) _notice(notice);
    } on KugouFailure catch (error) {
      _notice(error.message);
    } catch (_) {
      _notice('无法打开该内容，请稍后重试。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _notice(String message) {
    if (mounted) showMusicNotice(context, message);
  }

  @override
  Widget build(BuildContext context) {
    final hit = widget.hit;
    final song = hit.song;
    return WorkspacePage(
      title: Text(song == null ? '详情' : '歌曲详情'),
      body: SafeArea(
        child: ListView(
          padding: DesktopPageScope.bodyPadding(context, const EdgeInsets.all(24)),
          children: [
            Center(
              child: Cover(
                url: hit.cover.replaceAll('{size}', '400'),
                size: 176,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              hit.title,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleLarge,
            ),
            if (hit.subtitle.isNotEmpty)
              Text(hit.subtitle, textAlign: TextAlign.center),
            if (song != null && song.albumName.isNotEmpty)
              Text(song.albumName, textAlign: TextAlign.center),
            if (song != null) ...[
              const SizedBox(height: 16),
              Center(
                child: FilledButton.icon(
                  onPressed: _busy ? null : () => _play(song),
                  icon: const Icon(Icons.play_arrow_rounded),
                  label: Text(_busy ? '加载中…' : '播放歌曲'),
                ),
              ),
            ],
            if (hit.description.isNotEmpty) ...[
              const SizedBox(height: 20),
              SelectableText(hit.description),
            ],
          ],
        ),
      ),
    );
  }
}

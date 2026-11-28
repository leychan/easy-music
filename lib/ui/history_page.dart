import 'package:material_ui/material_ui.dart';

import '../music/music_library.dart';
import '../player/playback.dart';
import '../player/track.dart';
import 'cover.dart';
import 'music_toast.dart';
import 'now_playing.dart';
import 'workspace_page.dart';

class HistoryPage extends StatefulWidget {
  const HistoryPage({super.key, required this.player, required this.library});

  final Playback player;
  final MusicLibrary library;

  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  String? _pendingId;

  Future<void> _replay(Track track) async {
    if (_pendingId != null) return;
    setState(() => _pendingId = track.id);
    try {
      await playSongFromList(
        context,
        trackId: track.id,
        player: widget.player,
        library: widget.library,
        play: () => widget.library.replay(track, widget.player),
      );
    } finally {
      if (mounted) setState(() => _pendingId = null);
    }
  }

  Future<void> _remove(Track track) async {
    try {
      await widget.player.removeHistoryEntry(track.id);
    } catch (_) {
      if (mounted) showMusicNotice(context, '无法删除这条播放记录，请重试。');
    }
  }

  @override
  Widget build(BuildContext context) {
    final localizations = MaterialLocalizations.of(context);
    return WorkspacePage(
      title: const Text('最近播放'),
      actions: [
        IconButton(
          tooltip: '听歌统计',
          icon: const Icon(Icons.bar_chart_rounded),
          onPressed: () => Navigator.of(context).push<void>(MaterialPageRoute(
            builder: (_) => _ListeningStats(player: widget.player),
          )),
        ),
      ],
      body: SafeArea(
        child: ValueListenableBuilder(
          valueListenable: widget.player.history,
          builder: (context, entries, _) {
            if (entries.isEmpty) {
              return const Center(child: Text('还没有播放记录。'));
            }
            return ListView.builder(
              padding: DesktopPageScope.bodyPadding(context, const EdgeInsets.fromLTRB(12, 4, 12, 16)),
              itemCount: entries.length,
              itemBuilder: (context, index) {
                final entry = entries[index];
                final track = entry.track;
                final playing = track.id == _pendingId;
                final date = localizations.formatShortDate(entry.playedAt);
                final time = localizations.formatTimeOfDay(
                  TimeOfDay.fromDateTime(entry.playedAt),
                  alwaysUse24HourFormat: true,
                );
                final artist = track.artist.isNotEmpty
                    ? track.artist
                    : (track.isLocal ? '本地文件' : '在线音乐');
                return ListTile(
                  key: ValueKey(track.id),
                  leading: Cover(url: track.artUri?.toString() ?? '', size: 44),
                  title: Text(
                    track.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    '$artist · $date $time',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  onTap: _pendingId == null ? () => _replay(track) : null,
                  trailing: playing
                      ? const SizedBox.square(
                          dimension: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : IconButton(
                          tooltip: '从最近播放移除',
                          icon: const Icon(Icons.close_rounded),
                          onPressed: () => _remove(track),
                        ),
                );
              },
            );
          },
        ),
      ),
    );
  }
}

class _ListeningStats extends StatelessWidget {
  const _ListeningStats({required this.player});
  final Playback player;

  @override
  Widget build(BuildContext context) => WorkspacePage(
    title: const Text('听歌统计'),
    body: SafeArea(
      child: ValueListenableBuilder(
        valueListenable: player.history,
        builder: (context, _, _) {
          final stats = player.listeningStats;
          return ListView(
            padding: DesktopPageScope.bodyPadding(context, const EdgeInsets.all(16)),
            children: [
              ListTile(
                leading: const Icon(Icons.headphones_rounded),
                title: Text('共播放 ${stats.plays} 次'),
                subtitle: Text('听过 ${stats.songs} 首歌'),
              ),
              if (stats.top.isNotEmpty) ...[
                const Divider(),
                const ListTile(title: Text('播放最多')),
                for (final (index, track) in stats.top.indexed)
                  ListTile(
                    leading: Text('${index + 1}'),
                    title: Text(track.title),
                    subtitle: track.artist.isNotEmpty ? Text(track.artist) : null,
                    trailing: Text('${track.count} 次'),
                  ),
              ],
            ],
          );
        },
      ),
    ),
  );
}

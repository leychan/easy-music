import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../account/kugou/kugou_auth.dart';
import '../music/music_library.dart';
import '../music/song.dart';
import '../player/track.dart';
import 'music_toast.dart';

/// 收藏状态由音乐库维护，任何一个红心的操作都会刷新其他入口。
class FavoriteButton extends StatefulWidget {
  const FavoriteButton({
    super.key,
    required this.library,
    required this.song,
    this.compact = false,
    this.onChanged,
  });

  factory FavoriteButton.track({required MusicLibrary library, required Track? track}) =>
      FavoriteButton(library: library, song: Song.fromTrack(track));

  final MusicLibrary library;
  final Song? song;
  final bool compact;
  final VoidCallback? onChanged;

  @override
  State<FavoriteButton> createState() => _FavoriteButtonState();
}

class _FavoriteButtonState extends State<FavoriteButton> {
  @override
  void initState() {
    super.initState();
    if (widget.song != null) unawaited(widget.library.loadFavorites());
  }

  @override
  void didUpdateWidget(covariant FavoriteButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.song != null && (oldWidget.song == null || oldWidget.library != widget.library)) {
      unawaited(widget.library.loadFavorites());
    }
  }

  Future<void> _toggle(Song song, bool liked) async {
    try {
      await widget.library.toggleFavorite(song, favorite: !liked);
      if (!mounted) return;
      widget.onChanged?.call();
    } on KugouFailure catch (error) {
      if (mounted) showMusicNotice(context, error.message);
    } catch (_) {
      if (mounted) showMusicNotice(context, '收藏操作失败，请稍后重试。');
    }
  }

  @override
  Widget build(BuildContext context) {
    final song = widget.song;
    if (song == null || song.hash.isEmpty) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: widget.library,
      builder: (context, _) {
        final liked = widget.library.isFavorite(song);
        final busy = widget.library.favoriteBusy(song);
        return IconButton(
          tooltip: liked ? '取消收藏' : '收藏歌曲',
          isSelected: liked,
          style: widget.compact ? IconButton.styleFrom(
            minimumSize: const Size.square(34),
            padding: const EdgeInsets.all(8),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ) : null,
          onPressed: busy ? null : () => _toggle(song, liked),
          icon: busy ? const SizedBox.square(
            dimension: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          ) : Icon(
            liked ? Icons.favorite_rounded : Icons.favorite_border_rounded,
            size: 20,
            color: liked ? Theme.of(context).colorScheme.primary : null,
          ),
        );
      },
    );
  }
}

import 'dart:async';
import 'dart:math' as math;

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:material_ui/material_ui.dart';

import '../player/lyrics.dart';
import '../player/playback.dart';

class SyncedLyrics extends StatefulWidget {
  const SyncedLyrics({
    super.key,
    required this.player,
    required this.lines,
    this.textAlign = TextAlign.center,
    this.stage = false,
  });
  final Playback player;
  final List<LyricLine> lines;
  final TextAlign textAlign;
  final bool stage;

  @override
  State<SyncedLyrics> createState() => _SyncedLyricsState();
}

class _SyncedLyricsState extends State<SyncedLyrics>
    with SingleTickerProviderStateMixin {
  final _scroll = ScrollController(keepScrollOffset: false);
  final _viewportKey = GlobalKey();
  final _rowKeys = <int, GlobalKey>{};
  late final _position = ValueNotifier(widget.player.position);
  late final Ticker _ticker = createTicker((_) {
    _updatePosition(widget.player.position);
  });
  late StreamSubscription<Duration> _positions;
  late StreamSubscription<PlaybackState> _playbackStates;
  late int _active;
  double _initialScrollOffset = 0;
  bool _reduceMotion = false;

  CrossAxisAlignment get _alignment => widget.textAlign == TextAlign.start
      ? CrossAxisAlignment.start
      : CrossAxisAlignment.center;

  @override
  void initState() {
    super.initState();
    _active = activeLyricIndex(widget.lines, _position.value);
    _listenToPlayer();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = MediaQuery.disableAnimationsOf(context);
    _updateTicker();
  }

  @override
  void didUpdateWidget(covariant SyncedLyrics oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.lines != widget.lines || oldWidget.player != widget.player) {
      _rowKeys.clear();
      _initialScrollOffset = 0;
    }
    if (oldWidget.player != widget.player) {
      unawaited(_positions.cancel());
      unawaited(_playbackStates.cancel());
      _position.value = widget.player.position;
      _listenToPlayer();
    }
    _active = activeLyricIndex(widget.lines, _position.value);
    _updateTicker();
  }

  void _listenToPlayer() {
    _positions = widget.player.positionStream.listen(_updatePosition);
    _playbackStates = widget.player.playbackState.listen((_) {
      _updatePosition(widget.player.position);
    });
  }

  void _updatePosition(Duration position) {
    final active = activeLyricIndex(widget.lines, position);
    if (active != _active) _followLine(active);
    _position.value = position;
    _updateTicker();
  }

  void _followLine(int active) {
    final offset = _transitionOffset(active);
    setState(() {
      _active = active;
      _initialScrollOffset = offset;
    });
    if (offset == 0) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          _active != active ||
          !_scroll.hasClients ||
          _initialScrollOffset != offset) {
        return;
      }
      final remaining = _offsetFromCenter(active);
      if (remaining == null) return;
      final position = _scroll.position;
      // 中心 sliver 已经修正过滚动偏移，用实际行的位置求最终停点。
      final target = (position.pixels - remaining).clamp(
        position.minScrollExtent,
        position.maxScrollExtent,
      );
      if (_reduceMotion) {
        position.jumpTo(target);
      } else {
        unawaited(position.animateTo(
          target,
          duration: const Duration(milliseconds: 360),
          curve: Curves.easeOutCubic,
        ));
      }
    });
  }

  // 矮屏里下一句可能在视口外，从边缘滑入。远距离跳转直接定位。
  double _transitionOffset(int active) {
    if (!widget.stage || _reduceMotion || active < 0 || !_scroll.hasClients) {
      return 0;
    }
    final position = _scroll.position;
    if (!position.hasViewportDimension) return 0;
    final halfViewport = position.viewportDimension / 2;
    final offset = _offsetFromCenter(active);
    if (offset != null && offset.abs() <= halfViewport) return offset;
    if (_active < 0 || (active - _active).abs() != 1) return 0;
    return active > _active ? -halfViewport : halfViewport;
  }

  double? _offsetFromCenter(int active) {
    final row = _rowKeys[active]?.currentContext?.findRenderObject();
    final viewport = _viewportKey.currentContext?.findRenderObject();
    if (row is! RenderBox ||
        !row.attached ||
        !row.hasSize ||
        viewport is! RenderBox ||
        !viewport.attached ||
        !viewport.hasSize) {
      return null;
    }
    final middle = viewport.size.height / 2;
    final rowCenter = row
        .localToGlobal(row.size.center(Offset.zero), ancestor: viewport)
        .dy;
    return middle - rowCenter;
  }

  // 引擎能按倍速插值播放位置；逐帧只重绘当前句，暂停或缓冲时停止刷新。
  void _updateTicker() {
    final state = widget.player.playbackState.value;
    final shouldTick =
        !_reduceMotion &&
        state.playing &&
        state.processingState == AudioProcessingState.ready &&
        _active >= 0 &&
        widget.lines[_active].words.isNotEmpty;
    if (shouldTick && !_ticker.isActive) _ticker.start();
    if (!shouldTick && _ticker.isActive) _ticker.stop();
  }

  @override
  void dispose() {
    unawaited(_positions.cancel());
    unawaited(_playbackStates.cancel());
    _ticker.dispose();
    _position.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final lines = widget.lines;
    if (lines.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            '还没有歌词',
            style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
      );
    }
    const current = ValueKey('current-lyrics');
    final start = math.max(_active, 0);
    final viewport = LayoutBuilder(
      key: _viewportKey,
      builder: (context, constraints) => CustomScrollView(
        key: ValueKey(_active),
        controller: _scroll,
        center: current,
        anchor: 0.5,
        primary: false,
        slivers: [
          SliverList.builder(
            itemCount: start,
            itemBuilder: (context, index) =>
                _lyricRow(theme, start - index - 1, false),
          ),
          _CenteredLyricSliver(
            key: current,
            initialScrollOffset: _initialScrollOffset,
            child: _lyricRow(theme, start, _active >= 0),
          ),
          SliverList.builder(
            itemCount: lines.length - start - 1,
            itemBuilder: (context, index) =>
                _lyricRow(theme, start + index + 1, false),
          ),
          // 让最后一句也有足够空间停在视口中间。
          SliverToBoxAdapter(
            child: SizedBox(height: constraints.maxHeight / 2),
          ),
        ],
      ),
    );
    if (!widget.stage) return viewport;
    // 上下沿淡出，歌词滑入和滑出时不会在视口边缘突然断开。
    return ShaderMask(
      blendMode: BlendMode.dstIn,
      shaderCallback: (bounds) {
        final fade = math.min(16 / bounds.height, 0.16);
        return LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: const [
            Colors.transparent,
            Colors.white,
            Colors.white,
            Colors.transparent,
          ],
          stops: [0, fade, 1 - fade, 1],
        ).createShader(bounds);
      },
      child: viewport,
    );
  }

  Widget _lyricRow(
    ThemeData theme,
    int index,
    bool active,
  ) {
    final line = widget.lines[index];
    final stage = widget.stage;
    final colors = theme.colorScheme;
    final muted = colors.onSurfaceVariant;
    final highlight = stage ? colors.onSurface : colors.primary;
    final activeStyle = stage
        ? theme.textTheme.headlineMedium
        : theme.textTheme.titleLarge;
    // 缩小未唱到的歌词，让当前句更容易定位。
    final inactiveStyle = stage
        ? theme.textTheme.titleLarge
        : theme.textTheme.bodyLarge;
    final style = ((active ? activeStyle : inactiveStyle) ?? const TextStyle())
        .copyWith(
          color: active && line.words.isEmpty ? highlight : muted,
          fontWeight: stage
              ? FontWeight.w800
              : (active ? FontWeight.w800 : FontWeight.w600),
          height: stage ? 1.18 : null,
        );
    final label = Padding(
      padding: EdgeInsets.symmetric(vertical: stage ? 13 : 7),
      child: Column(
        crossAxisAlignment: _alignment,
        children: [
          if (active && line.words.isNotEmpty && line.text.isNotEmpty)
            _KaraokeLine(
              line: line,
              style: style,
              highlight: highlight,
              textAlign: widget.textAlign,
              position: _position,
            )
          else
            Text(
              line.text.isEmpty ? '♪' : line.text,
              style: style,
              textAlign: widget.textAlign,
            ),
          if (line.translation.isNotEmpty)
            Text(
              line.translation,
              textAlign: widget.textAlign,
              style: TextStyle(color: muted),
            ),
        ],
      ),
    );
    if (!stage) return label;
    final key = _rowKeys.putIfAbsent(index, GlobalKey.new);
    return SizedBox(
      key: key,
      width: double.infinity,
      child: label,
    );
  }
}

class _CenteredLyricSliver extends SliverToBoxAdapter {
  const _CenteredLyricSliver({
    required super.key,
    required super.child,
    required this.initialScrollOffset,
  });

  final double initialScrollOffset;

  @override
  RenderSliverToBoxAdapter createRenderObject(BuildContext context) =>
      _RenderCenteredLyricSliver(initialScrollOffset);
}

class _RenderCenteredLyricSliver extends RenderSliverToBoxAdapter {
  _RenderCenteredLyricSliver(double initialScrollOffset)
    : _appliedCorrection = -initialScrollOffset;

  double _appliedCorrection;

  @override
  void performLayout() {
    super.performLayout();
    // 锚点本来对齐行顶，用实际行高的一半做修正，换行时也能居中。
    final halfExtent = geometry!.scrollExtent / 2;
    final correction = halfExtent - _appliedCorrection;
    if (correction == 0) return;
    _appliedCorrection = halfExtent;
    geometry = SliverGeometry(scrollOffsetCorrection: correction);
  }
}

class _KaraokeLine extends StatefulWidget {
  const _KaraokeLine({
    required this.line,
    required this.style,
    required this.highlight,
    required this.textAlign,
    required this.position,
  });

  final LyricLine line;
  final TextStyle style;
  final Color highlight;
  final TextAlign textAlign;
  final ValueListenable<Duration> position;

  @override
  State<_KaraokeLine> createState() => _KaraokeLineState();
}

class _KaraokeLineState extends State<_KaraokeLine> {
  _KaraokeHighlight? _painter;

  @override
  Widget build(BuildContext context) {
    final defaults = DefaultTextStyle.of(context);
    final baseStyle = defaults.style.merge(widget.style);
    final style = MediaQuery.boldTextOf(context)
        ? baseStyle.copyWith(fontWeight: FontWeight.bold)
        : baseStyle;
    final text = widget.line.text;
    _painter?.dispose();
    _painter = _KaraokeHighlight(
      widget.line.words,
      widget.position,
      TextPainter(
        text: TextSpan(
          text: text,
          style: style.copyWith(color: widget.highlight),
        ),
        textAlign: widget.textAlign,
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
        locale: Localizations.maybeLocaleOf(context),
        textWidthBasis: defaults.textWidthBasis,
        textHeightBehavior:
            defaults.textHeightBehavior ??
            DefaultTextHeightBehavior.maybeOf(context),
      ),
    );
    return RepaintBoundary(
      child: CustomPaint(
        foregroundPainter: _painter,
        child: Text(text, textAlign: widget.textAlign, style: widget.style),
      ),
    );
  }

  @override
  void dispose() {
    _painter?.dispose();
    super.dispose();
  }
}

class _KaraokeHighlight extends CustomPainter {
  _KaraokeHighlight(this.words, this.position, this.text)
    : super(repaint: position);

  final List<LyricWord> words;
  final ValueListenable<Duration> position;
  final TextPainter text;
  double? _layoutWidth;
  late List<List<TextBox>> _boxes;

  void _layout(double width) {
    text.layout(minWidth: width, maxWidth: width);
    // 用排版引擎给出的字形位置，保证连续高亮也能跟随自动换行。
    var start = 0;
    _boxes = words.map((word) {
      final end = start + word.text.length;
      final boxes = text.getBoxesForSelection(
        TextSelection(baseOffset: start, extentOffset: end),
      );
      start = end;
      return boxes;
    }).toList();
    _layoutWidth = width;
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (_layoutWidth != size.width) _layout(size.width);
    final clip = Path();
    for (final (index, word) in words.indexed) {
      final elapsed = (position.value - word.start).inMicroseconds;
      if (elapsed <= 0) continue;
      final next = words.elementAtOrNull(index + 1);
      final interval = next == null ? Duration.zero : next.start - word.start;
      final duration = word.duration > Duration.zero
          ? word.duration
          : (interval > Duration.zero
                ? interval
                : const Duration(milliseconds: 200));
      final boxes = _boxes[index];
      final width = boxes.fold(
        0.0,
        (value, box) => value + box.right - box.left,
      );
      var remaining =
          width * (elapsed / duration.inMicroseconds).clamp(0.0, 1.0);
      for (final box in boxes) {
        if (remaining <= 0) break;
        final filled = math.min(remaining, box.right - box.left);
        final left = box.direction == TextDirection.rtl
            ? box.right - filled
            : box.left;
        clip.addRect(Rect.fromLTRB(left, box.top, left + filled, box.bottom));
        remaining -= filled;
      }
    }
    canvas.save();
    canvas.clipPath(clip);
    text.paint(canvas, Offset.zero);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _KaraokeHighlight oldDelegate) => true;

  void dispose() => text.dispose();
}

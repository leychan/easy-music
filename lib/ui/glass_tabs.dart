import 'package:material_ui/material_ui.dart';

import 'glass_surface.dart';

const double _minimumBarHeight = 52;
const double _highlightInset = 3;
const double _labelLineHeight = 1.2;

/// 底部标签栏的玻璃底座，按钮继续由 NavigationBar 处理点击和无障碍语义。
class GlassNavigationBar extends StatelessWidget {
  const GlassNavigationBar({
    super.key,
    required this.selectedIndex,
    required this.onDestinationSelected,
    required this.destinations,
  });

  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;
  final List<NavigationDestination> destinations;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final labelStyle = theme.textTheme.labelMedium?.copyWith(
      height: _labelLineHeight,
    );
    final labelSize = labelStyle?.fontSize ?? 12;
    // 给放大的标签预留额外空间，缩放上限与 NavigationBar 的标签一致。
    final scaledLabelSize = MediaQuery.textScalerOf(context)
        .clamp(minScaleFactor: 1, maxScaleFactor: 1.3)
        .scale(labelSize);
    final barHeight =
        _minimumBarHeight +
        ((scaledLabelSize - labelSize) * _labelLineHeight).ceil();
    // 圆角半径取高度的一半，让底座和高光都保持完整的半圆端头。
    final radius = BorderRadius.circular(barHeight / 2);
    return Center(
      heightFactor: 1,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: glassBarMaxWidth),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 6),
          child: GlassSurface(
            radius: radius,
            child: Stack(
              alignment: Alignment.center,
              children: [
                Positioned.fill(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      vertical: _highlightInset,
                    ),
                    child: _SlidingGlassHighlight(
                      duration: _selectionDuration(context),
                      index: selectedIndex,
                      count: destinations.length,
                      radius: BorderRadius.circular(
                        barHeight / 2 - _highlightInset,
                      ),
                    ),
                  ),
                ),
                NavigationBarTheme(
                  data: NavigationBarThemeData(
                    iconTheme: WidgetStateProperty.resolveWith(
                      (states) => IconThemeData(
                        size: 22,
                        color: states.contains(WidgetState.selected)
                            ? colors.onPrimaryContainer
                            : colors.onSurfaceVariant,
                      ),
                    ),
                    labelTextStyle: WidgetStateProperty.resolveWith((states) {
                      final selected = states.contains(WidgetState.selected);
                      return labelStyle?.copyWith(
                        color: selected
                            ? colors.onPrimaryContainer
                            : colors.onSurfaceVariant,
                        fontWeight: selected
                            ? FontWeight.w700
                            : FontWeight.w500,
                      );
                    }),
                  ),
                  child: Theme(
                    // 关闭图标区域的点击水波纹，保留整项的玻璃滑动高光。
                    data: theme.copyWith(splashFactory: NoSplash.splashFactory),
                    child: NavigationBar(
                      height: barHeight,
                      // 居中布局下，补 4 个逻辑像素的底部留白会将标签上移 2 个像素。
                      labelPadding: const EdgeInsets.only(bottom: 4),
                      backgroundColor: Colors.transparent,
                      surfaceTintColor: Colors.transparent,
                      indicatorColor: Colors.transparent,
                      elevation: 0,
                      animationDuration: _selectionDuration(context),
                      selectedIndex: selectedIndex,
                      onDestinationSelected: onDestinationSelected,
                      destinations: destinations,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 透镜沿着标签滑动时略微拉长，到达后恢复圆润的轮廓。
class _SlidingGlassHighlight extends ImplicitlyAnimatedWidget {
  const _SlidingGlassHighlight({
    required this.index,
    required this.count,
    required this.radius,
    required super.duration,
  }) : super(curve: Curves.easeOutCubic);

  final int index;
  final int count;
  final BorderRadius radius;

  @override
  AnimatedWidgetBaseState<_SlidingGlassHighlight> createState() =>
      _SlidingGlassHighlightState();
}

class _SlidingGlassHighlightState
    extends AnimatedWidgetBaseState<_SlidingGlassHighlight> {
  Tween<double>? _index;

  @override
  void forEachTween(TweenVisitor<dynamic> visitor) {
    _index = visitor(
      _index,
      widget.index.toDouble(),
      (value) => Tween<double>(begin: value as double),
    ) as Tween<double>?;
  }

  @override
  Widget build(BuildContext context) {
    final phase = animation.value;
    final stretch = 4 * phase * (1 - phase);
    final index = _index!.evaluate(animation);
    return Align(
      alignment: AlignmentDirectional(2 * index / (widget.count - 1) - 1, 0),
      child: FractionallySizedBox(
        widthFactor: 1 / widget.count,
        heightFactor: 1,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 5),
          child: Transform.scale(
            scaleX: 1 + 0.12 * stretch,
            scaleY: 1 - 0.06 * stretch,
            child: _GlassHighlight(radius: widget.radius),
          ),
        ),
      ),
    );
  }
}

/// 侧栏与横栏共用选中高光，内容层继续提供原来的按压和键盘交互。
class GlassTabSelection extends StatelessWidget {
  const GlassTabSelection({
    super.key,
    required this.selected,
    required this.radius,
    required this.child,
    this.backgroundColor = Colors.transparent,
  });

  final bool selected;
  final BorderRadius radius;
  final Widget child;
  final Color backgroundColor;

  @override
  Widget build(BuildContext context) => Semantics(
    selected: selected,
    child: DecoratedBox(
      decoration: BoxDecoration(color: backgroundColor, borderRadius: radius),
      child: Stack(
        fit: StackFit.passthrough,
        children: [
          Positioned.fill(
            child: AnimatedOpacity(
              opacity: selected ? 1 : 0,
              duration: _selectionDuration(context),
              curve: Curves.easeOutCubic,
              child: _GlassHighlight(radius: radius),
            ),
          ),
          child,
        ],
      ),
    ),
  );
}

Duration _selectionDuration(BuildContext context) =>
    MediaQuery.disableAnimationsOf(context)
    ? Duration.zero
    : const Duration(milliseconds: 320);

/// 斜向亮面带出折光感，底边用更深的主题色勾出玻璃边缘。
class _GlassHighlight extends StatelessWidget {
  const _GlassHighlight({required this.radius});

  final BorderRadius radius;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final light = colors.brightness == Brightness.light;
    final tint = Color.lerp(colors.primaryContainer, colors.primary, 0.23)!;
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: radius,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          stops: const [0, 0.43, 0.78, 1],
          colors: [
            Color.lerp(tint, Colors.white, light ? 0.76 : 0.30)!,
            tint.withValues(alpha: 0.65),
            colors.primaryContainer.withValues(alpha: 0.84),
            tint,
          ],
        ),
        border: Border.all(
          color: Colors.white.withValues(alpha: light ? 0.70 : 0.30),
        ),
        boxShadow: [
          BoxShadow(
            color: colors.primary.withValues(alpha: light ? 0.24 : 0.20),
            blurRadius: 7,
            offset: const Offset(0, 2),
          ),
        ],
      ),
    );
  }
}

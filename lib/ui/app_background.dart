import 'package:material_ui/material_ui.dart';

enum BackgroundStyle { diffuse, solid }

/// 让页面、嵌套导航和弹层都能读取同一个外观设置。
class BackgroundStyleScope extends InheritedWidget {
  const BackgroundStyleScope({
    super.key,
    required this.style,
    required super.child,
  });

  final BackgroundStyle style;

  static BackgroundStyle of(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<BackgroundStyleScope>()
          ?.style ??
      BackgroundStyle.diffuse;

  @override
  bool updateShouldNotify(BackgroundStyleScope oldWidget) =>
      style != oldWidget.style;
}

/// 页面和弹出菜单共用背景，切换样式时保留下面的页面和滚动状态。
class AppBackground extends StatelessWidget {
  const AppBackground({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => CustomPaint(
    painter: _AppBackgroundPainter(
      Theme.of(context).colorScheme,
      BackgroundStyleScope.of(context),
    ),
    child: child,
  );
}

class _AppBackgroundPainter extends CustomPainter {
  const _AppBackgroundPainter(this.colors, this.style);

  final ColorScheme colors;
  final BackgroundStyle style;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final light = colors.brightness == Brightness.light;
    final diffuse = style == BackgroundStyle.diffuse;
    // 夜间弥散用接近黑色的底色，保留低亮度的色斑和过渡。
    final base = !light && diffuse
        ? Color.alphaBlend(const Color(0x4D000000), colors.surface)
        : colors.surface;
    canvas.drawRect(Offset.zero & size, Paint()..color = base);
    if (!diffuse) return;

    final glowStrength = light ? 1.0 : 0.45;
    // 按容器宽高拉伸色斑，窄菜单和宽屏页面都能看到完整渐变。
    canvas.save();
    canvas.scale(size.width, size.height);
    _paintGlow(
      canvas,
      const Alignment(-0.95, -0.98),
      0.86,
      light ? const Color(0xFFFFD4BE) : const Color(0xFF563C67),
      0.70 * glowStrength,
    );
    _paintGlow(
      canvas,
      const Alignment(1.05, -0.28),
      0.77,
      colors.primaryContainer,
      (light ? 0.78 : 0.82) * glowStrength,
    );
    _paintGlow(
      canvas,
      const Alignment(-0.43, 1.03),
      0.88,
      light ? const Color(0xFFE2DDFC) : const Color(0xFF313C61),
      0.78 * glowStrength,
    );
    canvas.restore();
  }

  void _paintGlow(
    Canvas canvas,
    Alignment center,
    double radius,
    Color color,
    double strength,
  ) {
    const bounds = Rect.fromLTWH(0, 0, 1, 1);
    final gradient = RadialGradient(
      center: center,
      radius: radius,
      colors: [
        color.withValues(alpha: strength),
        color.withValues(alpha: strength * 0.65),
        color.withValues(alpha: strength * 0.18),
        color.withValues(alpha: 0),
      ],
      stops: const [0, 0.34, 0.70, 1],
    );
    canvas.drawRect(bounds, Paint()..shader = gradient.createShader(bounds));
  }

  @override
  bool shouldRepaint(_AppBackgroundPainter oldDelegate) =>
      style != oldDelegate.style ||
      colors.brightness != oldDelegate.colors.brightness ||
      colors.surface != oldDelegate.colors.surface ||
      colors.primaryContainer != oldDelegate.colors.primaryContainer;
}

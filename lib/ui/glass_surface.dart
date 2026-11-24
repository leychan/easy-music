import 'dart:ui' show ImageFilter;

import 'package:material_ui/material_ui.dart';

const double glassBarMaxWidth = 520;

/// 播放条和标签栏共用半透明底座，圆角内才绘制磨砂和高光。
class GlassSurface extends StatelessWidget {
  const GlassSurface({super.key, required this.radius, required this.child});

  final BorderRadius radius;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final light = colors.brightness == Brightness.light;
    final rim = Colors.white.withValues(alpha: light ? 0.85 : 0.20);
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: radius,
        boxShadow: [
          BoxShadow(
            color: colors.shadow.withValues(alpha: light ? 0.12 : 0.24),
            blurRadius: 16,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: Stack(
          children: [
            // 在纯色背景上也能从两侧看到主题色透过玻璃。
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      colors.primary.withValues(alpha: 0.22),
                      colors.surfaceContainerLow.withValues(alpha: 0.16),
                      colors.tertiary.withValues(alpha: 0.22),
                    ],
                  ),
                ),
              ),
            ),
            Positioned.fill(
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 4, sigmaY: 4),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: radius,
                    border: Border.all(color: rim),
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        colors.surface.withValues(alpha: light ? 0.48 : 0.56),
                        colors.surfaceContainerHigh.withValues(alpha: 0.24),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            child,
          ],
        ),
      ),
    );
  }
}

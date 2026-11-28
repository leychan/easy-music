import 'dart:convert';
import 'dart:io' show Platform;

import 'package:material_ui/material_ui.dart';

import '../player/session_store.dart';
import 'app_background.dart';
import 'linux_autostart.dart';
import 'music_toast.dart';
import 'workspace_page.dart';

typedef AppearanceOptions = ({ThemeMode mode, Color color, BackgroundStyle background});

class Appearance extends ValueNotifier<AppearanceOptions> {
  Appearance(this._store) : super(_restore(_store));
  final SessionStore _store;

  static const defaultColor = Color(0xFF74E3BA);
  static const desktopColor = Color(0xFFB86A3F);

  /// 页面和播放舞台共用底色，主题色仍用于按钮等强调元素。
  static const daySurface = Color(0xFFFBF6EE);
  static const nightSurface = Color(0xFF211923);

  static AppearanceOptions get defaults => (
    mode: ThemeMode.system,
    color: Platform.isLinux ? desktopColor : defaultColor,
    background: BackgroundStyle.diffuse,
  );

  static AppearanceOptions _restore(SessionStore store) {
    final raw = store.readPreference('appearance');
    if (raw == null) return defaults;
    try {
      final json = jsonDecode(raw);
      if (json is! Map) return defaults;
      final mode = ThemeMode.values
          .where((item) => item.name == json['mode'])
          .firstOrNull;
      final color = json['color'];
      // 旧版本只保存模式和主题色，升级后默认使用弥散背景。
      final background = BackgroundStyle.values
          .where((item) => item.name == json['background'])
          .firstOrNull;
      return (
        mode: mode ?? defaults.mode,
        color: color is int ? Color(color) : defaultColor,
        background: background ?? defaults.background,
      );
    } on FormatException {
      return defaults;
    }
  }

  void update({ThemeMode? mode, Color? color, BackgroundStyle? background}) {
    final next = (
      mode: mode ?? value.mode,
      color: color ?? value.color,
      background: background ?? value.background,
    );
    _store.savePreference(
      'appearance',
      jsonEncode({
        'mode': next.mode.name,
        'color': next.color.toARGB32(),
        'background': next.background.name,
      }),
    );
    value = next;
  }
}

const _themeModeLabels = {
  ThemeMode.system: '跟随系统',
  ThemeMode.light: '日间模式',
  ThemeMode.dark: '夜间模式',
};

const _backgroundLabels = {
  BackgroundStyle.diffuse: '弥散',
  BackgroundStyle.solid: '纯色',
};

void _updateAppearance(
  BuildContext context,
  Appearance appearance, {
  ThemeMode? mode,
  Color? color,
  BackgroundStyle? background,
}) {
  try {
    appearance.update(mode: mode, color: color, background: background);
  } catch (_) {
    showMusicNotice(context, '无法保存外观设置。');
  }
}

class AppearancePage extends StatelessWidget {
  const AppearancePage({super.key, required this.appearance});
  final Appearance appearance;

  @override
  Widget build(BuildContext context) => WorkspacePage(
    title: const Text('外观'),
    body: SafeArea(
      child: ValueListenableBuilder(
        valueListenable: appearance,
        builder: (context, options, _) => ListView(
          padding: DesktopPageScope.bodyPadding(context, const EdgeInsets.all(20)),
          children: [
            Text('主题模式', style: Theme.of(context).textTheme.titleMedium),
            Wrap(
              spacing: 8,
              children: [
                for (final entry in _themeModeLabels.entries)
                  ChoiceChip(
                    label: Text(entry.value),
                    selected: options.mode == entry.key,
                    onSelected: (selected) {
                      if (selected) {
                        _updateAppearance(context, appearance, mode: entry.key);
                      }
                    },
                  ),
              ],
            ),
            const SizedBox(height: 20),
            Text('背景色', style: Theme.of(context).textTheme.titleMedium),
            Wrap(
              spacing: 8,
              children: [
                for (final entry in _backgroundLabels.entries)
                  ChoiceChip(
                    label: Text(entry.value),
                    selected: options.background == entry.key,
                    onSelected: (selected) {
                      if (selected) _updateAppearance(context, appearance, background: entry.key);
                    },
                  ),
              ],
            ),
            if (Platform.isLinux) ...[
              const SizedBox(height: 16),
              const LinuxAutostart(),
            ],
            const SizedBox(height: 20),
            Text('主题色', style: Theme.of(context).textTheme.titleMedium),
            Wrap(
              spacing: 8,
              children: [
                for (final (color, title) in const [
                  (Appearance.defaultColor, '薄荷'),
                  (Appearance.desktopColor, '暖棕'),
                  (Color(0xFF81A9FF), '蓝色'),
                  (Color(0xFFE695B7), '粉色'),
                  (Color(0xFFBCA6F5), '紫色'),
                  (Color(0xFFEAB778), '暖橙'),
                ])
                  ChoiceChip(
                    avatar: CircleAvatar(backgroundColor: color),
                    label: Text(title),
                    selected: options.color == color,
                    onSelected: (selected) {
                      if (selected) _updateAppearance(context, appearance, color: color);
                    },
                  ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}

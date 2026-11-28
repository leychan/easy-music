import 'package:material_ui/material_ui.dart';

import 'app_background.dart';

/// 应用内居中弹窗共用背景、圆角和文字层级。
class AppDialog extends StatelessWidget {
  const AppDialog({
    super.key,
    required this.title,
    required this.content,
    this.actions = const [],
  });

  final Widget title;
  final Widget content;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dialogTheme = DialogTheme.of(context);
    return Dialog(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      shadowColor: theme.colorScheme.shadow.withValues(alpha: 0.38),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(24)),
      ),
      clipBehavior: Clip.antiAlias,
      insetPadding: const EdgeInsets.all(24),
      constraints: const BoxConstraints(maxWidth: 400),
      child: AppBackground(
        child: Material(
          type: MaterialType.transparency,
          // 弹出键盘或使用大字号时，内容和底部按钮可以一起滚动。
          child: SingleChildScrollView(
            primary: false,
            padding: const EdgeInsets.fromLTRB(24, 22, 24, 18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Semantics(
                  container: true,
                  namesRoute: true,
                  child: DefaultTextStyle(
                    style:
                        dialogTheme.titleTextStyle ??
                        theme.textTheme.titleLarge!,
                    child: title,
                  ),
                ),
                const SizedBox(height: 12),
                DefaultTextStyle(
                  style:
                      dialogTheme.contentTextStyle ??
                      theme.textTheme.bodyMedium!,
                  child: content,
                ),
                if (actions.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  OverflowBar(
                    alignment: MainAxisAlignment.end,
                    overflowAlignment: OverflowBarAlignment.end,
                    spacing: 8,
                    overflowSpacing: 4,
                    children: actions,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class AppChoiceDialog<T> extends StatelessWidget {
  const AppChoiceDialog({
    super.key,
    required this.title,
    required this.options,
    required this.selected,
  });

  final String title;
  final List<(T, String)> options;
  final T selected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return AppDialog(
      title: Text(title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (value, label) in options)
            Semantics(
              checked: value == selected,
              inMutuallyExclusiveGroup: true,
              child: SimpleDialogOption(
                onPressed: () => Navigator.pop(context, value),
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Row(
                  children: [
                    Icon(
                      value == selected
                          ? Icons.radio_button_checked_rounded
                          : Icons.radio_button_unchecked_rounded,
                      color: value == selected
                          ? colors.primary
                          : colors.onSurfaceVariant,
                      size: 20,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(label, style: theme.textTheme.titleMedium),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

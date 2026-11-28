import 'package:material_ui/material_ui.dart';

import 'app_background.dart';

class DiffuseMenuItem<T> {
  const DiffuseMenuItem({
    required this.value,
    required this.child,
    this.leadingIcon,
    this.enabled = true,
    this.checked,
  });

  final T value;
  final Widget child;
  final Widget? leadingIcon;
  final bool enabled;
  final bool? checked;
}

/// 菜单的定位、滚动和键盘操作交给 MenuAnchor，渐变铺在整组选项下方。
class DiffuseMenuButton<T> extends StatefulWidget {
  const DiffuseMenuButton({
    super.key,
    required this.itemBuilder,
    required this.onSelected,
    required this.tooltip,
    this.enabled = true,
    this.icon,
    this.child,
  });

  final List<DiffuseMenuItem<T>> Function(BuildContext) itemBuilder;
  final ValueChanged<T> onSelected;
  final String tooltip;
  final bool enabled;
  final Widget? icon;
  final Widget? child;

  @override
  State<DiffuseMenuButton<T>> createState() => _DiffuseMenuButtonState<T>();
}

class _DiffuseMenuButtonState<T> extends State<DiffuseMenuButton<T>> {
  final _focus = FocusNode();
  final _controller = MenuController();
  LocalHistoryEntry? _history;

  void _handleOpen() {
    final route = ModalRoute.of(context);
    if (route == null) return;
    // MenuAnchor 使用浮层，补上路由记录后系统返回键会先关闭菜单。
    final entry = LocalHistoryEntry(
      impliesAppBarDismissal: false,
      onRemove: () {
        if (_history == null) return;
        _history = null;
        _controller.close();
      },
    );
    _history = entry;
    route.addLocalHistoryEntry(entry);
  }

  void _handleClose() {
    final entry = _history;
    _history = null;
    entry?.remove();
  }

  @override
  void dispose() {
    _handleClose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MenuAnchor(
    childFocusNode: _focus,
    controller: _controller,
    onOpen: _handleOpen,
    onClose: _handleClose,
    animated: true,
    consumeOutsideTap: true,
    crossAxisUnconstrained: false,
    clipBehavior: Clip.antiAlias,
    style: const MenuStyle(
      backgroundColor: WidgetStatePropertyAll(Colors.transparent),
      surfaceTintColor: WidgetStatePropertyAll(Colors.transparent),
      shadowColor: WidgetStatePropertyAll(Color(0x40000000)),
      padding: WidgetStatePropertyAll(EdgeInsets.zero),
      minimumSize: WidgetStatePropertyAll(Size(112, 0)),
      maximumSize: WidgetStatePropertyAll(Size(280, double.infinity)),
      shape: WidgetStatePropertyAll(
        RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(12)),
        ),
      ),
    ),
    menuChildren: [
      Builder(
        builder: (context) => AppBackground(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final item in widget.itemBuilder(context))
                  Semantics(
                    checked: item.checked,
                    child: MenuItemButton(
                      leadingIcon: item.checked == null
                          ? item.leadingIcon
                          : item.checked!
                          ? const Icon(Icons.check_rounded, size: 20)
                          : const SizedBox(width: 20),
                      style: const ButtonStyle(
                        minimumSize: WidgetStatePropertyAll(Size(112, 48)),
                      ),
                      onPressed: item.enabled
                          ? () => widget.onSelected(item.value)
                          : null,
                      child: item.child,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    ],
    builder: (context, controller, _) {
      void toggle() =>
          controller.isOpen ? controller.close() : controller.open();
      final onPressed = widget.enabled ? toggle : null;
      return Semantics(
        button: true,
        enabled: widget.enabled,
        expanded: controller.isOpen,
        child: widget.child == null
            ? IconButton(
                focusNode: _focus,
                tooltip: widget.tooltip,
                icon: widget.icon ?? Icon(Icons.adaptive.more),
                onPressed: onPressed,
              )
            : Tooltip(
                message: widget.tooltip,
                child: InkWell(
                  focusNode: _focus,
                  onTap: onPressed,
                  child: widget.child,
                ),
              ),
      );
    },
  );
}

Future<T?> showDiffuseMenuSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool useSafeArea = false,
  bool isScrollControlled = false,
}) => showModalBottomSheet<T>(
  context: context,
  useSafeArea: useSafeArea,
  isScrollControlled: isScrollControlled,
  backgroundColor: Colors.transparent,
  shape: const RoundedRectangleBorder(
    borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
  ),
  clipBehavior: Clip.antiAlias,
  // 将拖拽条画在同一块背景上，保留底部面板原有的下滑关闭和返回行为。
  showDragHandle: false,
  builder: (context) {
    final theme = Theme.of(context);
    final handleSize =
        theme.bottomSheetTheme.dragHandleSize ?? const Size(32, 4);
    final handleColor =
        theme.bottomSheetTheme.dragHandleColor ??
        theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.4);
    return AppBackground(
      child: Material(
        type: MaterialType.transparency,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Semantics(
              label: MaterialLocalizations.of(context).modalBarrierDismissLabel,
              button: true,
              onTap: () => Navigator.pop(context),
              child: SizedBox(
                height: kMinInteractiveDimension,
                child: Center(
                  child: Container(
                    width: handleSize.width,
                    height: handleSize.height,
                    decoration: ShapeDecoration(
                      color: handleColor,
                      shape: const StadiumBorder(),
                    ),
                  ),
                ),
              ),
            ),
            Flexible(child: Builder(builder: builder)),
          ],
        ),
      ),
    );
  },
);

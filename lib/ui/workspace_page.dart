import 'package:material_ui/material_ui.dart';

/// 把底部避让空间放进滚动内容，让页面本身可以延伸到悬浮栏下。
EdgeInsets pageScrollPadding(BuildContext context, EdgeInsets padding) =>
    padding.copyWith(bottom: padding.bottom + MediaQuery.paddingOf(context).bottom);

/// 标记桌面右侧内容区，子页面可复用发现页的样式。
class DesktopPageScope extends InheritedWidget {
  const DesktopPageScope({super.key, required super.child});

  static bool active(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<DesktopPageScope>() != null;

  static EdgeInsets bodyPadding(BuildContext context, EdgeInsets standalone) =>
      active(context)
          ? EdgeInsets.only(top: standalone.top, bottom: standalone.bottom)
          : standalone;

  @override
  bool updateShouldNotify(DesktopPageScope oldWidget) => false;
}

class WorkspaceHeading extends StatelessWidget {
  const WorkspaceHeading({super.key, required this.title, this.actions = const []});

  final Widget title;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) => ConstrainedBox(
    constraints: const BoxConstraints(minHeight: 48),
    child: Row(
      children: [
        Expanded(
          child: DefaultTextStyle.merge(
            style: Theme.of(context).textTheme.headlineMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
            child: title,
          ),
        ),
        ...actions,
      ],
    ),
  );
}

/// 工作区内沿用外层面板和侧栏导航，独立打开时使用普通页面布局。
class WorkspacePage extends StatelessWidget {
  const WorkspacePage({super.key, required this.title, required this.body, this.actions = const []});

  final Widget title;
  final Widget body;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    if (!DesktopPageScope.active(context)) {
      return Scaffold(appBar: AppBar(title: title, actions: actions), body: body);
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 22, 24, 0),
      child: Column(
        children: [
          WorkspaceHeading(title: title, actions: actions),
          const SizedBox(height: 20),
          Expanded(child: body),
        ],
      ),
    );
  }
}

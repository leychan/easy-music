import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../updates/app_update.dart';
import 'app_dialog.dart';
import 'external_actions.dart';
import 'music_toast.dart';

class UpdateCheckTile extends StatefulWidget {
  const UpdateCheckTile({super.key});

  @override
  State<UpdateCheckTile> createState() => _UpdateCheckTileState();
}

class _UpdateCheckTileState extends State<UpdateCheckTile> {
  late final _packageInfo = PackageInfo.fromPlatform();
  bool _checking = false;

  Future<void> _check(String version) async {
    if (_checking) return;
    setState(() => _checking = true);
    try {
      final update = await checkAppUpdate(version);
      if (!mounted || ModalRoute.isCurrentOf(context) == false) return;
      if (update == null) {
        showMusicNotice(context, '已是最新版本。');
        return;
      }

      final apk = Platform.isAndroid ? update.androidApk : null;
      final download = await showDialog<bool>(
        context: context,
        builder: (context) => AppDialog(
          title: Text('发现新版本 ${update.version}'),
          content: Text('当前版本 $version'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('稍后'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(apk == null ? '查看发布页' : '下载 APK'),
            ),
          ],
        ),
      );
      if (!mounted || download != true) return;
      try {
        await openWebAddress(apk ?? update.releasePage);
      } catch (_) {
        if (mounted) showMusicNotice(context, '无法打开下载链接。');
      }
    } on Exception {
      if (mounted && ModalRoute.isCurrentOf(context) != false) {
        showMusicNotice(context, '检查更新失败，请稍后重试。');
      }
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<PackageInfo>(
    future: _packageInfo,
    builder: (context, snapshot) {
      final version = snapshot.data?.version ?? '';
      return ListTile(
        leading: const Icon(Icons.update_rounded),
        title: const Text('检查更新'),
        subtitle: Text(switch (snapshot.connectionState) {
          ConnectionState.done when version.isEmpty => '无法读取当前版本',
          ConnectionState.done when _checking => '正在检查更新…',
          ConnectionState.done => '当前版本 $version',
          _ => '正在读取当前版本…',
        }),
        onTap: version.isEmpty || _checking ? null : () => _check(version),
      );
    },
  );
}

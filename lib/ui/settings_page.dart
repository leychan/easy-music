import 'dart:io';

import 'package:material_ui/material_ui.dart';

import '../account/account.dart';
import '../player/playback.dart';
import 'appearance.dart';
import 'audio_cache_page.dart';
import 'external_actions.dart';
import 'playback_options.dart';
import 'music_toast.dart';
import 'update_check_tile.dart';
import 'workspace_page.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key, required this.account, required this.player, this.appearance});

  final Account account;
  final Playback player;
  final Appearance? appearance;

  @override
  Widget build(BuildContext context) => WorkspacePage(
    title: const Text('设置'),
    body: SafeArea(
      child: ListView(
        padding: DesktopPageScope.bodyPadding(context, const EdgeInsets.fromLTRB(20, 16, 20, 24)),
        children: [
          PlaybackQualityTile(player: player),
          PlaybackFadeTile(player: player),
          if (player.audioCache case final cache?)
            ValueListenableBuilder(
              valueListenable: cache.usage,
              builder: (context, usage, _) => ListTile(
                leading: const Icon(Icons.storage_outlined),
                title: const Text('音频缓存'),
                subtitle: Text(usage.limitMiB == 0 ? '已关闭' : '已使用 ${formatCacheSize(usage.bytes)}'),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => Navigator.of(context).push<void>(MaterialPageRoute(
                  builder: (_) => AudioCachePage(cache: cache),
                )),
              ),
            )
          else
            const ListTile(
              leading: Icon(Icons.storage_outlined),
              title: Text('音频缓存'),
              subtitle: Text('缓存暂不可用'),
              enabled: false,
            ),
          if (Platform.isAndroid)
            ListTile(
              leading: const Icon(Icons.notifications_outlined),
              title: const Text('播放通知'),
              subtitle: const Text('授权后可在通知栏播放、暂停和切歌'),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () async {
                try {
                  if (await managePlaybackNotifications()) player.refreshMediaNotification();
                } on Exception {
                  if (context.mounted) showMusicNotice(context, '无法打开系统通知设置。');
                }
              },
            ),
          ListenableBuilder(
            listenable: account,
            builder: (context, _) => SwitchListTile(
              secondary: const Icon(Icons.event_available_outlined),
              title: const Text('自动签到领 VIP'),
              subtitle: const Text('概念版账号每日领取畅听 VIP 并尝试升级'),
              value: account.autoDailyVip,
              onChanged: (enabled) async {
                try {
                  await account.setAutoDailyVip(enabled);
                } catch (_) {
                  if (context.mounted) showMusicNotice(context, '无法保存自动签到设置。');
                }
              },
            ),
          ),
          if (appearance case final appearance?)
            ListTile(
              leading: const Icon(Icons.palette_outlined),
              title: const Text('外观'),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => Navigator.of(context).push<void>(MaterialPageRoute(
                builder: (_) => AppearancePage(appearance: appearance),
              )),
            ),
          const UpdateCheckTile(),
          ListTile(
            leading: const Icon(Icons.info_outline_rounded),
            title: const Text('关于'),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => showAboutDialog(
              context: context,
              applicationName: 'Easy Music',
              applicationIcon: const Icon(Icons.graphic_eq_rounded),
              children: const [Text('支持 Android 和 Linux 的音乐播放器。')],
            ),
          ),
        ],
      ),
    ),
  );
}

import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../music/music_library.dart';
import '../player/audio_quality.dart';
import '../player/playback.dart';
import '../player/track.dart';
import 'app_dialog.dart';
import 'diffuse_menu.dart';
import 'music_toast.dart';

const playbackFadeOptions = [
  (0, '关闭淡入淡出'),
  (250, '0.25 秒'),
  (500, '0.5 秒'),
  (1000, '1 秒'),
];

// 当前值和箭头一起提示可点，整行仍共用同一个点击入口。
Widget _settingValue(BuildContext context, String label) {
  final theme = Theme.of(context);
  final colors = theme.colorScheme;
  final titleStyle = ListTileTheme.of(context).titleTextStyle ?? theme.textTheme.titleMedium;
  return DecoratedBox(
    decoration: BoxDecoration(
      color: colors.secondaryContainer,
      borderRadius: BorderRadius.circular(20),
    ),
    child: Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(12, 6, 8, 6),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Text(label, style: TextStyle(color: colors.onSecondaryContainer, fontSize: titleStyle?.fontSize)),
          ),
          const SizedBox(width: 4),
          Icon(Icons.keyboard_arrow_down_rounded, size: 20, color: colors.onSecondaryContainer),
        ],
      ),
    ),
  );
}

Widget _playbackSettingTile({
  required IconData icon,
  required String title,
  required String description,
  required String value,
  required VoidCallback onTap,
}) => LayoutBuilder(
  builder: (context, constraints) {
    // 窄屏或大字号时把选项移到说明下方，给标题留出整行宽度。
    final fontScale = MediaQuery.textScalerOf(context).scale(16) / 16;
    final stackValue = constraints.maxWidth < 244 * fontScale;
    final choice = _settingValue(context, value);
    return ListTile(
      leading: Icon(icon),
      title: Text(title),
      subtitle: stackValue
          ? Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [Text(description), const SizedBox(height: 6), choice],
            )
          : Text(description),
      trailing: stackValue ? null : choice,
      onTap: onTap,
    );
  },
);

class PlaybackFadeTile extends StatelessWidget {
  const PlaybackFadeTile({super.key, required this.player});

  final Playback player;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: player.fadeMilliseconds,
    builder: (context, current, _) => _playbackSettingTile(
      icon: Icons.graphic_eq_rounded,
      title: '播放淡入淡出',
      description: '开始播放、暂停和手动切歌时平滑调整音量',
      value: current == 0 ? '关闭' : '${current / 1000} 秒',
      onTap: () async {
        final selected = await showDialog<int>(
          context: context,
          builder: (_) => AppChoiceDialog(
            title: '播放淡入淡出',
            options: playbackFadeOptions,
            selected: current,
          ),
        );
        if (selected == null || !context.mounted) return;
        try {
          await player.setFadeMilliseconds(selected);
        } on Exception {
          if (context.mounted) showMusicNotice(context, '无法保存淡入淡出设置。');
        }
      },
    ),
  );
}

/// 不用先开始播放即可设定下一次点播使用的音质。
class PlaybackQualityTile extends StatelessWidget {
  const PlaybackQualityTile({super.key, required this.player});

  final Playback player;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: player.preferredQuality,
    builder: (context, preferred, _) => _playbackSettingTile(
      icon: Icons.high_quality_outlined,
      title: '首选音质',
      description: '用于下次点播',
      value: preferred.label,
      onTap: () async {
        final quality = await showDialog<AudioQuality>(
          context: context,
          builder: (_) => AppChoiceDialog(
            title: '首选音质',
            options: [
              for (final quality in AudioQuality.values) (quality, quality.label),
            ],
            selected: preferred,
          ),
        );
        if (quality != null && context.mounted) {
          await player.setPreferredQuality(quality);
        }
      },
    ),
  );
}

class QualityButton extends StatefulWidget {
  const QualityButton({
    super.key,
    required this.player,
    required this.library,
    required this.track,
  });

  final Playback player;
  final MusicLibrary library;
  final Track? track;

  @override
  State<QualityButton> createState() => _QualityButtonState();
}

class _QualityButtonState extends State<QualityButton> {
  bool _busy = false;

  Future<void> _select(AudioQuality quality) async {
    setState(() => _busy = true);
    try {
      final notice = await widget.library.changeQuality(widget.player, quality);
      if (!mounted || notice == null) return;
      showMusicNotice(context, notice);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: widget.player.preferredQuality,
    builder: (context, preferred, _) => DiffuseMenuButton<AudioQuality>(
      tooltip: '首选音质',
      enabled: !_busy,
      onSelected: _select,
      itemBuilder: (_) => [
        for (final quality in AudioQuality.values)
          DiffuseMenuItem(
            value: quality,
            checked: preferred == quality,
            child: Text(
              quality == AudioQuality.high ? '高品（320 kbps）' : quality.label,
            ),
          ),
      ],
      child: Padding(
        padding: const EdgeInsets.all(12),
        // 按实际播放的音质显示图标，避免降档时仍显示 HQ。
        child: _busy
            ? const SizedBox.square(
                dimension: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : switch (widget.track?.audioQuality) {
                AudioQuality.high => const Icon(
                    Icons.high_quality_outlined,
                    semanticLabel: '高品',
                  ),
                final quality => Text(
                    quality?.label ?? '音质',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
              },
      ),
    ),
  );
}

class SleepTimerButton extends StatelessWidget {
  const SleepTimerButton({super.key, required this.player});

  final Playback player;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: player.sleepDeadline,
    builder: (context, deadline, _) => IconButton(
      tooltip: deadline == null ? '定时暂停' : '定时暂停进行中',
      icon: Icon(
        deadline == null ? Icons.bedtime_outlined : Icons.bedtime_rounded,
        color: deadline == null ? null : Theme.of(context).colorScheme.primary,
      ),
      onPressed: () => showDialog<void>(
        context: context,
        builder: (_) => _SleepTimerDialog(player: player),
      ),
    ),
  );
}

class _SleepTimerDialog extends StatefulWidget {
  const _SleepTimerDialog({required this.player});

  final Playback player;

  @override
  State<_SleepTimerDialog> createState() => _SleepTimerDialogState();
}

class _SleepTimerDialogState extends State<_SleepTimerDialog> {
  final _minutes = TextEditingController(text: '30');
  SleepAction _action = SleepAction.pause;
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (widget.player.sleepDeadline.value != null) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _minutes.dispose();
    super.dispose();
  }

  static String _remaining(DateTime deadline) {
    final seconds = (deadline.difference(DateTime.now()).inMilliseconds / 1000)
        .ceil()
        .clamp(0, 10800);
    final minutes = (seconds ~/ 60).toString().padLeft(2, '0');
    final remainder = (seconds % 60).toString().padLeft(2, '0');
    return '$minutes:$remainder';
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: widget.player.sleepDeadline,
    builder: (context, deadline, _) {
      final minutes = int.tryParse(_minutes.text.trim());
      final valid = minutes != null && minutes >= 1 && minutes <= 180;
      return AppDialog(
        title: const Text('定时暂停'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (deadline != null) ...[
              Text('剩余 ${_remaining(deadline)}'),
              const SizedBox(height: 12),
            ],
            Wrap(
              spacing: 8,
              children: [
                for (final preset in [10, 20, 30, 60])
                  ChoiceChip(
                    label: Text('$preset 分钟'),
                    selected: minutes == preset,
                    onSelected: (_) =>
                        setState(() => _minutes.text = '$preset'),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            if (widget.player.onExit != null)
              Wrap(
                spacing: 8,
                children: [
                  for (final (action, label) in [
                    (SleepAction.pause, '暂停播放'), (SleepAction.exit, '退出应用'),
                  ])
                    ChoiceChip(
                      label: Text(label), selected: _action == action,
                      onSelected: (selected) { if (selected) setState(() => _action = action); },
                    ),
                ],
              ),
            TextField(
              controller: _minutes,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: '分钟（1–180）'),
              onChanged: (_) => setState(() {}),
            ),
          ],
        ),
        actions: [
          if (deadline != null)
            TextButton(
              onPressed: () {
                widget.player.cancelSleepTimer();
                Navigator.of(context).pop();
              },
              child: const Text('取消定时'),
            ),
          FilledButton(
            onPressed: valid
                ? () {
                    widget.player.startSleepTimer(Duration(minutes: minutes), action: _action);
                    Navigator.of(context).pop();
                  }
                : null,
            child: Text(deadline == null ? '开始' : '重新计时'),
          ),
        ],
      );
    },
  );
}

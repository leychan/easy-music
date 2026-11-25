import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../music/music_library.dart';
import '../player/audio_quality.dart';
import '../player/playback.dart';
import '../player/track.dart';
import 'music_toast.dart';

const playbackFadeOptions = [
  (0, '关闭淡入淡出'),
  (250, '0.25 秒'),
  (500, '0.5 秒'),
  (1000, '1 秒'),
];

class PlaybackFadeTile extends StatelessWidget {
  const PlaybackFadeTile({super.key, required this.player});

  final Playback player;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: player.fadeMilliseconds,
    builder: (context, current, _) => ListTile(
      leading: const Icon(Icons.graphic_eq_rounded),
      title: const Text('播放淡入淡出'),
      subtitle: const Text('开始播放、暂停和手动切歌时平滑调整音量'),
      trailing: Text(current == 0 ? '关闭' : '${current / 1000} 秒'),
      onTap: () async {
        final selected = await showDialog<int>(
          context: context,
          builder: (context) => SimpleDialog(
            title: const Text('播放淡入淡出'),
            children: [
              for (final (value, label) in playbackFadeOptions)
                SimpleDialogOption(
                  onPressed: () => Navigator.pop(context, value),
                  child: Row(children: [
                    Expanded(child: Text(label)),
                    if (value == current) const Icon(Icons.check_rounded, semanticLabel: '当前时长'),
                  ]),
                ),
            ],
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
    builder: (context, preferred, _) => ListTile(
      leading: const Icon(Icons.high_quality_outlined),
      title: const Text('首选音质'),
      subtitle: const Text('用于下次点播'),
      trailing: Text(preferred.label),
      onTap: () async {
        final quality = await showDialog<AudioQuality>(
          context: context,
          builder: (context) => SimpleDialog(
            title: const Text('首选音质'),
            children: [
              for (final quality in AudioQuality.values)
                SimpleDialogOption(
                  onPressed: () => Navigator.pop(context, quality),
                  child: Row(
                    children: [
                      Expanded(child: Text(quality.label)),
                      if (quality == preferred)
                        const Icon(Icons.check_rounded, semanticLabel: '当前音质'),
                    ],
                  ),
                ),
            ],
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
    builder: (context, preferred, _) => PopupMenuButton<AudioQuality>(
      tooltip: '首选音质',
      enabled: !_busy,
      onSelected: _select,
      itemBuilder: (_) => [
        for (final quality in AudioQuality.values)
          CheckedPopupMenuItem(
            value: quality,
            checked: preferred == quality,
            child: Text(quality.label),
          ),
      ],
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: _busy
            ? const SizedBox.square(
                dimension: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Text(
                widget.track?.audioQuality?.label ?? '音质',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
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
      return AlertDialog(
        title: const Text('定时暂停'),
        content: SingleChildScrollView(
          child: Column(
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

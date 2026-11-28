import 'dart:math' as math;

import 'package:flutter/services.dart' show PlatformException;
import 'package:material_ui/material_ui.dart';

import '../player/playback.dart';
import '../player/stem_mixer.dart';
import '../player/track.dart';
import 'music_toast.dart';

class StemMixButton extends StatelessWidget {
  const StemMixButton({super.key, required this.player, required this.track});

  final Playback player;
  final Track track;

  @override
  Widget build(BuildContext context) {
    final mixer = player.stemMixer!;
    return ListenableBuilder(
      listenable: mixer,
      builder: (context, _) => IconButton(
        tooltip: '人声 / 伴奏',
        isSelected: mixer.trackId == track.id,
        icon: const Icon(Icons.tune_rounded),
        selectedIcon: Icon(
          Icons.tune_rounded,
          color: Theme.of(context).colorScheme.primary,
        ),
        onPressed: () => showModalBottomSheet<void>(
          context: context,
          useSafeArea: true,
          isScrollControlled: true,
          showDragHandle: true,
          builder: (_) =>
              _StemMixPanel(player: player, mixer: mixer, track: track),
        ),
      ),
    );
  }
}

class _StemMixPanel extends StatefulWidget {
  const _StemMixPanel({
    required this.player,
    required this.mixer,
    required this.track,
  });

  final Playback player;
  final StemMixer mixer;
  final Track track;

  @override
  State<_StemMixPanel> createState() => _StemMixPanelState();
}

class _StemMixPanelState extends State<_StemMixPanel> {
  Playback get player => widget.player;
  StemMixer get mixer => widget.mixer;
  Track get track => widget.track;

  late Future<bool> _resources = player.hasStemMixResources(track);
  bool _preparedHere = false;
  bool _switching = false;

  Future<void> _run(Future<void> Function() action) async {
    try {
      await action();
    } on PlatformException catch (error) {
      if (mounted) showMusicNotice(context, error.message ?? '无法完成分轨操作，请重试。');
    } catch (_) {
      if (mounted) showMusicNotice(context, '无法完成分轨操作，请重试。');
    }
  }

  Future<void> _setMixEnabled(bool enabled) async {
    if (_switching) return;
    setState(() {
      _switching = true;
      if (!enabled) _preparedHere = true;
    });
    await _run(
      enabled ? () => player.enableStemMix(track) : player.disableStemMix,
    );
    if (mounted) {
      setState(() {
        _switching = false;
        if (mixer.trackId == track.id) _preparedHere = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
        child: FutureBuilder<bool>(
          future: _resources,
          builder: (context, resources) => StreamBuilder(
            stream: player.trackPlaybackStream,
            initialData: player.trackPlayback,
            builder: (context, current) => ListenableBuilder(
              listenable: Listenable.merge([
                mixer,
                player.experimentalKaraoke,
                player.tracks,
              ]),
              builder: (context, _) {
                final active = mixer.trackId == track.id;
                final request = mixer.preparation;
                final stillCurrent =
                    current.data?.trackId == track.id &&
                    player.tracks.value.any(
                      (item) =>
                          item.id == track.id &&
                          item.source == track.source &&
                          item.audioQuality == track.audioQuality,
                    );
                final ready =
                    stillCurrent &&
                    (active || _preparedHere || resources.data == true);
                // 命中缓存时保留调音控件，避免切换播放器时面板高度跳动。
                final showPreparation = request != null && !active &&
                    (!ready || request.hasSourceProgress);
                final busy = request != null || mixer.clearing || _switching;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (ready)
                      Row(
                        children: [
                          Expanded(
                            child: Text('人声 / 伴奏', style: text.titleLarge),
                          ),
                          Semantics(
                            label: '分轨开关',
                            child: Switch(
                              value: active,
                              onChanged: busy ? null : _setMixEnabled,
                            ),
                          ),
                          const SizedBox(width: 6),
                          const Text('分轨'),
                        ],
                      )
                    else
                      Text('人声 / 伴奏', style: text.titleLarge),
                    const SizedBox(height: 4),
                    Text(
                      track.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 16),
                    if (!stillCurrent)
                      const Text('已切换歌曲，请从当前歌曲打开此面板。')
                    else if (!player.canMixStems(track))
                      const Text('当前音源无法分轨。请播放本地歌曲或可完整读取的在线歌曲。')
                    else if (showPreparation) ...[
                      Text(_preparationLabel(request)),
                      const SizedBox(height: 8),
                      LinearProgressIndicator(
                        value: request.cancelled ? null : request.fraction,
                      ),
                      const SizedBox(height: 8),
                      OutlinedButton(
                        onPressed: request.cancelled
                            ? null
                            : () => _run(mixer.cancel),
                        child: const Text('取消'),
                      ),
                    ] else if (ready) ...[
                      _GainSlider(
                        label: '原唱',
                        value: mixer.vocalsFor(track.id),
                        onChanged: active && !busy
                            ? (value) =>
                                  _run(() => mixer.setGains(voice: value))
                            : null,
                      ),
                      _GainSlider(
                        label: '伴奏',
                        value: mixer.accompanimentFor(track.id),
                        onChanged: active && !busy
                            ? (value) =>
                                  _run(() => mixer.setGains(music: value))
                            : null,
                      ),
                      if (active && player.experimentalKaraoke.value) ...[
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('K 歌耳返'),
                          subtitle: const Text('建议戴耳机，避免外放啸叫'),
                          value: mixer.karaokeEnabled,
                          onChanged: mixer.changingKaraoke || busy
                              ? null
                              : (value) => _run(() => mixer.setKaraoke(value)),
                        ),
                        if (mixer.karaokeEnabled) ...[
                          _GainSlider(
                            label: '麦克风',
                            value: mixer.microphone,
                            onChanged: (value) =>
                                _run(() => mixer.setGains(mic: value)),
                          ),
                          _MicrophoneInputMeter(mixer: mixer),
                          _GainSlider(
                            label: '混响',
                            value: mixer.reverb,
                            onChanged: (value) =>
                                _run(() => mixer.setGains(room: value)),
                          ),
                        ],
                        if (mixer.karaokeError case final error?)
                          Text(
                            error,
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                            ),
                          ),
                      ],
                    ] else if (resources.connectionState ==
                        ConnectionState.waiting) ...[
                      const Text('正在检查分轨缓存…'),
                      const SizedBox(height: 8),
                      const LinearProgressIndicator(),
                    ] else ...[
                      Text(
                        track.isLocal
                            ? '首次需要下载约 40 MB 的模型。分轨时可以继续听原歌。'
                            : '在线歌曲需要先读取完整音频。首次还需下载约 40 MB 的模型，准备时可以继续听原歌。',
                      ),
                      const SizedBox(height: 12),
                      FilledButton(
                        onPressed: busy ? null : () => _setMixEnabled(true),
                        child: const Text('启用分轨'),
                      ),
                    ],
                    ValueListenableBuilder(
                      valueListenable: player.message,
                      builder: (context, value, _) =>
                          value == null || !stillCurrent
                          ? const SizedBox.shrink()
                          : Padding(
                              padding: const EdgeInsets.only(top: 8),
                              child: Text(
                                value,
                                style: TextStyle(
                                  color: Theme.of(context).colorScheme.error,
                                ),
                              ),
                            ),
                    ),
                    TextButton(
                      onPressed: mixer.active || busy
                          ? null
                          : () => _run(() async {
                              await mixer.clear();
                              if (mounted) {
                                setState(() {
                                  _resources = Future.value(false);
                                  _preparedHere = false;
                                });
                                showMusicNotice(this.context, '已清理分轨缓存');
                              }
                            }),
                      child: const Text('清理分轨缓存'),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  String _preparationLabel(StemPreparation request) {
    if (request.cancelled) return '正在取消…';
    final detail = switch (request.stage) {
      'download' => '正在下载分轨模型',
      'sourceDownload' => '正在准备在线音频',
      'decoding' => '正在解码原歌',
      'separating' => request.fraction == 0 ? '正在启动模型' : '正在分离人声和伴奏',
      'loading' => '正在切换到双轨播放',
      _ => '正在读取歌曲',
    };
    final fraction = request.fraction;
    if (fraction == null || request.stage == 'separating' && fraction == 0) {
      return '$detail…';
    }
    final percent = (fraction * 100).round();
    return '$detail · $percent%';
  }
}

class _MicrophoneInputMeter extends StatelessWidget {
  const _MicrophoneInputMeter({required this.mixer});

  final StemMixer mixer;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: mixer.microphoneInput,
    builder: (context, input, _) {
      final level = input?.level ?? 0;
      final status = switch (input?.state) {
        'opening' => '正在打开',
        'silenced' => '系统已静音，请检查麦克风开关或其他录音应用',
        'output' => '等待耳返输出',
        'active' => level >= 0.008 ? '已收到声音' : '等待声音',
        _ => '播放歌曲时拾音',
      };
      final route = input?.route ?? '麦克风';
      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('$route · $status'),
            const SizedBox(height: 6),
            LinearProgressIndicator(
              value: math.sqrt(level.clamp(0.0, 1.0)),
              semanticsLabel: '麦克风输入电平',
            ),
            if (input?.bluetoothOutput == true) ...[
              const SizedBox(height: 6),
              const Text('蓝牙输出有额外延迟，有线或 USB 耳机的耳返更及时。'),
            ],
          ],
        ),
      );
    },
  );
}

class _GainSlider extends StatelessWidget {
  const _GainSlider({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final double value;
  final ValueChanged<double>? onChanged;

  @override
  Widget build(BuildContext context) {
    final percent = (value * 100).round();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [Text(label), Text('$percent%')],
        ),
        Semantics(
          label: label,
          child: Slider(
            value: value,
            onChanged: onChanged,
            semanticFormatterCallback: (value) => '${(value * 100).round()}%',
          ),
        ),
      ],
    );
  }
}

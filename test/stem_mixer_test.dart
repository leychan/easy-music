import 'package:easy_music/player/stem_mixer.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const methods = MethodChannel('dev.easymusic.easy_music/stems');
  const events = MethodChannel('dev.easymusic.easy_music/stem_events');
  const external = MethodChannel('dev.easymusic.easy_music/external');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <MethodCall>[];
  var microphoneGranted = false;

  setUp(() {
    calls.clear();
    microphoneGranted = false;
    var karaoke = false;
    messenger.setMockMethodCallHandler(events, (call) async => null);
    messenger.setMockMethodCallHandler(external, (call) async {
      expect(call.method, 'karaokeMicrophonePermission');
      return microphoneGranted;
    });
    messenger.setMockMethodCallHandler(methods, (call) async {
      calls.add(call);
      final args = call.arguments as Map?;
      if (call.method == 'karaoke') karaoke = args?['enabled'] == true;
      return switch (call.method) {
        'prepare' => '/cache/stems.wav',
        'load' || 'seek' || 'karaoke' => {
          'id': 1,
          'state': 3,
          'playing': false,
          'duration': 10000,
          'position': args?['position'] ?? 0,
          'buffered': 10000,
          'karaoke': karaoke,
        },
        _ => null,
      };
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(events, null);
    messenger.setMockMethodCallHandler(methods, null);
    messenger.setMockMethodCallHandler(external, null);
  });

  Future<void> emit(Map<String, Object?> event) =>
      messenger.handlePlatformMessage(
        events.name,
        const StandardMethodCodec().encodeSuccessEnvelope(event),
        null,
      );

  test('分轨进度只更新当前请求，取消后忽略迟到的事件', () async {
    final mixer = StemMixer(onPlayback: (_) {}, onError: (_) {});
    addTearDown(mixer.dispose);
    final request = mixer.begin()!;
    expect(mixer.begin(), isNull);
    await mixer.prepare(request, Uri.parse('content://music/song'));
    await emit({
      'event': 'progress',
      'id': request.id + 1,
      'stage': 'download',
      'fraction': 0.9,
    });
    expect(request.stage, 'reading');
    expect(request.hasSourceProgress, isFalse);
    await emit({
      'event': 'progress',
      'id': request.id,
      'stage': 'download',
      'fraction': 0.4,
    });
    expect(request.fraction, 0.4);
    expect(request.hasSourceProgress, isTrue);
    await mixer.cancel();
    await emit({
      'event': 'progress',
      'id': request.id,
      'stage': 'download',
      'fraction': 0.8,
    });
    expect(request.fraction, 0.4);
    expect(calls.last.arguments, {'id': request.id});
    mixer.finish(request);
    expect(mixer.preparation, isNull);
  });

  test('K 歌获授权后保留原唱和伴奏，麦克风错误不打断分轨播放', () async {
    final updates = <bool>[];
    final errors = <int>[];
    var experimentEnabled = false;
    final mixer = StemMixer(
      onPlayback: updates.add,
      onError: errors.add,
      allowKaraoke: () => experimentEnabled,
    );
    addTearDown(mixer.dispose);
    final request = mixer.begin()!;
    await mixer.load(
      request: request,
      sourceTrackId: 'song',
      path: '/cache/stems.wav',
      position: const Duration(seconds: 3),
      volume: 0.8,
      speed: 1,
      repeatOne: false,
    );
    mixer.finish(request);
    await mixer.setGains(voice: 0.25, music: 0.8);
    await mixer.setKaraoke(true);
    expect(calls.where((call) => call.method == 'karaoke'), isEmpty);
    experimentEnabled = true;
    await expectLater(mixer.setKaraoke(true), throwsA(isA<PlatformException>()));
    expect(mixer.karaokeEnabled, isFalse);
    expect(calls.where((call) => call.method == 'karaoke'), isEmpty);
    microphoneGranted = true;
    await mixer.setKaraoke(true);
    expect(mixer.karaokeEnabled, isTrue);
    await mixer.setGains(mic: 0.7);
    expect((calls.last.arguments as Map)['reverb'], 0.18);
    await mixer.setGains(room: 0.35);
    expect(calls.last.arguments, {
      'vocals': 0.25,
      'accompaniment': 0.8,
      'microphone': 0.7,
      'reverb': 0.35,
    });
    expect(mixer.masterVolume, 0.8);
    await mixer.seek(const Duration(seconds: 6));
    expect(mixer.playback?.position, const Duration(seconds: 6));
    expect(updates, [false, false]);
    await emit({
      'event': 'position', 'id': request.id, 'state': 3, 'playing': true,
      'position': 6000, 'duration': 10000, 'buffered': 10000, 'karaoke': true,
      'microphoneInput': {
        'level': 0.1, 'route': '手机麦克风', 'state': 'active',
        'bluetoothOutput': true,
      },
    });
    expect(mixer.microphoneInput.value, (
      level: 0.1, route: '手机麦克风', state: 'active', bluetoothOutput: true,
    ));
    await emit({'event': 'karaokeError', 'id': request.id});
    expect(mixer.active, isTrue);
    expect(mixer.karaokeEnabled, isFalse);
    expect(mixer.karaokeError, isNotNull);
    expect(mixer.microphoneInput.value, isNull);
    final snapshot = await mixer.close();
    expect(snapshot?.position, const Duration(seconds: 6));
    await emit({'event': 'error', 'id': request.id});
    expect(errors, isEmpty);
    expect(mixer.active, isFalse);
  });
}

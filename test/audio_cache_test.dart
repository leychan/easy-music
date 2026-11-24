import 'dart:async';
import 'dart:io';

import 'package:easy_music/player/audio_cache.dart';
import 'package:easy_music/player/audio_quality.dart';
import 'package:easy_music/player/session_store.dart';
import 'package:easy_music/player/track.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory directory;
  late SessionStore store;
  late AudioCache cache;
  late HttpServer origin;
  late HttpClient client;
  late Future<void> Function(HttpRequest) serve;
  late int originRequests;
  final audio = List<int>.generate(1024, (index) => index % 256);

  Track track(String name, {String? id, AudioQuality? quality}) => Track(
    id: id ?? name,
    title: name,
    source: Uri.http('127.0.0.1:${origin.port}', '/$name.mp3'),
    audioQuality: quality,
  );

  Future<HttpClientResponse> response(
    Track track, {
    String? range,
    String method = 'GET',
  }) async {
    final request = await client.openUrl(method, cache.playbackUri(track));
    if (range != null) request.headers.set(HttpHeaders.rangeHeader, range);
    return request.close();
  }

  Future<List<int>> read(HttpClientResponse response) =>
      response.fold(<int>[], (bytes, chunk) => bytes..addAll(chunk));

  Future<void> waitForTracks(int count) async {
    if (cache.usage.value.tracks == count) return;
    final updated = Completer<void>();
    void listener() {
      if (cache.usage.value.tracks == count && !updated.isCompleted) {
        updated.complete();
      }
    }

    cache.usage.addListener(listener);
    try {
      await updated.future.timeout(const Duration(seconds: 2));
    } finally {
      cache.usage.removeListener(listener);
    }
  }

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('easy-music-cache-test');
    store = SessionStore(':memory:');
    cache = await AudioCache.open(directory, store);
    client = HttpClient();
    originRequests = 0;
    serve = (request) async {
      final response = request.response;
      response.headers.contentType = ContentType('audio', 'mpeg');
      response.contentLength = audio.length;
      response.add(audio);
      await response.close();
    };
    origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    origin.listen((request) async {
      originRequests++;
      await serve(request);
    });
  });

  tearDown(() async {
    client.close(force: true);
    await cache.close();
    await origin.close(force: true);
    store.close();
    await directory.delete(recursive: true);
  });

  test('完整音频写入磁盘，重启后可离线读取和拖动进度', () async {
    final song = track('song');
    expect(await read(await response(song)), audio);
    await waitForTracks(1);
    expect(cache.usage.value.bytes, audio.length);
    await cache.close();
    cache = await AudioCache.open(directory, store);
    await origin.close(force: true);
    expect(cache.usage.value.tracks, 1);

    final partial = await response(song, range: 'bytes=100-199');
    expect(partial.statusCode, HttpStatus.partialContent);
    expect(
      partial.headers.value(HttpHeaders.contentRangeHeader),
      'bytes 100-199/1024',
    );
    expect(await read(partial), audio.sublist(100, 200));
    expect(
      await read(await response(song, range: 'bytes=-4')),
      audio.sublist(1020),
    );
    final pastEnd = await response(song, range: 'bytes=1024-');
    expect(pastEnd.statusCode, HttpStatus.requestedRangeNotSatisfiable);
    await pastEnd.drain<void>();
    expect(originRequests, 1);
  });

  test('同一酷狗音质可复用临时地址，切换音质会读取对应音频', () async {
    final first = track(
      'first',
      id: 'kg:example',
      quality: AudioQuality.standard,
    );
    final renewed = track(
      'new-url',
      id: first.id,
      quality: AudioQuality.standard,
    );
    final lossless = track(
      'lossless',
      id: first.id,
      quality: AudioQuality.lossless,
    );
    await read(await response(first));
    await waitForTracks(1);
    expect(await read(await response(renewed)), audio);
    expect(originRequests, 1);
    await read(await response(lossless));
    await waitForTracks(2);
    expect(originRequests, 2);
  });

  test('分段和重复请求合并为整首，有缺口时不计入缓存', () async {
    serve = (request) async {
      final range = request.headers.value(HttpHeaders.rangeHeader)!;
      final endpoints = range.substring('bytes='.length).split('-');
      final start = int.parse(endpoints.first);
      final end = int.tryParse(endpoints.last) ?? audio.length - 1;
      final response = request.response;
      response.statusCode = HttpStatus.partialContent;
      response.headers.contentType = ContentType('audio', 'mpeg');
      response.headers.set(HttpHeaders.contentRangeHeader, 'bytes $start-$end/${audio.length}');
      response.contentLength = end - start + 1;
      response.add(audio.sublist(start, end + 1));
      await response.close();
    };
    final song = track('ranges');
    expect(await read(await response(song, range: 'bytes=512-')), audio.sublist(512));
    expect(await read(await response(song, range: 'bytes=0-255')), audio.sublist(0, 256));
    expect(await read(await response(song, range: 'bytes=512-')), audio.sublist(512));
    expect(cache.usage.value.tracks, 0);

    expect(await read(await response(song, range: 'bytes=128-767')), audio.sublist(128, 768));
    await waitForTracks(1);
    expect(cache.usage.value.bytes, audio.length);
    await origin.close(force: true);
    expect(await read(await response(song)), audio);
    expect(originRequests, 4);
  });

  test('两首歌同时读取时各自写入缓存', () async {
    final resume = Completer<void>();
    serve = (request) async {
      final response = request.response;
      response.headers.contentType = ContentType('audio', 'mpeg');
      response.contentLength = audio.length;
      response.bufferOutput = false;
      response.add(audio.sublist(0, 512));
      await response.flush();
      await resume.future;
      response.add(audio.sublist(512));
      await response.close();
    };
    final first = read(await response(track('first')));
    late Future<List<int>> second;
    try {
      second = read(await response(track('second')));
    } finally {
      resume.complete();
    }
    expect(await Future.wait([first, second]), [audio, audio]);
    await waitForTracks(2);
    expect(cache.usage.value.bytes, 2 * audio.length);
  });

  test('播放中清空会丢弃正在写入的缓存，音频仍能接收完整', () async {
    final resume = Completer<void>();
    serve = (request) async {
      final response = request.response;
      response.headers.contentType = ContentType('audio', 'mpeg');
      response.contentLength = audio.length;
      response.bufferOutput = false;
      response.add(audio.sublist(0, 512));
      await response.flush();
      await resume.future;
      response.add(audio.sublist(512));
      await response.close();
    };
    final song = track('clear');
    final fetching = read(await response(song));
    try {
      expect(
        directory.listSync().any((entry) => entry.path.endsWith('.part')),
        isTrue,
      );
      await cache.clear();
    } finally {
      resume.complete();
    }
    expect(await fetching, audio);
    expect(cache.usage.value.tracks, 0);
    expect(await directory.list().toList(), isEmpty);
  });

  test('连接中断留下的音频片段不会缓存，可以重新播放', () async {
    final completeResponse = serve;
    serve = (request) async {
      final socket = await request.response.detachSocket(writeHeaders: false);
      socket.write(
        'HTTP/1.1 200 OK\r\nContent-Type: audio/mpeg\r\n'
        'Content-Length: 1024\r\nConnection: close\r\n\r\n',
      );
      socket.add(audio.sublist(0, 512));
      await socket.close();
    };
    final song = track('interrupted');
    final interrupted = await response(song);
    if (interrupted.statusCode == HttpStatus.ok) {
      await expectLater(read(interrupted), throwsA(isA<HttpException>()));
    } else {
      expect(interrupted.statusCode, HttpStatus.badGateway);
      await interrupted.drain<void>();
    }
    expect(cache.usage.value.tracks, 0);
    serve = completeResponse;
    expect(await read(await response(song)), audio);
    await waitForTracks(1);
  });

  test('调低容量优先移除最久未使用的文件，关闭后不再写入', () async {
    final song = track('recent');
    await read(await response(song));
    await waitForTracks(1);
    await cache.close();
    final recent = directory.listSync().whereType<File>().single;
    const size = 150 * 1024 * 1024;
    final recentFile = await recent.open(mode: FileMode.append);
    await recentFile.truncate(size);
    await recentFile.close();
    final old = File(p.join(directory.path, '${'a' * 64}.audio'));
    final oldFile = await old.open(mode: FileMode.write);
    await oldFile.truncate(size);
    await oldFile.close();
    await old.setLastModified(DateTime.utc(2020));

    cache = await AudioCache.open(directory, store);
    await cache.setLimit(256);
    expect(cache.usage.value, (limitMiB: 256, bytes: size, tracks: 1));
    expect(await recent.exists(), isTrue);
    expect(await old.exists(), isFalse);

    await cache.setLimit(0);
    expect(await read(await response(song)), audio);
    await cache.close();
    cache = await AudioCache.open(directory, store);
    expect(cache.usage.value, (limitMiB: 0, bytes: 0, tracks: 0));
  });
}

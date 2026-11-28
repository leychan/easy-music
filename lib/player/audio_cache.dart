import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:synchronized/synchronized.dart';
import 'package:uuid/uuid.dart';

import 'session_store.dart';
import 'track.dart';

typedef AudioCacheUsage = ({int limitMiB, int bytes, int tracks});

/// Android 和 Linux 都通过本机回环地址读取在线音频，可边播边缓存。
/// 队列仍保存原始音源，这个地址只在当前进程的播放器里使用。
class AudioCache {
  AudioCache._(this._directory, this._store, this._limitMiB);

  static const limitsMiB = [0, 256, 512, 1024, 2048, 4096];
  static const _defaultLimit = 512;
  static const _preference = 'audio_cache_mib';
  static const _mib = 1024 * 1024;
  static final _cacheName = RegExp(r'^[a-f0-9]{64}\.audio$');
  static final _byteRange = RegExp(r'^bytes=(\d*)-(\d*)$');
  static final _contentRange = RegExp(r'^bytes (\d+)-(\d+)/(\d+)$');
  static const _maxPendingFiles = 8;
  static const _playlistExtensions = {'.m3u8', '.m3u', '.mpd', '.pls'};

  final Directory _directory;
  final SessionStore _store;
  final _lock = Lock();
  final _client = HttpClient()
    ..autoUncompress = false
    ..connectionTimeout = const Duration(seconds: 15);
  final _token = const Uuid().v4();
  final _routes = <String, Track>{};
  final _entries = <String, _CacheEntry>{};
  late final HttpServer _server;
  late final _usage = ValueNotifier<AudioCacheUsage>((
    limitMiB: _limitMiB,
    bytes: 0,
    tracks: 0,
  ));
  int _limitMiB;
  int _bytes = 0;
  int _generation = 0;
  final _writes = <String, _CacheWrite>{};
  bool _closed = false;

  ValueListenable<AudioCacheUsage> get usage => _usage;
  int get _limit => _limitMiB * _mib;

  static Future<AudioCache> open(
    Directory directory,
    SessionStore store,
  ) async {
    final limit = int.tryParse(store.readPreference(_preference) ?? '');
    final cache = AudioCache._(
      directory,
      store,
      limitsMiB.contains(limit) ? limit! : _defaultLimit,
    );
    await directory.create(recursive: true);
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is! File) continue;
      final name = p.basename(entity.path);
      if (name.startsWith('pending-') && name.endsWith('.part')) {
        await entity.delete();
      } else if (_cacheName.hasMatch(name)) {
        final stat = await entity.stat();
        if (stat.type != FileSystemEntityType.file) continue;
        cache._entries[p.basenameWithoutExtension(name)] = _CacheEntry(
          entity,
          stat.size,
          stat.modified,
        );
        cache._bytes += stat.size;
      }
    }
    await cache._trim(cache._limit);
    cache._publishUsage();
    cache._server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    cache._server.listen(cache._serve);
    return cache;
  }

  bool canProxyTrack(Track track) =>
      _canProxy(track.source) &&
      track.source.host != 'kugou.invalid' &&
      !_playlistExtensions.contains(p.extension(track.source.path).toLowerCase());

  /// 分轨复用同一音质的缓存标识，避免临时播放地址更新后找不到已分好的音轨。
  String stemCacheKey(Track track) => _key(track);

  Uri cachedPlaybackUri(Track track) =>
      playbackUri(track).replace(queryParameters: {'cachedOnly': '1'});

  Uri playbackUri(Track track) {
    final origin = track.source;
    if (!canProxyTrack(track)) return origin;
    final extension = p.extension(origin.path).toLowerCase();
    final key = _hash([
      track.id,
      track.albumAudioId,
      origin.toString(),
      track.audioQuality?.apiName,
    ]);
    _routes[key] = track;
    final suffix = RegExp(r'^\.[a-z0-9]{1,8}$').hasMatch(extension)
        ? extension
        : '';
    return Uri.http('127.0.0.1:${_server.port}', '/$_token/$key$suffix');
  }

  void retainTracks(List<Track> tracks) {
    final sources = {for (final track in tracks) (track.id, track.albumAudioId, track.source)};
    _routes.removeWhere(
      (_, track) => !sources.contains((track.id, track.albumAudioId, track.source)),
    );
  }

  static bool _canProxy(Uri uri) =>
      uri.host.isNotEmpty &&
      uri.userInfo.isEmpty &&
      (uri.scheme == 'https' ||
          (uri.scheme == 'http' &&
              (!Platform.isAndroid ||
                  uri.host == 'kugou.com' ||
                  uri.host.endsWith('.kugou.com'))));

  static String _hash(List<Object?> fields) =>
      sha256.convert(utf8.encode(jsonEncode(fields))).toString();

  static String _key(Track track) {
    // 酷狗的临时授权链接会变化。音质未知的旧队列和普通直链按完整地址匹配。
    if (track.kugouHash != null && track.audioQuality != null) {
      // 同一个哈希补正专辑曲目编号后，重新获取音频，避免读到旧编号的缓存。
      return _hash([track.id, track.albumAudioId, track.audioQuality!.apiName]);
    }
    return _hash([track.source.toString()]);
  }

  Future<void> setLimit(int limitMiB) => _lock.synchronized(() async {
    if (!limitsMiB.contains(limitMiB)) throw ArgumentError.value(limitMiB);
    _store.savePreference(_preference, '$limitMiB');
    _limitMiB = limitMiB;
    if (limitMiB == 0) _generation++;
    try {
      for (final writing in _writes.values.toList()) {
        if (writing.expected > _limit) await _discardWrite(writing);
      }
      await _makeRoom(0);
    } finally {
      _publishUsage();
    }
  });

  Future<void> clear() => _lock.synchronized(() async {
    _generation++;
    try {
      for (final writing in _writes.values.toList()) {
        await _discardWrite(writing);
      }
      await _trim(0);
    } finally {
      _publishUsage();
    }
  });

  void _publishUsage() => _usage.value = (
    limitMiB: _limitMiB,
    bytes: _bytes,
    tracks: _entries.length,
  );

  Future<void> _trim(int target) async {
    if (_bytes <= target) return;
    final entries = _entries.entries.toList()
      ..sort((a, b) => a.value.used.compareTo(b.value.used));
    for (final entry in entries) {
      if (_bytes <= target) break;
      final file = entry.value.file;
      if (await file.exists()) await file.delete();
      _bytes -= entry.value.bytes;
      _entries.remove(entry.key);
    }
  }

  Future<void> _serve(HttpRequest request) async {
    final response = request.response;
    final generation = _generation;
    // 切歌或拖动进度时，播放器可能主动断开请求。
    unawaited(response.done.then<void>((_) {}, onError: (Object _) {}));
    try {
      final segments = request.uri.pathSegments;
      final track = segments.length == 2 && segments.first == _token
          ? _routes[p.basenameWithoutExtension(segments.last)]
          : null;
      if (track == null ||
          (request.method != 'GET' && request.method != 'HEAD')) {
        response.statusCode = HttpStatus.notFound;
        return;
      }
      final key = _key(track);
      final cached = await _openCached(key);
      if (cached != null) {
        await _serveCached(request, cached.file, cached.bytes, cached.etag);
      } else if (request.uri.queryParameters['cachedOnly'] == '1') {
        response.statusCode = HttpStatus.notFound;
      } else {
        await _serveOrigin(request, track.source, key, generation);
      }
    } catch (_) {
      // 连接尚未发送数据时可返回错误；已开始传输的连接由 close 结束。
      try {
        response.statusCode = HttpStatus.badGateway;
        response.contentLength = 0;
      } on StateError {
        // 响应头已发送。
      }
    } finally {
      try {
        await response.close();
      } catch (_) {
        // 播放器已关闭连接。
      }
    }
  }

  Future<({RandomAccessFile file, int bytes, String? etag})?> _openCached(String key) =>
      _lock.synchronized(() async {
        final entry = _limit == 0 ? null : _entries[key];
        if (entry == null) return null;
        RandomAccessFile file;
        try {
          file = await entry.file.open();
        } on FileSystemException {
          // 系统或用户可能在应用运行时清掉缓存目录。
          _entries.remove(key);
          _bytes -= entry.bytes;
          _publishUsage();
          return null;
        }
        entry.used = DateTime.now();
        try {
          await entry.file.setLastModified(entry.used);
        } on FileSystemException {
          // 更新时间失败时，本次播放仍可使用已打开的文件。
        }
        return (file: file, bytes: entry.bytes, etag: entry.etag);
      });

  Future<void> _serveCached(
    HttpRequest request,
    RandomAccessFile file,
    int bytes,
    String? etag,
  ) async {
    try {
      final response = request.response;
      response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
      if (etag != null) response.headers.set(HttpHeaders.etagHeader, etag);
      response.headers.contentType = ContentType.binary;
      var start = 0;
      var end = bytes - 1;
      final range = _byteRange.firstMatch(
        request.headers.value(HttpHeaders.rangeHeader) ?? '',
      );
      if (range != null) {
        final first = int.tryParse(range[1]!);
        final last = int.tryParse(range[2]!);
        start = first ?? math.max(0, bytes - (last ?? 0));
        if (first != null && last != null) end = math.min(end, last);
        if (start > end) {
          response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
          response.headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes */$bytes',
          );
          return;
        }
        response.statusCode = HttpStatus.partialContent;
        response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes $start-$end/$bytes',
        );
      }
      response.contentLength = end - start + 1;
      if (request.method == 'HEAD') return;
      await file.setPosition(start);
      await response.addStream(_readBytes(file, response.contentLength));
    } finally {
      await file.close();
    }
  }

  Stream<List<int>> _readBytes(RandomAccessFile file, int remaining) async* {
    while (remaining > 0) {
      final chunk = await file.read(math.min(remaining, 64 * 1024));
      if (chunk.isEmpty) {
        throw const FileSystemException('Incomplete audio cache');
      }
      remaining -= chunk.length;
      yield chunk;
    }
  }

  Future<void> _serveOrigin(
    HttpRequest request,
    Uri origin,
    String key,
    int generation,
  ) async {
    final upstream = await _openOrigin(request, origin);
    final response = request.response;
    response.bufferOutput = false;
    response.statusCode = upstream.statusCode;
    response.contentLength = upstream.contentLength;
    for (final header in [
      HttpHeaders.contentTypeHeader,
      HttpHeaders.contentRangeHeader,
      HttpHeaders.acceptRangesHeader,
      HttpHeaders.contentEncodingHeader,
      HttpHeaders.etagHeader,
    ]) {
      if (upstream.headers[header] case final values?) {
        response.headers.set(header, values);
      }
    }
    if (request.method == 'HEAD') {
      await upstream.drain<void>();
      return;
    }
    final range = _audioRange(upstream);
    final writing = range == null ? null : await _beginWrite(
      key, origin, upstream.headers.value(HttpHeaders.etagHeader), range.total, generation,
    );
    final body = upstream.timeout(const Duration(seconds: 30));
    var offset = range?.start ?? 0;
    await response.addStream(
      writing == null ? body : body.asyncMap((chunk) async {
        final end = offset + chunk.length;
        if (end <= range!.end) await _writeChunk(writing, offset, end, chunk);
        offset = end;
        return chunk;
      }),
    );
  }

  Future<HttpClientResponse> _openOrigin(
    HttpRequest request,
    Uri origin,
  ) async {
    // 每次跳转都沿用 Android 对明文音源的域名限制。
    for (var redirects = 0; redirects <= 5; redirects++) {
      final outgoing = await _client.openUrl(request.method, origin);
      outgoing.followRedirects = false;
      outgoing.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      for (final header in [
        HttpHeaders.rangeHeader,
        HttpHeaders.userAgentHeader,
      ]) {
        if (request.headers[header] case final values?) {
          outgoing.headers.set(header, values);
        }
      }
      final response = await outgoing.close().timeout(
        const Duration(seconds: 30),
        onTimeout: () {
          const error = HttpException('Audio response timed out');
          outgoing.abort(error);
          throw error;
        },
      );
      if (!response.isRedirect) return response;
      final location = response.headers.value(HttpHeaders.locationHeader);
      await response.drain<void>();
      if (location == null) break;
      origin = origin.resolve(location);
      if (!_canProxy(origin)) break;
    }
    throw const HttpException('Invalid audio redirect');
  }

  ({int start, int end, int total})? _audioRange(HttpClientResponse response) {
    final mime = response.headers.contentType?.mimeType;
    final encoding = response.headers.value(HttpHeaders.contentEncodingHeader);
    if ((encoding != null && encoding != 'identity') ||
        response.contentLength <= 0 ||
        (mime != null &&
            !mime.startsWith('audio/') &&
            !mime.startsWith('video/') &&
            mime != 'application/octet-stream' &&
            mime != 'application/ogg') ||
        (mime?.contains('mpegurl') ?? false) ||
        mime == 'audio/x-scpls') {
      return null;
    }
    final length = response.contentLength;
    if (response.statusCode == HttpStatus.ok) {
      return (start: 0, end: length, total: length);
    }
    if (response.statusCode != HttpStatus.partialContent) return null;
    final range = _contentRange.firstMatch(
      response.headers.value(HttpHeaders.contentRangeHeader) ?? '',
    );
    if (range == null) return null;
    final start = int.tryParse(range[1]!);
    final end = int.tryParse(range[2]!);
    final total = int.tryParse(range[3]!);
    if (start == null || end == null || total == null ||
        start > end || end >= total || end - start + 1 != length) {
      return null;
    }
    return (start: start, end: end + 1, total: total);
  }

  Future<_CacheWrite?> _beginWrite(
    String key, Uri origin, String? etag, int expected, int generation,
  ) => _lock.synchronized(() async {
    if (_closed || generation != _generation || expected > _limit || _entries.containsKey(key)) {
      return null;
    }
    try {
      if (_writes[key] case final existing?) {
        // 临时链接变化或上游替换了文件时，旧片段不能拼到新音频里。
        if (existing.origin == origin && existing.etag == etag && existing.expected == expected) {
          return existing;
        }
        await _discardWrite(existing);
      }
      if (_writes.length >= _maxPendingFiles) await _discardWrite(_writes.values.first);
      await _directory.create(recursive: true);
      final partial = File(p.join(_directory.path, 'pending-${const Uuid().v4()}.part'));
      final handle = await partial.open(mode: FileMode.write);
      return _writes[key] = _CacheWrite(key, origin, etag, partial, handle, expected);
    } on FileSystemException {
      return null;
    }
  });

  Future<void> _writeChunk(_CacheWrite writing, int start, int end, List<int> chunk) =>
      _lock.synchronized(() async {
        if (!identical(_writes[writing.key], writing)) return;
        final added = writing.recordRange(start, end);
        if (added == 0) return;
        try {
          await _makeRoom(added, keep: writing);
          // 顺序读取时沿用文件位置，只有拖动进度或交错请求才需要移动它。
          if (start != writing.position) await writing.handle.setPosition(start);
          await writing.handle.writeFrom(chunk);
          writing.position = end;
          writing.bytes += added;
          // 只公布无缺口的整首音频。重复或交叠的请求不会把缺失的范围误算为已写入。
          if (writing.bytes == writing.expected) await _commitWrite(writing);
        } on FileSystemException {
          if (identical(_writes[writing.key], writing)) {
            try {
              await _discardWrite(writing);
            } on FileSystemException {
              // 删除失败的临时文件在下次打开缓存时清理。
            }
          }
        } finally {
          _publishUsage();
        }
      });

  Future<void> _makeRoom(int extra, {_CacheWrite? keep}) async {
    var pendingBytes = _writes.values.fold<int>(extra, (bytes, item) => bytes + item.bytes);
    if (_bytes + pendingBytes <= _limit) return;
    // 先让空间给正在播放的歌曲，再按原有规则淘汰最久未使用的完整缓存。
    for (final item in _writes.values.toList()) {
      if (_bytes + pendingBytes <= _limit) break;
      if (identical(item, keep)) continue;
      pendingBytes -= item.bytes;
      await _discardWrite(item);
    }
    await _trim(_limit - pendingBytes);
  }

  Future<void> _commitWrite(_CacheWrite writing) async {
    await writing.handle.close();
    final file = await writing.partial.rename(p.join(_directory.path, '${writing.key}.audio'));
    _writes.remove(writing.key);
    _entries[writing.key] = _CacheEntry(file, writing.bytes, DateTime.now(), etag: writing.etag);
    _bytes += writing.bytes;
  }

  Future<void> _discardWrite(_CacheWrite writing) async {
    _writes.remove(writing.key);
    // rename 失败时文件句柄可能已经关闭，仍需清理路径。
    try {
      await writing.handle.close();
    } on FileSystemException {
      // 文件句柄已关闭。
    }
    if (await writing.partial.exists()) await writing.partial.delete();
  }

  Future<void> close() async {
    _closed = true;
    _client.close(force: true);
    await _server.close(force: true);
    await _lock.synchronized(() async {
      for (final writing in _writes.values.toList()) {
        await _discardWrite(writing);
      }
    });
  }
}

class _CacheEntry {
  _CacheEntry(this.file, this.bytes, this.used, {this.etag});

  final File file;
  final int bytes;
  final String? etag;
  DateTime used;
}

class _CacheWrite {
  _CacheWrite(this.key, this.origin, this.etag, this.partial, this.handle, this.expected);

  final String key;
  final Uri origin;
  final String? etag;
  final File partial;
  final RandomAccessFile handle;
  final int expected;
  final _ranges = <({int start, int end})>[];
  int bytes = 0;
  int position = 0;

  /// 合并有交集或相邻的区间，返回这次真正补齐的字节数。
  int recordRange(int start, int end) {
    var first = 0;
    while (first < _ranges.length && _ranges[first].end < start) {
      first++;
    }
    var last = first;
    var alreadyCovered = 0;
    while (last < _ranges.length && _ranges[last].start <= end) {
      final range = _ranges[last++];
      start = math.min(start, range.start);
      end = math.max(end, range.end);
      alreadyCovered += range.end - range.start;
    }
    _ranges.replaceRange(first, last, [(start: start, end: end)]);
    return end - start - alreadyCovered;
  }
}

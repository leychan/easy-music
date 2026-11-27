import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:csv/csv.dart';
import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';

import '../account/kugou/kugou_auth.dart';
import 'playlist_import.dart';

/// 从歌单提取供酷狗搜索使用的曲名和歌手。文件里的路径和链接仅用于推测曲名。
abstract final class PlaylistFileImport {
  static Future<List<ImportPreview>> read(
    String fileName,
    Stream<List<int>> chunks,
  ) async {
    final buffer = _PlaylistBytes();
    await for (final chunk in chunks) {
      buffer.add(chunk);
    }
    final bytes = buffer.takeBytes();
    return Isolate.run(() => _parse(fileName, bytes));
  }

  static List<ImportPreview> _parse(String fileName, Uint8List bytes) {
    try {
      // 洛雪的 LXMC 是 gzip 压缩的 JSON，也限制解压后的大小。
      final compressed =
          bytes.length >= 2 && bytes[0] == 0x1f && bytes[1] == 0x8b;
      if (compressed) {
        final unpacked = _PlaylistBytes();
        gzip.decoder.startChunkedConversion(unpacked)
          ..add(bytes)
          ..close();
        bytes = unpacked.takeBytes();
      }
      final content = _decode(bytes).trim();
      final title = p.basenameWithoutExtension(fileName);
      if (content.isEmpty) {
        throw const KugouFailure('歌单文件为空。');
      }
      final previews = _detect(
        content,
        title,
        p.extension(fileName).toLowerCase(),
      );
      final playable = previews
          .where((item) => item.tracks.isNotEmpty)
          .toList();
      if (playable.isEmpty) {
        throw const KugouFailure('歌单里没有可用于匹配的曲目信息。');
      }
      return playable;
    } on FormatException {
      throw const KugouFailure('无法读取歌单文件，请检查文件内容和文字编码。');
    } on XmlException {
      throw const KugouFailure('歌单的 XML 格式有误。');
    }
  }

  static String _decode(Uint8List bytes) {
    if (bytes.length >= 2) {
      final bom = ByteData.sublistView(bytes).getUint16(0);
      if (bom == 0xfeff || bom == 0xfffe) {
        if (bytes.length.isOdd) throw const FormatException('UTF-16');
        final data = ByteData.sublistView(bytes);
        final endian = bom == 0xfeff ? Endian.big : Endian.little;
        return String.fromCharCodes([
          for (var offset = 2; offset < bytes.length; offset += 2)
            data.getUint16(offset, endian),
        ]);
      }
    }
    return utf8.decode(bytes);
  }

  static final _m3uHeader = RegExp(
    r'^#EXT(M3U(?:\s|$)|INF:)',
    caseSensitive: false,
  );

  static List<ImportPreview> _detect(
    String content,
    String title,
    String extension,
  ) {
    // 先看格式特征，只有没有标记的 M3U 才需要用扩展名辅助判断。
    if (content.startsWith('<')) return [_xspf(content, title)];
    if (content.startsWith('{') || content.startsWith('"{')) {
      return _lxMusic(content, title);
    }
    final lines = const LineSplitter()
        .convert(content)
        .map((line) => line.trim());
    final header = lines.firstWhere(
      (line) =>
          line.isNotEmpty && !line.startsWith(';') && !line.startsWith('#'),
      orElse: () => '',
    );
    if (header.toUpperCase() == '[PLAYLIST]') return [_pls(lines, title)];
    final table = _csv(content, lines.first, title);
    if (table != null) return [table];
    if (lines.any(_m3uHeader.hasMatch)) return [_m3u(lines, title)];
    final entries = lines.where(
      (line) => line.isNotEmpty && !line.startsWith('#'),
    );
    if (const ['.m3u', '.m3u8'].contains(extension) ||
        (entries.isNotEmpty &&
            entries.every((line) => _mediaName(line).isNotEmpty))) {
      return [_m3u(lines, title)];
    }
    throw _unknownFormat;
  }

  static const _unknownFormat = KugouFailure(
    '无法识别歌单文件。支持 M3U、M3U8、PLS、XSPF、CSV 和洛雪歌单备份。',
  );

  static ImportPreview _m3u(Iterable<String> lines, String fileTitle) {
    var title = fileTitle;
    var label = '';
    final tracks = <ImportTrack>[];
    for (final line in lines) {
      final tag = line.toUpperCase();
      if (tag.startsWith('#EXT-X-')) {
        throw const KugouFailure('这是 HLS 播放流，请选择音乐歌单文件。');
      }
      if (tag.startsWith('#PLAYLIST:')) {
        title = _or(line.substring(10).trim(), title);
      } else if (tag.startsWith('#EXTINF:')) {
        final comma = line.indexOf(',');
        label = comma < 0 ? '' : line.substring(comma + 1);
      } else if (line.isNotEmpty && !line.startsWith('#')) {
        final track = _labelTrack(label, line);
        if (track != null) tracks.add(track);
        label = '';
      }
    }
    return ImportPreview(title, tracks, format: 'M3U / M3U8');
  }

  static final _plsField = RegExp(
    r'^(file|title)(\d+)\s*=(.*)$',
    caseSensitive: false,
  );

  static ImportPreview _pls(Iterable<String> lines, String title) {
    final files = <int, String>{};
    final labels = <int, String>{};
    for (final line
        in lines
            .skipWhile((line) => line.toUpperCase() != '[PLAYLIST]')
            .skip(1)) {
      if (line.startsWith('[')) break;
      final field = _plsField.firstMatch(line);
      if (field == null) continue;
      final index = int.tryParse(field[2]!);
      if (index == null || index < 1) continue;
      final entries = field[1]!.toLowerCase() == 'file' ? files : labels;
      entries[index] = field[3]!.trim();
    }
    final indexes = files.keys.toList()..sort();
    return ImportPreview(title, [
      for (final index in indexes)
        ?_labelTrack(labels[index] ?? '', files[index]!),
    ], format: 'PLS');
  }

  static ImportPreview _xspf(String content, String title) {
    final root = XmlDocument.parse(content).rootElement;
    final trackList = _element(root, 'trackList');
    if (root.name.local != 'playlist' || trackList == null) {
      throw _unknownFormat;
    }
    final tracks = <ImportTrack>[];
    for (final row in trackList.childElements.where(
      (node) => node.name.local == 'track',
    )) {
      final name = _elementText(row, 'title');
      final artist = _elementText(row, 'creator');
      if (name.isNotEmpty) {
        tracks.add(ImportTrack(name, artist));
      } else if (_labelTrack('', _elementText(row, 'location'))
          case final track?) {
        tracks.add(ImportTrack(track.title, _or(artist, track.artists)));
      }
    }
    return ImportPreview(
      _or(_elementText(root, 'title'), title),
      tracks,
      format: 'XSPF',
    );
  }

  static XmlElement? _element(XmlElement root, String name) =>
      root.childElements.where((node) => node.name.local == name).firstOrNull;

  static String _elementText(XmlElement root, String name) =>
      _element(root, name)?.innerText.trim() ?? '';

  static List<ImportPreview> _lxMusic(String content, String title) {
    var decoded = jsonDecode(content);
    // 部分旧版洛雪把同一份 JSON 序列化了两次。
    if (decoded is String) decoded = jsonDecode(decoded);
    if (decoded is! Map) throw _unknownFormat;
    final data = decoded['data'];
    final lists = switch (decoded['type']) {
      'playListPart' || 'playListPart_v2' || 'defautlList' => [data],
      'playList' || 'playList_v2' when data is List => data,
      'allData' || 'allData_v2' when decoded['playList'] is List =>
        decoded['playList'] as List,
      _ => throw _unknownFormat,
    };
    return [
      for (final list in lists.whereType<Map>())
        if (list['list'] case final List tracks)
          ImportPreview(_or(_text(list['name']), title), [
            for (final track in tracks.whereType<Map>())
              if (_text(track['name']) case final name when name.isNotEmpty)
                ImportTrack(name, _text(track['singer'])),
          ], format: '洛雪音乐'),
    ];
  }

  static const _titleHeaders = {
    'trackname',
    'tracktitle',
    'songname',
    'songtitle',
    'title',
    'name',
    '歌曲名',
    '歌名',
    '歌曲',
    '歌曲名称',
    '曲名',
    '曲目',
    '标题',
  };
  static const _artistHeaders = {
    'artist',
    'artists',
    'artistname',
    'artistnames',
    'trackartist',
    'singer',
    'performer',
    '歌手',
    '歌手名',
    '歌手名称',
    '艺人',
    '艺术家',
    '演唱者',
  };

  static ImportPreview? _csv(String content, String firstLine, String title) {
    if (!firstLine.contains(RegExp(r'[,;\t]'))) return null;
    final rows = csv.decode(content);
    if (rows.isEmpty) return null;
    final headers = rows.first
        .map(
          (cell) =>
              _text(cell).toLowerCase().replaceAll(RegExp(r'[\s()_-]'), ''),
        )
        .toList();
    final name = headers.indexWhere(_titleHeaders.contains);
    final artist = headers.indexWhere(_artistHeaders.contains);
    // 同时有曲名和歌手列才把普通表格识别为歌单。
    if (name < 0 || artist < 0) return null;
    return ImportPreview(title, [
      for (final row in rows.skip(1))
        if (_text(row.elementAtOrNull(name)) case final value
            when value.isNotEmpty)
          ImportTrack(value, _text(row.elementAtOrNull(artist))),
    ], format: 'CSV');
  }

  static final _artistTitleSeparator = RegExp(r'\s+[-–—]\s+');
  static final _audioExtension = RegExp(
    r'\.(mp3|flac|wav|m4a|m4b|ogg|opus|oga|aac|wma|ape|alac|aiff?|mpc|dsf|dff|mka|wv|tak|ac3)$',
    caseSensitive: false,
  );

  static ImportTrack? _labelTrack(String label, String location) {
    final name = _or(label, _mediaName(location)).trim();
    if (name.isEmpty) return null;
    final separator = _artistTitleSeparator.firstMatch(name);
    if (separator == null) return ImportTrack(name, '');
    return ImportTrack(
      name.substring(separator.end),
      name.substring(0, separator.start),
    );
  }

  static String _mediaName(String location) {
    final path = location.replaceAll('\\', '/');
    // URI 的查询参数不属于文件名，本地路径中的 # 和 ? 则可能是歌名的一部分。
    final uri = path.contains('://') ? Uri.tryParse(path) : null;
    var name = p.posix.basename(uri?.path ?? path);
    try {
      name = Uri.decodeComponent(name);
    } on FormatException {
      // 本地文件名可能有原样保存的百分号。
    } on ArgumentError {
      // 无效的百分号转义依然可以作为原始文件名使用。
    }
    return _audioExtension.hasMatch(name)
        ? p.posix.basenameWithoutExtension(name)
        : '';
  }

  static String _text(Object? value) => value is String ? value.trim() : '';

  static String _or(String value, String fallback) =>
      value.isEmpty ? fallback : value;
}

class _PlaylistBytes extends ByteConversionSink {
  static const _maxBytes = 16 * 1024 * 1024;
  final _buffer = BytesBuilder();

  @override
  void add(List<int> chunk) {
    if (chunk.length > _maxBytes - _buffer.length) {
      throw const KugouFailure('歌单文件超过 16 MB，请拆分后导入。');
    }
    _buffer.add(chunk);
  }

  Uint8List takeBytes() => _buffer.takeBytes();

  @override
  void close() {}
}

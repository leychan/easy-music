import 'dart:convert';
import 'dart:io';

class LyricLine {
  const LyricLine(this.start, this.text, {this.words = const [], this.translation = ''});

  final Duration start;
  final String text;
  final List<LyricWord> words;
  final String translation;
}

class LyricWord {
  const LyricWord(this.start, this.text, {this.duration = Duration.zero});
  final Duration start;
  final String text;
  final Duration duration;
}

class LyricVersion {
  const LyricVersion(this.id, this.accessKey, this.title, this.author, this.duration);
  final String id;
  final String accessKey;
  final String title;
  final String author;
  final int duration;
}

final _timestamp = RegExp(r'\[(\d{1,4}):([0-5]\d)(?:[.:](\d{1,3}))?\]');
final _leadingTimestamps = RegExp(
  r'^(?:\[\d{1,4}:[0-5]\d(?:[.:]\d{1,3})?\]\s*)+',
);
final _offset = RegExp(
  r'^\[offset\s*:\s*([+-]?\d+)\s*\]$',
  caseSensitive: false,
);

List<LyricLine> parseLrc(String input) {
  final lines = input.replaceFirst('\uFEFF', '').split(RegExp(r'\r?\n'));
  var offsetMs = 0;
  for (final line in lines) {
    final offset = _offset.firstMatch(line.trim());
    if (offset != null) offsetMs = int.tryParse(offset[1]!) ?? 0;
  }

  // 同一句歌词可以有多个时间标签，例如重复的副歌。
  final lyrics = <LyricLine>[];
  for (final rawLine in lines) {
    final line = rawLine.trim();
    final prefix = _leadingTimestamps.firstMatch(line);
    if (prefix == null) continue;

    final text = line.substring(prefix.end).trim();
    for (final tag in _timestamp.allMatches(prefix[0]!)) {
      final minutes = int.parse(tag[1]!);
      final seconds = int.parse(tag[2]!);
      final fraction = int.parse((tag[3] ?? '').padRight(3, '0'));
      final timeMs = (minutes * 60 + seconds) * 1000 + fraction - offsetMs;
      lyrics.add(LyricLine(Duration(milliseconds: timeMs), text));
    }
  }

  lyrics.sort((a, b) => a.start.compareTo(b.start));
  return lyrics;
}

int activeLyricIndex(List<LyricLine> lyrics, Duration position) {
  // 定位最后一条已开始的歌词，前后拖动进度时都能直接找到对应行。
  var low = 0;
  var high = lyrics.length;
  while (low < high) {
    final mid = (low + high) ~/ 2;
    if (lyrics[mid].start <= position) {
      low = mid + 1;
    } else {
      high = mid;
    }
  }
  return low - 1;
}

final _krcLine = RegExp(r'^\[(\d+),\d+\](.*)$');
final _krcWord = RegExp(r'<(\d+),(\d+),\d+>(.*?)(?=<\d+,\d+,\d+>|$)');
final _yrcWord = RegExp(r'\((\d+),(\d+),\d+\)(.*?)(?=\(\d+,\d+,\d+\)|$)');
final _language = RegExp(r'^\[language:([^\]]+)\]$', multiLine: true);
const _krcKey = [
  0x40, 0x47, 0x61, 0x77, 0x5e, 0x32, 0x74, 0x47,
  0x51, 0x36, 0x31, 0x2d, 0xce, 0xd2, 0x6e, 0x69,
];

/// KRC 解包后保留逐字时间和附带的翻译，供播放器自行渲染。
String? decodeKrc(List<int> bytes) {
  if (bytes.length <= 4 ||
      bytes[0] != 0x6b || bytes[1] != 0x72 ||
      bytes[2] != 0x63 || bytes[3] != 0x31) {
    return null;
  }
  try {
    final compressed = [
      for (var i = 4; i < bytes.length; i++)
        bytes[i] ^ _krcKey[(i - 4) % _krcKey.length],
    ];
    final text = utf8.decode(zlib.decode(compressed)).replaceFirst('\uFEFF', '');
    return const LineSplitter().convert(text).any(_krcLine.hasMatch) ? text : null;
  } on FormatException {
    return null;
  }
}

List<LyricLine> parseLyrics(String input) {
  final rows = const LineSplitter().convert(input.replaceFirst('\uFEFF', ''));
  final timed = rows.map(_krcLine.firstMatch).whereType<RegExpMatch>().toList();
  if (timed.isEmpty) return parseLrc(input);
  final offsets = rows.map(_offset.firstMatch).whereType<RegExpMatch>();
  final offset = int.tryParse(offsets.lastOrNull?[1] ?? '') ?? 0;
  final translations = _translations(input);
  final result = <LyricLine>[];
  for (final (index, match) in timed.indexed) {
    final start = int.tryParse(match[1]!);
    if (start == null) continue;
    final body = match[2]!;
    final krc = _krcWord.allMatches(body).toList();
    final words = [
      for (final word in (krc.isNotEmpty ? krc : _yrcWord.allMatches(body)))
        if (int.tryParse(word[1]!) case final time?)
          LyricWord(
            Duration(milliseconds: (krc.isNotEmpty ? start + time : time) - offset),
            word[3]!,
            duration: Duration(milliseconds: int.tryParse(word[2]!) ?? 0),
          ),
    ];
    result.add(LyricLine(
      Duration(milliseconds: start - offset),
      words.isEmpty ? body.trim() : words.map((word) => word.text).join(),
      words: words,
      translation: translations.elementAtOrNull(index) ?? '',
    ));
  }
  result.sort((a, b) => a.start.compareTo(b.start));
  return result;
}

List<String> _translations(String input) {
  final encoded = _language.firstMatch(input)?[1];
  if (encoded == null) return const [];
  try {
    final payload = jsonDecode(utf8.decode(base64Decode(encoded)));
    final entries = payload is Map ? payload['content'] : null;
    if (entries is List) {
      for (final entry in entries.whereType<Map>()) {
        final lines = entry['lyricContent'];
        if (entry['type']?.toString() == '1' && lines is List) {
          return [
            for (final line in lines)
              line is List ? line.whereType<String>().join() : (line is String ? line : ''),
          ];
        }
      }
    }
  } on FormatException {
    // 翻译数据损坏时仍可显示原歌词。
  }
  return const [];
}

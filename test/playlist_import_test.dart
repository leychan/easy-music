import 'dart:convert';
import 'dart:io';

import 'package:easy_music/account/kugou/kugou_auth.dart';
import 'package:easy_music/music/playlist_file_import.dart';
import 'package:easy_music/music/playlist_import.dart';
import 'package:flutter_test/flutter_test.dart';

Future<List<ImportPreview>> read(String fileName, String text) =>
    PlaylistFileImport.read(fileName, Stream.value(utf8.encode(text)));

List<(String, String)> tracks(ImportPreview preview) =>
    preview.tracks.map((track) => (track.title, track.artists)).toList();

void main() {
  test('根据内容识别改名的 M3U，读取标签，并从文件名补齐信息', () async {
    final result = (await read(
      '分享.txt',
      '\ufeff'
          r'''
#EXTM3U
#PLAYLIST:深夜歌单
#EXTINF:200,歌手甲 - 曲目 - 现场版
https://music.example.com/stream?id=42
..\音乐\歌手乙 - 第二首.flac
file:///music/%E7%AC%AC%E4%B8%89%E9%A6%96.mp3
''',
    )).single;

    expect(result.format, 'M3U / M3U8');
    expect(result.title, '深夜歌单');
    expect(tracks(result), [('曲目 - 现场版', '歌手甲'), ('第二首', '歌手乙'), ('第三首', '')]);
  });

  test('无标记和无扩展名的 M3U 可以根据音频路径识别', () async {
    final result = (await read('歌单', 'music/第一首.ogg\n第二首.m4a')).single;
    expect(tracks(result), [('第一首', ''), ('第二首', '')]);
  });

  test('根据 PLS 标记识别，按曲目编号排序，接受 UTF-16 导出', () async {
    const input =
        '[Playlist]\r\nTitle2=歌手 - 第二首\r\n'
        'File2=https://radio.example.com/listen\r\nFile1=第一首.mp3\r\n';
    final result = (await PlaylistFileImport.read(
      '列表.m3u',
      Stream.value([
        0xff,
        0xfe,
        for (final unit in input.codeUnits) ...[unit & 0xff, unit >> 8],
      ]),
    )).single;

    expect(result.format, 'PLS');
    expect(tracks(result), [('第一首', ''), ('第二首', '歌手')]);
  });

  test('识别带命名空间的 XSPF，保留单独的歌手和标题字段', () async {
    final result = (await read('export', '''
<?xml version="1.0"?>
<x:playlist xmlns:x="http://xspf.org/ns/0/" version="1">
  <x:title>甲 &amp; 乙</x:title>
  <x:trackList>
    <x:track><x:title>A - B</x:title><x:creator>甲</x:creator></x:track>
    <x:track><x:location>audio/第二首.wav</x:location></x:track>
    <x:track><x:location>https://music.example.com/unknown</x:location></x:track>
  </x:trackList>
</x:playlist>
''')).single;

    expect(result.format, 'XSPF');
    expect(result.title, '甲 & 乙');
    expect(tracks(result), [('A - B', '甲'), ('第二首', '')]);
  });

  test('CSV 接受中英文表头和带逗号的字段', () async {
    final english = (await read(
      'export.data',
      '\ufeff'
          'Track URI,Track Name,Artist Name(s)\r\n'
          'spotify:track:1,"歌名, 副标题","甲;乙"\r\n',
    )).single;
    final chinese = (await read('export', '歌曲名称;歌手\n歌名;歌手甲')).single;

    expect(english.format, 'CSV');
    expect(tracks(english), [('歌名, 副标题', '甲;乙')]);
    expect(tracks(chinese), [('歌名', '歌手甲')]);
  });

  test('洛雪压缩备份按歌单分别预览，并忽略空歌单', () async {
    final archive = gzip.encode(
      utf8.encode(
        jsonEncode({
          'type': 'playList_v2',
          'data': [
            {'name': '试听列表', 'list': []},
            {
              'name': '一',
              'list': [
                {'name': '第一首', 'singer': '甲'},
              ],
            },
            {
              'name': '二',
              'list': [
                {'name': '第二首', 'singer': '乙'},
              ],
            },
          ],
        }),
      ),
    );
    final result = await PlaylistFileImport.read(
      'backup',
      Stream.fromIterable([archive.sublist(0, 1), archive.sublist(1)]),
    );

    expect(result.map((preview) => preview.title), ['一', '二']);
    expect(result.map((preview) => preview.format), everyElement('洛雪音乐'));
    expect(result.map(tracks), [
      [('第一首', '甲')],
      [('第二首', '乙')],
    ]);
  });

  test('洛雪旧版单个歌单用 JSON 内容识别', () async {
    final result = (await read(
      'legacy.json',
      jsonEncode(
        jsonEncode({
          'type': 'playListPart',
          'data': {
            'name': '旧歌单',
            'list': [
              {'name': '歌名', 'singer': '歌手'},
            ],
          },
        }),
      ),
    )).single;
    expect(result.title, '旧歌单');
    expect(tracks(result), [('歌名', '歌手')]);
  });

  test('拒绝 HLS、普通表格和损坏的 XML', () async {
    await expectLater(
      read('stream.m3u8', '#EXTM3U\n#EXT-X-TARGETDURATION:5\n#EXTINF:5,\na.ts'),
      throwsA(
        isA<KugouFailure>().having(
          (error) => error.message,
          'message',
          contains('HLS'),
        ),
      ),
    );
    await expectLater(
      read('table.csv', 'name,email\n甲,foo@example.com'),
      throwsA(isA<KugouFailure>()),
    );
    await expectLater(
      read('list.xspf', '<playlist><trackList>'),
      throwsA(isA<KugouFailure>()),
    );
  });

  test('公开歌单导入可以从分享文字中识别完整链接', () async {
    final calls = <String>[];
    final importer = PublicPlaylistImport((playlist) async {
      calls.add(playlist.globalCollectionId);
      return [];
    });

    await importer.read(
      'https://www.kugou.com/yy/special/single/collection_1.html',
    );
    await importer.read(
      '歌单介绍 https://example.com/\n歌单「https://www.kugou.com/yy/special/single/collection_2.html」。',
    );
    expect(calls, ['collection_1', 'collection_2']);
  });
}

import 'dart:convert';

import 'package:easy_music/account/kugou/kugou_client.dart';
import 'package:easy_music/account/kugou/kugou_device.dart';
import 'package:easy_music/music/kugou_music_api.dart';
import 'package:easy_music/music/song.dart';
import 'package:easy_music/player/lyrics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 歌词是两段式接口，任何一步的细节错了都只会静默返回 null，
/// 所以把两段的请求形状都固定下来。
void main() {
  final device = KugouDevice(guid: 'g-1', mac: 'AA:BB:CC:DD:EE:FF');
  late List<http.Request> requests;

  KugouMusicApi clientReturning(Object Function(http.Request) respond) {
    requests = [];
    return KugouMusicApi(
      KugouClient(
        device,
        client: MockClient((request) async {
          requests.add(request);
          return http.Response(jsonEncode(respond(request)), 200);
        }),
      ),
    );
  }

  test('先查候选再用同一次返回的 accesskey 下载', () async {
    final api = clientReturning((request) {
      if (request.url.host == 'krcs.kugou.com') {
        return {
          'status': 200,
          'candidates': [
            {'id': '1', 'accesskey': 'WRONG', 'duration': 100000},
            {'id': '274944371', 'accesskey': '2A7B3588', 'duration': 269792},
          ],
        };
      }
      return {
        'status': 200,
        'contenttype': 1,
        'content': base64Encode(utf8.encode('[00:00.00]晴天')),
      };
    });

    final lrc = await api.lyrics(
      _song(duration: const Duration(seconds: 269)),
    );
    expect(lrc, '[00:00.00]晴天');
    expect(requests, hasLength(2));

    // 第一段：keyword 必须为空串，传歌名会搜出别人唱的同名歌。
    final search = requests.first.url;
    expect(search.host, 'krcs.kugou.com');
    expect(search.queryParameters['keyword'], '');
    expect(search.queryParameters['hash'], 'B3A52A7A958BF0AED0EBFBA2E9A818B7');
    expect(search.queryParameters['duration'], '269000');

    // 第二段：必须选时长最接近的那个候选，用它的 id 与 accesskey。
    final download = requests.last.url;
    expect(download.host, 'lyrics.kugou.com');
    expect(download.queryParameters['id'], '274944371');
    expect(download.queryParameters['accesskey'], '2A7B3588');
    expect(download.queryParameters['fmt'], 'krc');
  });

  test('没有候选时返回 null 且不发起下载请求', () async {
    final api = clientReturning((_) => {'status': 200, 'candidates': []});
    expect(await api.lyrics(_song()), isNull);
    expect(requests, hasLength(1));
  });

  test('KRC 歌词保留中文、行时间和偏移', () async {
    final api = clientReturning((request) {
      if (request.url.host == 'krcs.kugou.com') {
        return {
          'candidates': [
            {'id': 'bad', 'duration': 269000},
            {'id': '1', 'accesskey': 'k', 'duration': '269010'},
          ],
        };
      }
      return {
        'contenttype': '0',
        'content':
            'a3JjMTjbGsglTQAO9+OCgBP9uCbNouu5EXlfCXyHAxn+0hxlzcssA95+9x9KNSx+'
            'zdFzavtgGmCGsixXj+WUVndw4+QMC7AjY1+fOuCKIC36B3G2',
      };
    });
    final lines = parseLyrics((await api.lyrics(_song()))!);
    expect(lines.map((line) => line.text), ['你好', '再见']);
    expect(lines.map((line) => line.start.inMilliseconds), [1134, 3145]);
    expect(lines.first.words.map((word) => word.start.inMilliseconds), [1134, 1634]);
    expect(requests.last.url.queryParameters['id'], '1');
  });

  test('损坏的 KRC 内容返回 null', () async {
    final api = clientReturning((request) {
      if (request.url.host == 'krcs.kugou.com') {
        return {
          'candidates': [
            {'id': '1', 'accesskey': 'k', 'duration': 269000},
          ],
        };
      }
      return {
        'contenttype': 0,
        'content': base64Encode([...ascii.encode('krc1'), 1, 2, 3, 4]),
      };
    });
    expect(await api.lyrics(_song()), isNull);
  });

  test('KRC 保留附带翻译，YRC 逐字时间按绝对毫秒读取', () {
    final language = base64Encode(utf8.encode(jsonEncode({
      'content': [
        {'type': 1, 'lyricContent': [['你好']]},
      ],
    })));
    final translated = parseLyrics('[language:$language]\n[1000,800]<0,400,0>Hel<400,400,0>lo').single;
    expect(translated.translation, '你好');
    expect(translated.text, 'Hello');
    expect(translated.words.last.start.inMilliseconds, 1400);
    expect(translated.words.last.duration.inMilliseconds, 400);
    final yrc = parseLyrics('[2000,700](2000,300,0)春(2300,400,0)天').single;
    expect(yrc.text, '春天');
    expect(yrc.words.last.start.inMilliseconds, 2300);
    expect(yrc.words.first.duration.inMilliseconds, 300);
  });
}

Song _song({Duration duration = const Duration(seconds: 269)}) =>
    Song(
      hash: 'B3A52A7A958BF0AED0EBFBA2E9A818B7',
      title: '晴天',
      albumAudioId: 20505418,
      duration: duration,
    );

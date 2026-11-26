import 'dart:convert';

import 'package:easy_music/updates/app_update.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

MockClient _release(String tag, {List<String> assets = const []}) =>
    MockClient((request) async {
      expect(
        request.url,
        Uri.parse(
          'https://api.github.com/repos/leychan/easy-music/releases/latest',
        ),
      );
      return http.Response(
        jsonEncode({
          'tag_name': tag,
          'assets': [
            for (final name in assets) {'name': name},
          ],
        }),
        200,
      );
    });

void main() {
  test('版本按数字比较，并匹配正式 Android ARM64 APK', () async {
    final update = await checkAppUpdate(
      '0.1.9+4026',
      client: _release(
        'v0.1.10',
        assets: ['easy-music-0.1.10-android-arm64.apk'],
      ),
    );

    expect(update?.version, '0.1.10');
    expect(
      update?.releasePage.toString(),
      'https://github.com/leychan/easy-music/releases/tag/v0.1.10',
    );
    expect(
      update?.androidApk.toString(),
      'https://github.com/leychan/easy-music/releases/download/v0.1.10/easy-music-0.1.10-android-arm64.apk',
    );
  });

  test('同版本的构建号不参与比较，也不提示降级', () async {
    final client = _release('v0.1.6');
    expect(await checkAppUpdate('0.1.6+4026', client: client), isNull);
    expect(await checkAppUpdate('0.1.7', client: client), isNull);
  });

  test('预览版可以升级到同版本的正式版，缺少 APK 时仍有发布页', () async {
    final update = await checkAppUpdate(
      '0.1.6-beta.1+4026',
      client: _release(
        'v0.1.6',
        assets: ['easy-music-0.1.6-android-arm64-debug.apk'],
      ),
    );

    expect(update?.version, '0.1.6');
    expect(update?.releasePage.path, '/leychan/easy-music/releases/tag/v0.1.6');
    expect(update?.androidApk, isNull);
  });

  test('无效的正式版标签和 GitHub 请求失败都抛出错误', () async {
    await expectLater(
      checkAppUpdate('0.1.6', client: _release('v0.1.7-beta')),
      throwsFormatException,
    );
    final client = MockClient((_) async => http.Response('{}', 403));
    await expectLater(
      checkAppUpdate('0.1.6', client: client),
      throwsA(isA<http.ClientException>()),
    );
  });
}

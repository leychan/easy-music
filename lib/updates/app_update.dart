import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:pub_semver/pub_semver.dart';

const _repository = 'leychan/easy-music';
final _stableTag = RegExp(
  r'^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$',
);

class AppUpdate {
  const AppUpdate({
    required this.version,
    required this.releasePage,
    this.androidApk,
  });

  final String version;
  final Uri releasePage;
  final Uri? androidApk;
}

/// 查询 GitHub 已发布的正式版。有更新时返回发布页和可用的 APK 链接。
Future<AppUpdate?> checkAppUpdate(
  String installedVersion, {
  http.Client? client,
}) async {
  // 标签只记录发布版本。安装包的 +构建号不参与更新判断。
  final current = Version.parse(installedVersion.split('+').first);
  final requestClient = client ?? http.Client();
  try {
    final response = await requestClient
        .get(
          Uri.https('api.github.com', '/repos/$_repository/releases/latest'),
          headers: const {'Accept': 'application/vnd.github+json'},
        )
        .timeout(const Duration(seconds: 10));
    if (response.statusCode != 200) {
      throw http.ClientException(
        'GitHub Releases returned HTTP ${response.statusCode}',
      );
    }

    final release = jsonDecode(response.body);
    final tag = release is Map<String, dynamic> ? release['tag_name'] : null;
    if (tag is! String || !_stableTag.hasMatch(tag)) {
      throw const FormatException('Invalid GitHub release tag');
    }
    final version = tag.substring(1);
    if (Version.parse(version) <= current) return null;

    // 使用发布工作流的正式 APK 文件名，缺少附件时由界面打开发布页。
    final apkName = 'easy-music-$version-android-arm64.apk';
    final assets = release['assets'];
    final hasApk =
        assets is List &&
        assets.any((asset) => asset is Map && asset['name'] == apkName);
    return AppUpdate(
      version: version,
      releasePage: Uri.https('github.com', '/$_repository/releases/tag/$tag'),
      androidApk: hasApk
          ? Uri.https(
              'github.com',
              '/$_repository/releases/download/$tag/$apkName',
            )
          : null,
    );
  } finally {
    if (client == null) requestClient.close();
  }
}

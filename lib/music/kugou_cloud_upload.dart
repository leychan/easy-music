import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../account/kugou/kugou_auth.dart';
import '../account/kugou/signature.dart';
import 'kugou_music_api.dart';

extension KugouCloudUpload on KugouMusicApi {
  Future<void> uploadCloudFile(
    String fileName,
    Stream<Uint8List> Function() open,
    void Function(int uploaded, int total) progress,
  ) async {
    final account = client.session;
    if (account == null) throw const KugouFailure('请先登录酷狗账号。');
    final ext = p.extension(fileName).replaceFirst('.', '').toLowerCase();
    if (!RegExp(r'^[a-z0-9]{1,8}$').hasMatch(ext)) {
      throw const KugouFailure('无法识别音频文件格式。');
    }
    var size = 0;
    final md5 = await crypto.md5
        .bind(
          open().map((bytes) {
            size += bytes.length;
            return bytes;
          }),
        )
        .first;
    if (size <= 0) throw const KugouFailure('音频文件为空。');

    void checkAccount() {
      if (client.session?.userid != account.userid ||
          client.session?.token != account.token) {
        throw const KugouFailure('账号已变化，请重新选择文件。');
      }
    }

    const bucket = 'musicclound';
    final hash = md5.toString();
    final bss = <String, Object?>{
      'bucket': bucket,
      'filename': hash,
      'version': client.clientver,
      'uuid': client.device.guid,
    };
    checkAccount();
    final auth = await client.get(
      Uri.parse('https://gateway.kugou.com/bsstrackercdngz/v1/upload/auth'),
      extraParams: {
        ...bss,
        'method': 'POST',
        'loginType': 1,
        'extranet': 1,
        'buVerifyCode': crypto.md5
            .convert(
              utf8.encode('${client.appid}${bucket}8ae10344e9738dcb'),
            )
            .toString(),
      },
    );
    final authData = _uploadData(auth, '获取上传授权');
    final authorization = authData['authorization'];
    if (authorization is! String || authorization.isEmpty) {
      throw const KugouFailure('酷狗未返回上传授权。');
    }
    final transport = http.Client();
    try {
      Future<Map> send(
        String host,
        String path,
        Map<String, Object?> extra,
        String action, {
        List<int>? bytes,
      }) async {
        checkAccount();
        final params = <String, Object?>{
          ...bss,
          ...extra,
          'authorization': authorization,
          'userid': account.userid,
          'token': account.token,
          'dfid': client.device.dfid,
          'mid': client.device.mid,
          'appid': client.appid,
          'clientver': client.clientver,
          'clienttime': DateTime.now().millisecondsSinceEpoch ~/ 1000,
        };
        params['signature'] = client.isLite ? KugouSignature.liteAndroid(params) : KugouSignature.android(params);
        final request =
            http.Request(
                'POST',
                Uri.https(
                  host,
                  path,
                  params.map((key, value) => MapEntry(key, '$value')),
                ),
              )
              ..followRedirects = false
              ..headers['authorization'] = authorization;
        if (bytes != null) {
          request.headers['content-type'] = 'application/octet-stream';
          request.bodyBytes = bytes;
        }
        final response = await transport
            .send(request)
            .then(http.Response.fromStream)
            .timeout(const Duration(seconds: 30));
        if (response.statusCode != 200) throw KugouFailure('$action失败，请稍后重试。');
        final result = jsonDecode(response.body);
        if (result is! Map) throw KugouFailure('$action响应无法读取。');
        return _uploadData(result, action);
      }

      final init = await send(
        'bssulbig.kugou.com',
        '/v2/multipart/initiate/music',
        {'ssl': 1, 'extendname': ext},
        '初始化上传',
      );
      final uploadId = init['upload_id']?.toString() ?? '';
      var cloudHash = init['x-bss-filename']?.toString() ?? hash;
      if (uploadId.isNotEmpty) {
        final advertised = init['external_host']?.toString() ?? '';
        final endpoint = Uri.tryParse(
          advertised.contains('://') ? advertised : 'https://$advertised',
        );
        final host = endpoint?.host ?? '';
        if (endpoint == null ||
            !host.endsWith('.kugou.com') ||
            endpoint.userInfo.isNotEmpty) {
          throw const KugouFailure('酷狗没有提供安全的上传地址。');
        }
        const partSize = 1024 * 1024;
        final pending = BytesBuilder(copy: false);
        var part = 0;
        var uploaded = 0;
        Future<void> pushPart() async {
          final bytes = pending.takeBytes();
          await send(
            host,
            '/v3/multipart/upload',
            {'partnumber': ++part, 'upload_id': uploadId, 'body_empty': 1},
            '上传音频分片',
            bytes: bytes,
          );
          uploaded += bytes.length;
          progress(uploaded, size);
        }

        await for (final chunk in open()) {
          var offset = 0;
          while (offset < chunk.length) {
            final end = math.min(
              chunk.length,
              offset + partSize - pending.length,
            );
            pending.add(Uint8List.sublistView(chunk, offset, end));
            offset = end;
            if (pending.length == partSize) await pushPart();
          }
        }
        if (pending.isNotEmpty) await pushPart();
        if (uploaded != size) throw const KugouFailure('文件在上传期间发生变化，请重试。');
        final completed = await send(host, '/v3/multipart/complete', {
          'partnumber': part,
          'upload_id': uploadId,
          'md5': hash,
          'if_id3': 1,
        }, '确认文件上传');
        cloudHash = completed['x-bss-filename']?.toString() ?? cloudHash;
      } else if (init['x-bss-hash'] == null && init['x-bss-filename'] == null) {
        throw const KugouFailure('酷狗未返回可用的上传任务。');
      }

      checkAccount();
      final result = await client.cloudPost(
        Uri.parse('https://mcloudservice.kugou.com/v1/add_files'),
        body: {
          'list_ver': 0,
          'data': [
            {
              'name': fileName,
              'ext': ext,
              'author_name': '',
              'hash': cloudHash,
              'hash_std': hash,
              'audio_id': 0,
              'bitrate': 4,
              'album_audio_id': 0,
              'size': size,
              'timelen': 0,
            },
          ],
        },
      );
      _uploadData(result, '加入音乐云盘');
      progress(size, size);
    } finally {
      transport.close();
    }
  }

  static Map _uploadData(Map result, String phase) {
    if (result['status']?.toString() != '1') {
      throw KugouFailure('$phase失败，请稍后重试。');
    }
    final data = result['data'];
    return data is Map ? data : const {};
  }
}

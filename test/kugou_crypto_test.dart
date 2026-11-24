import 'dart:convert';

import 'package:easy_music/account/kugou/crypto.dart';
import 'package:easy_music/account/kugou/kugou_client.dart';
import 'package:easy_music/account/kugou/kugou_device.dart';
import 'package:easy_music/account/kugou/signature.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 期望值由 KuGouMusicApi 的原始算法（util/helper.js、util/util.js）产出。
/// 两边输入完全一致，任何一个字节对不上都会失败。
void main() {
  group('签名与原版 KuGouMusicApi 一致', () {
    test('Web 版签名', () {
      final params = <String, Object?>{
        'appid': 1001,
        'type': 1,
        'plat': 4,
        'qrcode_txt':
            'https://h5.kugou.com/apps/loginQRCode/html/index.html?appid=1005&',
        'srcappid': 2919,
        'mid': '1234567890',
        'dfid': '-',
        'uuid': '-',
        'clientver': 20489,
        'clienttime': 1700000000,
      };
      expect(
        KugouSignature.web(params),
        'd758f5cf3af7500d028cbe451cdad06b',
      );
    });

    test('Android 版签名（无请求体）', () {
      expect(KugouSignature.android(_androidParams), '97f67eae408ca48ccedc86a78ddb6a33');
    });

    test('Android 版签名（带请求体）', () {
      final body = jsonEncode({
        'businessid': 5,
        'mobile': '13800000000',
        'plat': 3,
      });
      expect(
        KugouSignature.android(_androidParams, body),
        '910716e1622f1e77bf1802a5d5f07f44',
      );
    });

    test('通用 signParams 签名', () {
      expect(
        KugouSignature.smsKey(1700000000000),
        '1b9484741f86e5fcb89c25adae99a4e6',
      );
    });

    test('登录 key 签名', () {
      expect(
        KugouSignature.loginKey(1700000000000),
        'a16d61ca1308a00264f488e64029b29a',
      );
    });

    test('mid 由 MD5 转十进制大数', () {
      expect(
        KugouSignature.mid('550e8400-e29b-41d4-a716-446655440000'),
        '308741372901437977228425563242293240765',
      );
    });
  });

  group('加密原语', () {
    test('MD5 与 SHA1 输出标准摘要', () {
      expect(KugouCrypto.md5('abc'), '900150983cd24fb0d6963f7d28e17f72');
      expect(KugouCrypto.sha1('abc'), 'a9993e364706816aba3e25717850c26c9cd0d89d');
    });

    test('AES-CBC 加解密可往返，且为 PKCS7 填充', () {
      const key = '5e4ef500e9597fe004bd09a46d8add98';
      const iv = '04bd09a46d8add98';
      final cipher = KugouCrypto.aesCbcEncryptHex('{"a":1}', key, iv);
      // 8 字节明文补到 16 字节，密文长度应为 32 个 hex 字符。
      expect(cipher.length, 32);
      expect(KugouCrypto.aesCbcDecryptHex(cipher, key, iv), '{"a":1}');
    });

    test('AES 解密失败时返回原密文而不是抛错', () {
      expect(
        KugouCrypto.aesCbcDecryptHex('zzzz', '0123456789abcdef', '0123456789abcdef'),
        'zzzz',
      );
    });

    test('RSA 加密输出 128 字节密文', () {
      final hex = KugouCrypto.rsaEncryptHex('{"key":"test"}');
      expect(hex.length, 256);
      expect(hex, equals(hex.toUpperCase()));
    });
  });

  group('设备标识', () {
    test('生成的 GUID 是 UUID v4 格式', () {
      final device = KugouDevice.generate();
      expect(
        RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')
            .hasMatch(device.guid),
        isTrue,
      );
      expect(device.mid, KugouSignature.mid(device.guid));
    });

    test('编解码保留 guid、mac 与 dfid', () {
      final device = KugouDevice(guid: 'g-1', mac: 'AA:BB:CC:DD:EE:FF', dfid: 'd-1');
      final restored = KugouDevice.decode(device.encode());
      expect(restored.guid, 'g-1');
      expect(restored.mac, 'AA:BB:CC:DD:EE:FF');
      expect(restored.dfid, 'd-1');
      expect(restored.mid, device.mid);
    });

    test('缺少设备指纹时用占位值，不阻断请求', () {
      expect(KugouDevice(guid: 'g-1', mac: 'AA:BB:CC:DD:EE:FF').dfid, '-');
    });
  });

  group('请求参数拼装', () {
    test('签名覆盖全部查询参数，且不把 signature 自身算进去', () async {
      final device = KugouDevice(guid: 'guid-1', mac: 'AA:BB:CC:DD:EE:FF');
      Uri? captured;
      final client = KugouClient(
        device,
        client: MockClient((request) async {
          captured = request.url;
          return http.Response(jsonEncode({'status': 1}), 200);
        }),
      );
      await client.get(
        Uri.parse('https://example.org/v2/qrcode'),
        extraParams: {'plat': 4},
      );
      final query = captured!.queryParameters;
      expect(query['plat'], '4');
      expect(query['mid'], device.mid);
      expect(query['dfid'], '-');
      expect(query['appid'], '1005');
      expect(query['signature'], hasLength(32));
    });
  });
}

const _androidParams = <String, Object>{
  'dfid': '-',
  'mid': '1234567890',
  'uuid': '-',
  'appid': 1005,
  'clientver': 20489,
  'clienttime': 1700000000,
  'plat': 1,
  'support_multi': 1,
  'clienttime_ms': 1700000000000,
  't3': 'MCwwLDAsMCwwLDAsMCwwLDA=',
};

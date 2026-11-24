import 'dart:convert';
import 'dart:math';

import 'crypto.dart';

/// 请求酷狗接口时用到的签名与设备标识。
///
/// 对应 KuGouMusicApi 的 `util/helper.js` 与 `util/util.js`。所有算法都是
/// 纯字符串拼接后取 MD5，没有 Node 特有依赖，因此可以逐条移植。
class KugouSignature {
  KugouSignature._();

  /// 各接口共用的客户端常量，取自 KuGouMusicApi 的 `util/config.json`。
  static const appid = 1005;
  static const clientver = 20489;
  static const srcappid = 2919;
  static const liteAppid = 3116;
  static const liteClientver = 11440;

  static const _webSalt = 'NVPh5oo715z5DIWAeQlhMDsWXXQV4hwt';

  /// Android 版签名盐。云歌单协议（cloudlist）把同一个值当作 `appkey` 用，
  /// 所以不能保持私有。
  static const androidSalt = 'OIlwieks28dk2k092lksi2UIkp';

  static const _androidSalt = androidSalt;
  static const _liteAndroidSalt = 'LnT6xpN3khm36zse0QzvmgTZ3waWdRSA';

  static const _signParamsSalt = 'R6snCXJgbCaj9WFRJKefTMIFp0ey6Gza';
  static const _randomAlphabet = '1234567890ABCDEFGHIJKLMNOPQRSTUVWXYZ';

  /// Web 版签名：`MD5(盐 + 按 key 排序的 k=v 串 + 请求体 + 盐)`。
  static String web(Map<String, Object?> params, [String data = '']) {
    final sorted = params.keys.toList()..sort();
    final joined = sorted.map((key) => '$key=${params[key]}').join();
    return KugouCrypto.md5('$_webSalt$joined$data$_webSalt');
  }

  /// Android 版签名：规则同 Web，但盐值不同，且对象值先 JSON 序列化。
  static String android(Map<String, Object?> params, [String data = '']) =>
      _android(params, data, _androidSalt);

  static String liteAndroid(Map<String, Object?> params, [String data = '']) =>
      _android(params, data, _liteAndroidSalt);

  static String _android(Map<String, Object?> params, String data, String salt) {
    final sorted = params.keys.toList()..sort();
    final joined = sorted
        .map((key) {
          final value = params[key];
          return '$key=${value is Map || value is List ? jsonEncode(value) : value ?? ''}';
        })
        .join();
    return KugouCrypto.md5('$salt$joined$data$salt');
  }

  /// 登录接口 `key` 参数：`MD5(appid + 盐 + clientver + 时间戳)`。
  static String loginKey(int clienttimeMs, {bool lite = false}) => KugouCrypto.md5(
    lite
        ? '$liteAppid$_liteAndroidSalt$liteClientver$clienttimeMs'
        : '$appid$_androidSalt$clientver$clienttimeMs',
  );

  /// 手机号验证码接口 `key` 参数，规则同上但盐值是 H5 签名盐。
  static String smsKey(int clienttimeMs) =>
      KugouCrypto.md5('$appid$_signParamsSalt$clientver$clienttimeMs');

  /// 设备注册接口签名：只取参数**值**排序拼接，两侧各加盐 `1014`。
  ///
  /// 对应 KuGouMusicApi 的 `signatureRegisterParams`。这里传的是查询参数表，
  /// 不要包含 `signature` 自身。
  static String register(Map<String, Object?> params) {
    final values = params.values.map((value) => '$value').toList()..sort();
    return KugouCrypto.md5('$_registerSalt${values.join()}$_registerSalt');
  }

  static const _registerSalt = '1014';

  /// 取播放地址时 tracker 的 `key`，哈希大小写要和请求参数完全一致。
  ///
  /// 对应 KuGouMusicApi `helper.js` 的 `signKey`（标准版盐值）。这个值错了
  /// 服务端只回一句 `invalid sign`，不会指出是哪个字段，所以单独留个具名方法
  /// 免得和别的 MD5 混在一起。
  static String trackerKey({
    required String hash,
    required String mid,
    int userid = 0,
    bool lite = false,
  }) => KugouCrypto.md5(
    lite ? '$hash$_liteTrackerSalt$liteAppid$mid$userid' : '$hash$_trackerSalt$appid$mid$userid',
  );

  static const _trackerSalt = '57ae12eb6890223e355ccfcb74edf70d';
  static const _liteTrackerSalt = '185672dd44712f60bb1736df5a377e82';

  static String randomString(int length, {Random? random}) {
    final source = random ?? Random.secure();
    return List.generate(
      length,
      (_) => _randomAlphabet[source.nextInt(_randomAlphabet.length)],
    ).join();
  }

  /// UUID v4，用作设备 GUID。
  static String uuidV4({Random? random}) {
    final source = random ?? Random.secure();
    final hex = List.generate(32, (_) => source.nextInt(16).toRadixString(16)).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-4'
        '${hex.substring(13, 16)}-'
        '${(8 + source.nextInt(4)).toRadixString(16)}${hex.substring(17, 20)}-'
        '${hex.substring(20, 32)}';
  }

  /// `mid`：把 MD5 摘要当成 16 进制大数转成十进制字符串。
  static String mid(String guid) {
    var value = BigInt.zero;
    final digest = KugouCrypto.md5(guid);
    for (var i = 0; i < digest.length; i++) {
      value = value * BigInt.from(16) + BigInt.parse(digest[i], radix: 16);
    }
    return value.toString();
  }
}

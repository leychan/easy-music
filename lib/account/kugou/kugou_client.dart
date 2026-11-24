import 'dart:async';
import 'dart:convert';
import 'dart:io' show HandshakeException;
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'crypto.dart';
import 'kugou_auth.dart' show KugouFailure, KugouSession;
import 'kugou_device.dart';
import 'signature.dart';

/// 酷狗网关的请求与响应约定。
///
/// 对应 KuGouMusicApi 的 `util/request.js`：每个请求都要带上设备标识、
/// 时间戳和签名，否则服务端返回的状态码无法用于判断业务结果。
class KugouClient {
  KugouClient(this.device, {http.Client? client})
    : _client = client ?? http.Client();

  final KugouDevice device;
  final http.Client _client;

  /// 当前登录信息。设置后所有请求都会带上 `token`/`userid`，
  /// 未登录时保持 null 也能访问搜索、取播放地址等公开接口。
  KugouSession? session;

  bool get isLite => session?.lite ?? false;
  int get appid => isLite ? KugouSignature.liteAppid : KugouSignature.appid;
  int get clientver => isLite ? KugouSignature.liteClientver : KugouSignature.clientver;

  /// 各接口要求的 User-Agent 不同，默认用厂商发现的 Android 客户端 UA。
  ///
  /// 搜索、联想、每日推荐这类内容接口对这个 UA 敏感：换成 H5 的
  /// `Mozilla/5.0` 会走另一条校验分支，直接返回 `err signature`。
  static const _defaultUserAgent =
      'Android15-1070-11083-46-0-DiscoveryDRADProtocol-wifi';

  /// 发送 Android 版签名的请求。
  ///
  /// [extraParams] 会与默认参数合并后一起参与签名，因此调用方不要再自行加签。
  Future<Map<String, dynamic>> get(
    Uri url, {
    Map<String, Object?> extraParams = const {},
    String? userAgent,
    Map<String, String> headers = const {},
    bool? lite,
    Duration timeout = const Duration(seconds: 15),
  }) => _send(
    'GET',
    url,
    extraParams: extraParams,
    userAgent: userAgent,
    extraHeaders: headers,
    lite: lite,
    timeout: timeout,
  );

  /// 扫码登录使用 H5 签名和独立的未登录请求。
  Future<Map<String, dynamic>> webGet(
    Uri url, {
    required Map<String, Object?> extraParams,
    bool lite = false,
  }) => _send(
    'GET',
    url,
    extraParams: extraParams,
    includeSession: false,
    webSignature: true,
    lite: lite,
    timeout: const Duration(seconds: 15),
  );

  Future<Map<String, dynamic>> post(
    Uri url, {
    Map<String, Object?> extraParams = const {},
    Object? body,
    String? userAgent,
    Map<String, String> headers = const {},
    bool includeSession = true,
    bool? lite,
    Duration timeout = const Duration(seconds: 15),
  }) => _send(
    'POST',
    url,
    extraParams: extraParams,
    body: body,
    userAgent: userAgent,
    extraHeaders: headers,
    includeSession: includeSession,
    lite: lite,
    timeout: timeout,
  );

  /// 云歌单服务（cloudlist）专用请求。
  ///
  /// 这个服务**不接受**普通 Android 签名：token 明文放在查询参数里会被判
  /// 成「token 无效」（`20017`），哪怕这个 token 在 `usercenter` 上完全可用。
  /// 它走一套独立的会话加密协议（见 KuGouMusicApi `util/request.js` 的
  /// `createCloudRequest`）：
  ///
  /// - `key = MD5(appid + appkey + clientver + clienttime)`，appkey 就是
  ///   标准版签名盐 [KugouSignature.androidSalt]；
  /// - `p = RSA({"aes": 6位随机串, "uid": userid, "token": token})`，
  ///   token 藏在这里，这是服务端唯一认的凭证来源；
  /// - 请求体用 AES-CBC 加密，key/iv 取自那个随机串的 MD5；
  /// - 响应同样是 AES 密文，需要解密；服务端偶尔回明文，要能回退。
  ///
  /// 缺了 `p` 里的 token 只会得到 `20017`，报错信息不会提示原因，
  /// 所以这里把整套协议完整实现，而不是复用 [_send]。
  Future<Map<String, dynamic>> cloudPost(
    Uri url, {
    required Map<String, Object?> body,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final session = this.session;
    final clienttime = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final storage = url.host == 'mcloudservice.kugou.com';
    // 云盘跟随登录版本，cloudlist 的 /v1/modify_* 始终使用标准版加密协议。
    final lite = storage && isLite;

    // 6 位会话串 -> MD5 -> 前 16 位作 AES key、后 16 位作 iv。
    final nonce = KugouSignature.randomString(6);
    final aes = storage ? nonce.toLowerCase() : nonce;
    final digest = KugouCrypto.md5(aes);

    // 音乐云盘使用 Android 客户端参数签名，和短信登录的 H5 签名不同。
    final key = KugouSignature.loginKey(clienttime, lite: lite);

    final portrait = KugouCrypto.rsaEncryptPkcs1(
      jsonEncode({
        'aes': aes,
        'uid': storage ? '${session?.userid ?? 0}' : session?.userid ?? 0,
        'token': session?.token ?? '',
      }),
      lite: lite,
    );

    final params = <String, Object?>{
      'appid': lite ? KugouSignature.liteAppid : KugouSignature.appid,
      'clientver': lite ? KugouSignature.liteClientver : KugouSignature.clientver,
      'mid': device.mid,
      'clienttime': clienttime,
      'key': key,
      if (!storage) 'dfid': device.dfid,
      'p': portrait,
    };

    final plain = jsonEncode(body);
    final cipherHex = KugouCrypto.aesCbcEncryptHex(
      plain,
      digest.substring(0, 16),
      digest.substring(16, 32),
    );
    final cipher = Uint8List.fromList(
      List.generate(
        cipherHex.length ~/ 2,
        (index) => int.parse(
          cipherHex.substring(index * 2, index * 2 + 2),
          radix: 16,
        ),
      ),
    );

    final target = url.replace(
      queryParameters: {
        ...url.queryParameters,
        ...params.map((k, v) => MapEntry(k, '$v')),
      },
    );

    final request = http.Request('POST', target)
      ..headers.addAll({
        'user-agent': _defaultUserAgent,
        'content-type': 'application/json;charset=utf-8',
        if (!storage) 'x-router': 'cloudlist.service.kugou.com',
        'dfid': device.dfid,
        'mid': device.mid,
        'clienttime': '$clienttime',
        'kg-rc': '1',
        'kg-thash': '5d816a0',
        'kg-rec': '1',
        'kg-rf': 'B9EDA08A64250DEFFBCADDEE00F8F25F',
      })
      ..bodyBytes = cipher;

    http.Response response;
    try {
      response = await _client.send(request).then(http.Response.fromStream).timeout(timeout);
    } on TimeoutException {
      throw const KugouFailure('连接酷狗服务器超时，请检查网络后重试。');
    } on http.ClientException catch (error) {
      throw KugouFailure(_networkMessage(error));
    } on HandshakeException {
      throw const KugouFailure('与酷狗服务器的加密连接失败，请检查系统时间或网络代理。');
    }

    // 先按 AES 解密；服务端未加密时直接当明文解析。
    final decrypted = KugouCrypto.aesCbcDecryptBytes(
      response.bodyBytes,
      digest.substring(0, 16),
      digest.substring(16, 32),
    );
    if (decrypted.isNotEmpty) {
      try {
        final decoded = jsonDecode(decrypted);
        if (decoded is Map<String, dynamic>) return decoded;
      } on FormatException {
        // 明文响应可能碰巧满足 AES 填充条件，仍按普通 JSON 解析一次。
      }
    }
    return _decode(response);
  }

  /// 发请求但返回原始字节。[signature] 指定签名算法，`register` 用设备注册
  /// 的那套规则（只对参数值排序拼接，盐值 `1014`）。
  ///
  /// 设备注册接口的响应是 AES 密文的 base64，不能按 JSON 解析，
  /// 所以单独留一个不解码的出口。
  Future<Uint8List> postRaw(
    Uri url, {
    Map<String, Object?> extraParams = const {},
    required String body,
    required String signature,
    String? userAgent,
    Map<String, String> headers = const {},
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final clienttime = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final query = <String, Object?>{
      'dfid': device.dfid,
      'mid': device.mid,
      'uuid': '-',
      'appid': KugouSignature.appid,
      'clientver': KugouSignature.clientver,
      'clienttime': clienttime,
      ...extraParams,
      'signature': signature,
    };
    final target = url.replace(
      queryParameters: {
        ...url.queryParameters,
        ...query.map((key, value) => MapEntry(key, '$value')),
      },
    );
    final request = http.Request('POST', target)
      ..headers.addAll({
        'user-agent': userAgent ?? _defaultUserAgent,
        'content-type': 'application/json;charset=utf-8',
        'dfid': device.dfid,
        'mid': device.mid,
        'clienttime': '$clienttime',
        'kg-rc': '1',
        'kg-thash': '5d816a0',
        'kg-rec': '1',
        'kg-rf': 'B9EDA08A64250DEFFBCADDEE00F8F25F',
        ...headers,
      })
      ..body = body;
    try {
      final response = await http.Response.fromStream(
        await _client.send(request),
      ).timeout(timeout);
      if (response.statusCode >= 400) {
        throw const KugouFailure('酷狗服务器暂时不可用，请稍后重试。');
      }
      return response.bodyBytes;
    } on TimeoutException {
      throw const KugouFailure('连接酷狗服务器超时，请检查网络后重试。');
    } on http.ClientException catch (error) {
      throw KugouFailure(_networkMessage(error));
    } on HandshakeException {
      throw const KugouFailure('与酷狗服务器的加密连接失败，请检查系统时间或网络代理。');
    }
  }

  Future<Map<String, dynamic>> _send(
    String method,
    Uri url, {
    required Map<String, Object?> extraParams,
    Object? body,
    String? userAgent,
    Map<String, String> extraHeaders = const {},
    bool includeSession = true,
    bool webSignature = false,
    bool? lite,
    required Duration timeout,
  }) async {
    final clienttime = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final credentials = includeSession ? session : null;
    final useLite = lite ?? credentials?.lite ?? false;
    final params = <String, Object?>{
      'dfid': device.dfid,
      'mid': device.mid,
      'uuid': '-',
      'appid': useLite ? KugouSignature.liteAppid : KugouSignature.appid,
      'clientver': useLite ? KugouSignature.liteClientver : KugouSignature.clientver,
      'clienttime': clienttime,
      // 登录后酷狗按 token 判断账号与会员权限，未登录时不要带空串。
      if (credentials != null) ...{
        'token': credentials.token,
        'userid': credentials.userid,
      },
      ...extraParams,
    };

    final payload = body == null ? '' : jsonEncode(body);
    params['signature'] = webSignature
        ? KugouSignature.web(params, payload)
        : (useLite ? KugouSignature.liteAndroid : KugouSignature.android)(params, payload);

    final query = params.map(
      (key, value) => MapEntry(key, value is Map || value is List ? jsonEncode(value) : '$value'),
    );
    // Uri.queryParameters 会把空值写成裸键。酷狗签名校验按 key=value 取参数，
    // 所以 module= 等空值也要带等号，保证实际请求与签名一致。
    final encodedQuery = {...url.queryParameters, ...query}.entries.map((entry) {
      final key = Uri.encodeQueryComponent(entry.key);
      final value = Uri.encodeQueryComponent(entry.value);
      return '$key=$value';
    }).join('&');
    final target = url.replace(query: encodedQuery);

    final request = http.Request(method, target)
      ..headers.addAll({
        'user-agent': userAgent ?? _defaultUserAgent,
        'dfid': device.dfid,
        'mid': device.mid,
        'clienttime': '$clienttime',
        'kg-rc': '1',
        'kg-thash': '5d816a0',
        'kg-rec': '1',
        'kg-rf': 'B9EDA08A64250DEFFBCADDEE00F8F25F',
        ...extraHeaders,
      });
    if (body != null) {
      request.headers['content-type'] = 'application/json;charset=utf-8';
      request.body = payload;
    }

    http.Response response;
    try {
      response = await _client
          .send(request)
          .then(http.Response.fromStream)
          .timeout(timeout);
    } on TimeoutException {
      throw const KugouFailure('连接酷狗服务器超时，请检查网络后重试。');
    } on http.ClientException catch (error) {
      throw KugouFailure(_networkMessage(error));
    } on HandshakeException {
      throw const KugouFailure('与酷狗服务器的加密连接失败，请检查系统时间或网络代理。');
    }

    return _decode(response);
  }

  /// 把底层网络异常翻译成用户能理解的话，同时保留 TLS 失败这一独立原因，
  /// 否则证书问题会被笼统地报成“检查网络设置”，非常难排查。
  static String _networkMessage(http.ClientException error) {
    if (error.message.contains('Handshake')) {
      return '与酷狗服务器的加密连接失败，请检查系统时间或网络代理。';
    }
    return '无法连接酷狗服务器，请检查网络设置。';
  }

  Map<String, dynamic> _decode(http.Response response) {
    // 先解 JSON 再看状态码：酷狗会把有意义的业务结果塞进 5xx 响应，
    // 例如「手机号绑了多个账号」就是 HTTP 502 + error_code 34175。
    // 先按状态码失败会把这类结果连同 info_list 一起丢掉。
    Object? decoded;
    var parsed = false;
    try {
      decoded = jsonDecode(utf8.decode(response.bodyBytes));
      parsed = decoded is Map<String, dynamic>;
    } on FormatException {
      parsed = false;
    }

    if (parsed) return decoded as Map<String, dynamic>;

    if (response.statusCode >= 500) {
      throw const KugouFailure('酷狗服务器暂时不可用，请稍后重试。');
    }
    throw const KugouFailure('酷狗服务器返回了无法识别的数据。');
  }

  /// AES-128-CBC 加密，供登录接口拼装加密字段。
  static String aesEncrypt(String plain, String key, String iv) =>
      KugouCrypto.aesCbcEncryptHex(plain, key, iv);

  static String aesDecrypt(String cipherHex, String key, String iv) =>
      KugouCrypto.aesCbcDecryptHex(cipherHex, key, iv);

  static String rsaEncrypt(String plain) => KugouCrypto.rsaEncryptHex(plain);

  /// 用本次登录请求的种子解开 `secu_params`，解密失败时返回空凭证。
  static Map<String, dynamic> decryptSecuParams(Object? value, String seed) {
    if (value is! String || value.isEmpty) return const {};
    final plain = KugouCrypto.aesDecryptHexWithSeed(value, seed);
    if (plain == null || plain.trim().isEmpty) return const {};
    try {
      final decoded = jsonDecode(plain);
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is String && decoded.trim().isNotEmpty) {
        return {'token': decoded};
      }
      return const {};
    } on FormatException {
      // 酷狗也会直接加密裸 token，不一定包成 JSON。
      return {'token': plain};
    }
  }

  void close() => _client.close();
}

/// 把接口返回的原始字节交给调用方（二维码图片等）。
typedef KugouBytes = Uint8List;

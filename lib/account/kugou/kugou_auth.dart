import 'dart:convert';

import 'crypto.dart';
import 'kugou_client.dart';
import 'signature.dart';

// 酷狗会在不同接口中交替使用数字和数字字符串。
int? _responseInt(Object? value) => switch (value) {
  num number => number.toInt(),
  String text => int.tryParse(text.trim()),
  _ => null,
};

String? _responseText(Object? value) =>
    value is String && value.trim().isNotEmpty ? value : null;

/// 酷狗登录成功后的账号凭证。
class KugouSession {
  const KugouSession({
    required this.userid,
    required this.token,
    required this.nickname,
    required this.avatar,
    this.vipType = 0,
    this.mobile,
    this.lite = false,
  });

  final int userid;
  final String token;
  final String nickname;
  final String avatar;
  final int vipType;
  final String? mobile;
  final bool lite;

  Map<String, Object?> toJson() => {
    'userid': userid,
    'token': token,
    'nickname': nickname,
    'avatar': avatar,
    'vipType': vipType,
    if (lite) 'lite': true,
    if (mobile != null) 'mobile': mobile,
  };

  static KugouSession fromJson(Map<String, dynamic> json) => KugouSession(
    userid: (json['userid'] as num?)?.toInt() ?? 0,
    token: json['token'] as String? ?? '',
    nickname: json['nickname'] as String? ?? '',
    avatar: json['avatar'] as String? ?? '',
    vipType: (json['vipType'] as num?)?.toInt() ?? 0,
    mobile: json['mobile'] as String?,
    lite: json['lite'] == true,
  );
}

/// 扫码状态。酷狗用 0/1/2/4 表示，其余值视为未知。
enum QrLoginState {
  waiting,

  /// 已扫码，等待手机上确认。
  scanned,

  /// 授权成功，[KugouLoginResult.session] 可用。
  authorized,

  expired,
}

class KugouLoginResult {
  const KugouLoginResult({required this.state, this.session});

  final QrLoginState state;
  final KugouSession? session;
}

/// 手机号绑定了多个酷狗账号时，服务端返回的可选账号。
///
/// 酷狗对这类手机号不直接登录，而是返回 `error_code: 34175` 和一串账号，
/// 要客户端选一个再带上 `userid` 重新提交（同一组 mobile + code 仍然有效）。
class KugouAccountOption {
  const KugouAccountOption({
    required this.userid,
    required this.nickname,
    this.avatar = '',
    this.username = '',
  });

  final int userid;
  final String nickname;
  final String avatar;

  /// 掩码后的手机号，如 `13*****0`。
  final String username;

  /// 展示用名称：昵称为空时退回手机号或 UID，避免出现空白项。
  String get label =>
      nickname.isNotEmpty ? nickname : (username.isNotEmpty ? username : '$userid');

  static KugouAccountOption? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final userid = _responseInt(raw['userid']) ?? 0;
    if (userid <= 0) return null;
    return KugouAccountOption(
      userid: userid,
      nickname: _responseText(raw['nickname']) ?? '',
      avatar: _responseText(raw['pic']) ?? '',
      username: _responseText(raw['username']) ?? '',
    );
  }
}

/// 登录被服务端拒绝。[message] 可直接展示给用户。
class KugouFailure implements Exception {
  const KugouFailure(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 服务端**明确**判定登录凭证无效。
///
/// 与普通 [KugouFailure] 区分开：普通失败（网络、解析、接口下线）不应该
/// 清掉本地凭证，只有这个异常才表示「真的要去重新登录」。
class KugouSessionExpired extends KugouFailure {
  const KugouSessionExpired([super.message = '登录已失效，请重新登录。']);
}

/// 活动接口拒绝当前登录。账号本身是否过期仍由资料接口确认。
class DailyVipAuthorizationExpired extends KugouFailure {
  const DailyVipAuthorizationExpired() : super('签到接口未接受概念版登录，请重新登录。');
}

/// 该手机号下有多个账号，需要用户选一个。
///
/// 这不属于失败：验证码已经校验通过了，只差指定要用哪个账号。
class KugouMultiAccount extends KugouFailure {
  const KugouMultiAccount(this.accounts, String message) : super(message);

  final List<KugouAccountOption> accounts;
}

/// 直接调用酷狗官方登录接口。
///
/// 对应 KuGouMusicApi 的 `module/login_*.js`。不经过任何自建授权服务：
/// 应用自己计算签名、自己保存酷狗返回的 token。
class KugouAuth {
  KugouAuth(this.client);

  final KugouClient client;

  static const _loginUser = 'https://login-user.kugou.com';
  static const _loginRetry = 'https://loginserviceretry.kugou.com';
  static const _gateway = 'https://gateway.kugou.com';

  /// 通过概念版的当日领取接口申请活动奖励，资格以服务端结果为准。
  Future<void> claimDailyVip(KugouSession authorization, {required String day}) async {
    final result = await client.post(
      Uri.parse('$_gateway/youth/v1/recharge/receive_vip_listen_song'),
      lite: true,
      includeSession: false,
      extraParams: {
        'userid': authorization.userid,
        'token': authorization.token,
        'source_id': 90139,
        'receive_day': day,
      },
      body: {'receive_day': day},
      userAgent: 'Android15-1070-11440-46-0-ReportPlaySongToServerProtocol-wifi',
    );
    _checkVipResponse(result, '酷狗未确认今日畅听 VIP 领取', alreadyDone: const {131001});
  }

  Future<void> upgradeDailyVip(KugouSession session) async {
    final result = await client.post(
      Uri.parse('$_gateway/youth/v1/listen_song/upgrade_vip_reward'),
      lite: true,
      includeSession: false,
      extraParams: {
        'userid': session.userid,
        'token': session.token,
        'kugouid': session.userid,
        'ad_type': 1,
      },
    );
    _checkVipResponse(result, '酷狗未确认概念版 VIP 升级', alreadyDone: const {20030, 131001});
  }

  void _checkVipResponse(Map<String, dynamic> result, String failure, {required Set<int> alreadyDone}) {
    final status = _responseInt(result['status']);
    final code = _responseInt(result['error_code']);
    if (alreadyDone.contains(code) ||
        (status == 1 && (code == null || code == 0)) ||
        (status == null && code == 0)) {
      return;
    }
    if (code == 51002 || code == 20017 || code == 20018) {
      throw const DailyVipAuthorizationExpired();
    }
    final message = _responseText(result['error_msg']) ??
        _responseText(result['msg']) ?? _responseText(result['message']);
    throw KugouFailure(message ?? (code == null ? '$failure。' : '$failure（错误码 $code）。'));
  }

  /// 验证码接口只有明文 HTTP 入口：同一主机名的 HTTPS 握手会直接失败，
  /// 换成其他域名则签名对不上。这里沿用官方客户端的做法。
  static final _captcha = Uri.parse('http://login.user.kugou.com/v7/send_mobile_code');

  // 手机号登录用的固定 AES 参数，取自 KuGouMusicApi 的 login_cellphone.js。
  static const _smsT2Key = 'fd14b35e3f81af3817a20ae7adae7020';
  static const _smsT2Iv = '17a20ae7adae7020';
  static const _smsT1Key = '5e4ef500e9597fe004bd09a46d8add98';
  static const _smsT1Iv = '04bd09a46d8add98';

  /// 设备指纹常量，酷狗客户端里固定不变。
  static const _deviceFingerprint = '0f607264fc6318a92b9e13c65db7cd3c';

  /// 登录请求的 `t1`/`t2` 字段。
  ///
  /// 服务端把这两个字段当作**必填**：缺任意一个都直接返回 20010，看起来像
  /// “参数错误”或“登录失败”，极难联想到是缺字段。补上后才会进入真正的
  /// 业务校验（验证码错误时返回 20021）。
  ///
  /// `t1/t2` 是登录风控用的加密时间戳：`t1` 只含时间，`t2` 还带 guid、固定
  /// 指纹、MAC 与平台串，都用各自的固定 key/iv 加密。
  ({String t1, String t2}) _loginTimestamps(int clienttimeMs, {bool lite = false}) {
    final device = lite ? client.device.guid : 'android';
    final t2 = KugouCrypto.aesCbcEncryptHex(
      '${client.device.guid}|$_deviceFingerprint|${client.device.mac}|$device|$clienttimeMs',
      _smsT2Key,
      _smsT2Iv,
    );
    final t1 = KugouCrypto.aesCbcEncryptHex('|$clienttimeMs', _smsT1Key, _smsT1Iv);
    return (t1: t1, t2: t2);
  }

  /// 申请二维码。[type] 为 `web` 时使用 H5 的 appid，扫码后跳网页授权。
  Future<String> requestQrCode({bool web = false, bool lite = false}) async {
    final json = await client.webGet(
      Uri.parse('$_loginUser/v2/qrcode'),
      lite: lite,
      extraParams: {
        'appid': web ? 1014 : 1001,
        'type': 1,
        'plat': 4,
        'qrcode_txt':
            'https://h5.kugou.com/apps/loginQRCode/html/index.html'
            '?appid=${lite ? KugouSignature.liteAppid : KugouSignature.appid}&',
        'srcappid': KugouSignature.srcappid,
      },
    );
    final data = json['data'];
    final key = data is Map<String, dynamic>
        ? (data['qrcode'] ?? data['key'])
        : null;
    if (key is! String || key.isEmpty) {
      throw KugouFailure(_messageOf(json) ?? '酷狗没有返回可用的二维码，请稍后重试。');
    }
    return key;
  }

  /// 二维码内容。酷狗官方 H5 页面负责渲染，这里只给出待编码的文本。
  static String qrContent(String key) => Uri.https(
    'h5.kugou.com',
    '/apps/loginQRCode/html/index.html',
    {'qrcode': key},
  ).toString();

  Future<KugouLoginResult> checkQrCode(String key, {bool lite = false}) async {
    final json = await client.webGet(
      Uri.parse('$_loginUser/v2/get_userinfo_qrcode'),
      lite: lite,
      extraParams: {
        'plat': 4,
        'appid': lite ? KugouSignature.liteAppid : KugouSignature.appid,
        'srcappid': KugouSignature.srcappid,
        'qrcode': key,
        'dev': client.device.guid,
      },
    );
    final data = json['data'];
    if (data is! Map<String, dynamic>) {
      throw const KugouFailure('酷狗返回的扫码状态无法识别。');
    }
    final status = _responseInt(data['status']) ?? 0;
    return switch (status) {
      4 => KugouLoginResult(
        state: QrLoginState.authorized,
        session: _sessionFromData(data, lite: lite),
      ),
      2 => const KugouLoginResult(state: QrLoginState.scanned),
      1 => const KugouLoginResult(state: QrLoginState.waiting),
      _ => const KugouLoginResult(state: QrLoginState.expired),
    };
  }

  /// 发送短信验证码。返回服务端给出的剩余可发送次数（拿不到时返回 null）。
  Future<int?> sendSmsCode(String mobile, {bool lite = false}) async {
    _validateMobile(mobile);
    final json = await client.post(
      _captcha,
      body: {'businessid': 5, 'mobile': mobile, 'plat': 3},
      // 发码接口仍走 HTTP，不能把已有会话的凭证带过去。
      includeSession: false,
      lite: lite,
    );
    if (_responseInt(json['status']) == 1) {
      final data = json['data'];
      return data is Map ? _responseInt(data['count']) : null;
    }
    throw KugouFailure(_messageOf(json) ?? '验证码发送失败，请稍后重试。');
  }

  /// 用验证码登录。
  ///
  /// [userid] 只在「一个手机号绑了多个账号」时传入：首次提交会抛
  /// [KugouMultiAccount] 并给出账号列表，用户选定后带上该 userid 重登，
  /// 此时同一组手机号与验证码仍然有效。
  Future<KugouSession> loginWithSms(
    String mobile,
    String code, {
    int? userid,
    bool lite = false,
  }) async {
    _validateMobile(mobile);
    if (!RegExp(r'^\d{4,6}$').hasMatch(code)) {
      throw const KugouFailure('请输入收到的验证码。');
    }
    final encrypted = KugouCrypto.aesEncryptWithSeed(
      jsonEncode({'mobile': mobile, 'code': code}),
    );
    final now = DateTime.now().millisecondsSinceEpoch;
    final stamps = _loginTimestamps(now, lite: lite);
    final body = <String, Object?>{
      'plat': 1,
      'support_multi': 1,
      'clienttime_ms': now,
      'mobile': '${mobile.substring(0, 2)}*****${mobile.substring(10, 11)}',
      'key': lite ? KugouSignature.loginKey(now, lite: true) : KugouSignature.smsKey(now),
      'pk': KugouCrypto.rsaEncryptHex(
        jsonEncode({'clienttime_ms': now, 'key': encrypted.key}),
        lite: lite,
      ),
      'params': encrypted.cipher,
      // t1/t2 必填，缺任意一个都是 20010。
      't1': stamps.t1,
      't2': stamps.t2,
      'dev': client.device.guid,
      if (lite) 'dfid': client.device.dfid,
      'gitversion': '5f0b7c4',
      if (userid != null && userid > 0) 'userid': userid,
    };
    final json = await client.post(
      Uri.parse('$_loginRetry/v7/login_by_verifycode'),
      body: body,
      userAgent: lite ? 'Android16-1070-11440-130-0-LOGIN-wifi' : 'Android16-1070-11489-130-0-LOGIN-wifi',
      headers: {'support-calm': '1'},
      includeSession: false,
      lite: lite,
    );
    _throwIfMultiAccount(json);
    return _sessionFromLogin(json, encrypted.key, mobile: mobile, lite: lite);
  }

  static void _validateMobile(String mobile) {
    if (!RegExp(r'^1\d{10}$').hasMatch(mobile)) {
      throw const KugouFailure('请输入 11 位手机号。');
    }
  }

  Future<KugouSession> loginWithPassword(String username, String password, {bool lite = false}) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final encrypted = KugouCrypto.aesEncryptWithSeed(
      jsonEncode({'pwd': password, 'code': '', 'clienttime_ms': now}),
    );
    final key = KugouSignature.loginKey(now, lite: lite);
    final stamps = _loginTimestamps(now, lite: lite);
    final body = <String, Object?>{
      'plat': 1,
      'support_multi': 1,
      'clienttime_ms': now,
      't1': stamps.t1,
      't2': stamps.t2,
      't3': 'MCwwLDAsMCwwLDAsMCwwLDA=',
      'dev': client.device.guid,
      'username': username,
      'key': key,
      'params': encrypted.cipher,
      'pk': KugouCrypto.rsaEncryptHex(
        jsonEncode({'clienttime_ms': now, 'key': encrypted.key}),
        lite: lite,
      ),
    };
    final json = await client.post(
      Uri.parse('$_gateway/v9/login_by_pwd'),
      body: body,
      userAgent: lite ? 'Android16-1070-11440-130-0-LOGIN-wifi' : 'Android16-1070-11489-130-0-LOGIN-wifi',
      headers: {'x-router': 'login.user.kugou.com'},
      includeSession: false,
      lite: lite,
    );
    return _sessionFromLogin(json, encrypted.key, lite: lite);
  }

  /// 检查响应是不是「手机号绑定了多个账号」。
  ///
  /// 酷狗用 `error_code: 34175` 表示这种情况（HTTP 状态码还可能是 502），
  /// `data.info_list` 里是可选账号。这不是失败，而是要求客户端选一个账号：
  /// 验证码本身已经校验通过了。
  void _throwIfMultiAccount(Map<String, dynamic> json) {
    if (_responseInt(json['error_code']) != multiAccountErrorCode) return;

    final accounts = _parseAccountList(json);
    if (accounts.isEmpty) {
      // 宁可提示“换种方式登录”，也不要把 34175 这种原始错误码丢给用户。
      throw const KugouFailure('该手机号下暂无可登录的账号，请换一种方式登录。');
    }
    throw KugouMultiAccount(
      accounts,
      '该手机号绑定了 ${accounts.length} 个酷狗账号，请选择要登录的账号。',
    );
  }

  /// 从响应里挖出可选账号列表。
  ///
  /// 这个结构没有官方文档，只从社区实现里确认过 `data.info_list` 一种形态。
  /// 因此这里递归找所有数组，只要里面能解析出账号就采用，避免因为放错一层
  /// 就丢掉列表。
  static List<KugouAccountOption> _parseAccountList(Map<String, dynamic> json) {
    for (final list in _collectLists(json, 0)) {
      final parsed = list
          .map(KugouAccountOption.tryParse)
          .whereType<KugouAccountOption>()
          .toList();
      if (parsed.isNotEmpty) return _dedupe(parsed);
    }
    return const [];
  }

  /// 按层序遍历收集所有数组，最多下探 [_maxDepth] 层。
  static Iterable<List<Object?>> _collectLists(Object? node, int depth) {
    if (depth > _maxDepth) return const [];
    final here = <List<Object?>>[];
    final children = <Object?>[];

    void walk(Object? value) {
      if (value is List) {
        here.add(value.cast<Object?>());
        children.addAll(value);
      } else if (value is Map) {
        children.addAll(value.values);
      }
    }

    walk(node);
    return [
      ...here,
      for (final child in children) ..._collectLists(child, depth + 1),
    ];
  }

  static const _maxDepth = 4;

  static List<KugouAccountOption> _dedupe(List<KugouAccountOption> items) {
    final seen = <int>{};
    return [
      for (final item in items)
        if (seen.add(item.userid)) item,
    ];
  }

  /// 手机号绑定多个账号时服务端返回的错误码。
  static const multiAccountErrorCode = 34175;

  /// 用 token 拉取账号资料，用于校验已保存的登录是否仍有效。
  ///
  /// 接口是 `/v3/get_my_info`，token 必须放进 RSA 加密的 `p` 里
  /// （对应上游 `module/user_detail.js`）。
  ///
  /// **不要换回 `/v1/user/detail`**：那个接口已经下线，网关直接回 404。
  /// 用了它的话 [fetchProfile] 会拿不到 data，而调用方把「拿不到 data」
  /// 理解成「token 失效」→ 把本地凭证删掉 → 表现为「登录莫名其妙没了，
  /// 歌单一直 20017」。实测 404 见 `tool/probe/profile_api.cjs`。
  Future<KugouSession?> fetchProfile(KugouSession session) async {
    final clienttime = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final pk = KugouCrypto.rsaEncryptHex(
      jsonEncode({'token': session.token, 'clienttime': clienttime}),
      lite: session.lite,
    ).toUpperCase();
    final json = await client.post(
      Uri.parse('$_gateway/v3/get_my_info'),
      body: {
        'visit_time': clienttime,
        'usertype': 1,
        'p': pk,
        'userid': session.userid,
      },
      extraParams: {'plat': 1, 'token': session.token, 'userid': session.userid},
      headers: {'x-router': 'usercenter.kugou.com'},
      lite: session.lite,
    );
    final data = json['data'];
    if (data is! Map<String, dynamic>) {
      // 服务端**明确**说凭证无效时抛这个专用异常，让调用方去清凭证。
      // 其他情况（字段改名、接口临时故障、空 data）一律返回 null，
      // 由调用方保守处理——绝不能因为一次解析不出来就把人踢下线，
      // 那正是「歌单一直 20017」的成因。
      final code = _responseInt(json['error_code']);
      if (code == 20017 || code == 20018 || code == 20019) {
        throw const KugouSessionExpired();
      }
      return null;
    }
    final nickname = _responseText(data['nickname']) ?? _responseText(data['username']);
    if (nickname == null) return null;
    return KugouSession(
      userid: _responseInt(data['userid']) ?? session.userid,
      token: session.token,
      nickname: nickname,
      avatar: _responseText(data['pic']) ?? session.avatar,
      vipType: _responseInt(data['vip_type']) ?? session.vipType,
      mobile: session.mobile,
      lite: session.lite,
    );
  }

  KugouSession _sessionFromLogin(
    Map<String, dynamic> json,
    String seed, {
    String? mobile,
    bool lite = false,
  }) {
    if (_responseInt(json['status']) != 1) {
      throw KugouFailure(_messageOf(json) ?? '登录失败，请检查账号信息后重试。');
    }
    final data = json['data'];
    if (data is! Map<String, dynamic>) {
      throw const KugouFailure('酷狗没有返回登录凭证。');
    }
    final secured = KugouClient.decryptSecuParams(data['secu_params'], seed);
    return _sessionFromData({...data, ...secured}, mobile: mobile, lite: lite);
  }

  KugouSession _sessionFromData(Map<String, dynamic> data, {String? mobile, bool lite = false}) {
    final token = _responseText(data['token']);
    final userid = _responseInt(data['userid']) ?? 0;
    if (token == null || userid <= 0) {
      throw const KugouFailure('酷狗没有返回完整的登录凭证。');
    }
    return KugouSession(
      userid: userid,
      token: token,
      nickname: _responseText(data['nickname']) ?? _responseText(data['username']) ?? '$userid',
      avatar: _responseText(data['pic']) ?? '',
      vipType: _responseInt(data['vip_type']) ?? 0,
      mobile: mobile,
      lite: lite,
    );
  }

  String? _messageOf(Map<String, dynamic> json) {
    for (final key in ['error', 'error_msg', 'msg', 'message']) {
      final value = json[key];
      if (value is String && value.isNotEmpty) return value;
    }
    // 酷狗常把人类可读的原因放在 data 里（如 "验证码过期"、"参数错误"）。
    final data = json['data'];
    if (data is String && data.isNotEmpty) return data;

    final error = _responseInt(json['error_code']);
    return error == null || error == 0 ? null : _explain(error);
  }

  /// 把酷狗的原始错误码翻译成用户能理解的说法。
  ///
  /// 这些码是实际探测出来的，官方文档只覆盖了极个别场景：
  /// 20010 是请求体缺字段（本项目的 `t1`/`t2` 就踩过），
  /// 20020 是验证码过期，20021 是验证码错误。
  static String _explain(int code) => switch (code) {
    20010 => '登录请求未被接受，请更新应用后重试。',
    20020 => '验证码已过期，请重新获取。',
    20021 => '验证码不正确，请重新输入。',
    20022 => '账号或密码不正确。',
    multiAccountErrorCode => '该手机号绑定了多个账号，请选择要登录的账号。',
    _ => '登录失败（错误码 $code）。',
  };
}

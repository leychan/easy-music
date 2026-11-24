import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'kugou/kugou_auth.dart';
import 'kugou/kugou_client.dart';
import 'kugou/kugou_device.dart';

/// 账号状态的唯一入口。
///
/// 登录凭证直接来自酷狗：应用自己算签名、自己调酷狗接口，拿到的
/// `token` 与 `userid` 就是酷狗账号凭证，不经过任何中间授权服务。
class Account extends ChangeNotifier {
  Account({KugouDevice? device, KugouClient? client})
    : _storage = const FlutterSecureStorage(
        aOptions: AndroidOptions(storageNamespace: 'EasyMusicAccount'),
      ) {
    _client = client;
    _device = device;
    unawaited(_restore());
  }

  final FlutterSecureStorage _storage;
  KugouClient? _client;
  KugouDevice? _device;
  static const _deviceKey = 'kugou_device';
  static const _sessionKey = 'kugou_session';
  static const _autoDailyVipKey = 'auto_daily_vip';
  final _vipChecks = <int>{};
  final _dailyVip = <int, ({String day, String notice})>{};

  bool _disposed = false;
  bool _persisted = false;

  bool loading = true;
  bool busy = false;

  /// 密钥存储不可用时给出提示；与登录失效无关。
  String? storageWarning;

  /// 已保存的登录被服务端判定失效时置为 true，界面提示后调用 [dismissExpiry]。
  bool sessionExpired = false;

  KugouSession? session;

  // 此前应用会自动签到，尚未保存设置的用户继续沿用该行为。
  bool _autoDailyVip = true;
  bool get autoDailyVip => _autoDailyVip;

  Future<void> setAutoDailyVip(bool enabled) async {
    await _storage.write(key: _autoDailyVipKey, value: enabled.toString());
    if (_disposed) return;
    _autoDailyVip = enabled;
    notifyListeners();
  }

  bool get dailyVipNeedsConceptLogin => session?.lite == false;

  String? get dailyVipNotice {
    final record = _dailyVip[session?.userid];
    return record?.day == _vipDay() ? record?.notice : null;
  }

  // 按酷狗活动的北京时间计算当日日期。
  static String _vipDay() => DateTime.now().toUtc()
      .add(const Duration(hours: 8)).toIso8601String().substring(0, 10);

  static String _vipAuthorizationKey(int id) => 'kugou_daily_vip_authorization_$id';
  static const _baseVipReceipt = '今日畅听 VIP 已领取。';
  static const _baseVipReceipts = {_baseVipReceipt, '今日 VIP 已领取。', '今日概念版 VIP 已领取。'};

  /// 使用主账号的概念版登录，先领取畅听 VIP，再请求概念版升级。
  Future<void> checkDailyVip() async {
    final owner = session;
    final api = auth;
    if (!_autoDailyVip || _disposed || loading || busy || owner == null || !owner.lite || api == null ||
        owner.userid <= 0 || owner.token.isEmpty) {
      return;
    }
    final day = _vipDay();
    final id = owner.userid;
    final existing = _dailyVip[id];
    if ((existing?.day == day && !_baseVipReceipts.contains(existing?.notice)) ||
        !_vipChecks.add(id)) {
      return;
    }
    final key = 'kugou_daily_vip_$id';
    bool isCurrent() => _autoDailyVip && !_disposed && !busy &&
        session?.userid == id && session?.token == owner.token;
    Future<void> record(String notice) async {
      _dailyVip[id] = (day: day, notice: notice);
      await _saveDailyVip(key, day, notice);
    }

    try {
      final cached = existing?.day == day ? existing?.notice : await _readDailyVip(key, day);
      if (!isCurrent()) return;
      var claimed = _baseVipReceipts.contains(cached);
      if (cached != null && !claimed) {
        _dailyVip[id] = (day: day, notice: cached);
      } else {
        if (!claimed) {
          // 先记录尝试，重启后避免重复提交；领取成功时单独记录第一步。
          await record('今日 VIP 领取结果待确认。');
          if (!isCurrent()) {
            _dailyVip.remove(id);
            await _safeDelete(key);
            return;
          }
        }
        try {
          if (!claimed) {
            await api.claimDailyVip(owner, day: day);
            claimed = true;
            await record(_baseVipReceipt);
          }
          if (!isCurrent()) return;
          await api.upgradeDailyVip(owner);
          await record('今日畅听 VIP 已领取，概念版 VIP 已升级。');
          // 更新账号的会员等级，让后续播放请求使用新的权益状态。
          if (isCurrent()) unawaited(_verify(owner));
        } on KugouFailure catch (error) {
          if (claimed) {
            await record('$_baseVipReceipt 概念版升级未完成。${error.message}');
          } else {
            await record(error.message);
          }
        } on Object {
          await record(claimed ? '$_baseVipReceipt 概念版升级未完成。' : '今日 VIP 领取未完成。');
        }
      }
      if (!_disposed && session?.userid == id) notifyListeners();
    } finally {
      _vipChecks.remove(id);
    }
  }

  Future<KugouSession?> _readVipAuthorization(int id) async {
    try {
      final raw = await _storage.read(key: _vipAuthorizationKey(id));
      if (raw == null) return null;
      final authorization = KugouSession.fromJson(jsonDecode(raw) as Map<String, dynamic>);
      if (authorization.userid != id || authorization.token.isEmpty) return null;
      return KugouSession(
        userid: id, token: authorization.token, nickname: authorization.nickname,
        avatar: authorization.avatar, vipType: authorization.vipType, mobile: authorization.mobile,
        lite: true,
      );
    } on Object {
      return null;
    }
  }

  Future<void> _saveDailyVip(String key, String day, String notice) async {
    try {
      await _storage.write(key: key, value: jsonEncode({'day': day, 'notice': notice}));
    } on Object {
      // 密钥存储暂不可用时，仍在本次运行中保留当天结果。
    }
  }

  Future<String?> _readDailyVip(String key, String day) async {
    try {
      final stored = await _storage.read(key: key);
      if (stored == null) return null;
      final record = jsonDecode(stored);
      if (record is Map && record['day'] == day && record['notice'] is String) {
        final notice = record['notice'] as String;
        // 旧版用主账号凭证被拒的记录，不占用新授权的当天领取机会。
        return notice.contains('错误码 51002') ? null : notice;
      }
    } on Object {
      // 读取失败时，领取流程继续使用内存中的当天记录。
    }
    return null;
  }

  KugouDevice? get device => _device;

  /// 已就绪的请求客户端，音乐库接口直接用它发请求。
  ///
  /// 为 null 表示账号层还在初始化（读设备标识）。它会在登录状态变化时同步
  /// [KugouClient.session]，因此拿到手后不必再关心登录与否。
  KugouClient? get client => _client;

  /// 登录接口入口。为 null 表示账号层尚未初始化完成。
  KugouAuth? get auth {
    final client = _client;
    return client == null ? null : KugouAuth(client);
  }

  Future<void> _restore() async {
    try {
      _device = await _loadDevice();
      // 测试可以注入现成的客户端（例如带 mock 传输层），正常运行才自建。
      _client ??= KugouClient(_device!);
      await _loadSession();
      _autoDailyVip = await _storage.read(key: _autoDailyVipKey) != 'false';
    } catch (_) {
      storageWarning = '无法读取本机保存的登录状态。';
    } finally {
      loading = false;
      _publish();
    }
  }

  /// 设备标识丢失时重新生成：酷狗会把它当成新设备，登录需要重做。
  Future<KugouDevice> _loadDevice() async {
    String? raw;
    try {
      raw = await _storage.read(key: _deviceKey);
    } on Object {
      // Linux 没有可用的密钥环时，仍用临时设备标识初始化登录入口。
      storageWarning = '无法读取本机保存的登录状态。';
      return _device ?? _client?.device ?? KugouDevice.generate();
    }
    if (raw != null) {
      try {
        return KugouDevice.decode(raw);
      } on Object {
        // 内容损坏，按首次启动处理。
      }
    }
    final device = KugouDevice.generate();
    try {
      await _storage.write(key: _deviceKey, value: device.encode());
    } on Object {
      // 写不进去也不影响本次运行，只是下次启动会换设备。
    }
    return device;
  }

  Future<void> _loadSession() async {
    final raw = await _storage.read(key: _sessionKey);
    if (raw == null) return;
    KugouSession restored;
    try {
      restored = KugouSession.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );
    } on Object {
      await _safeDelete(_sessionKey);
      return;
    }
    if (restored.token.isEmpty || restored.userid <= 0) {
      await _safeDelete(_sessionKey);
      return;
    }
    // 旧版已扫码的概念版凭证可以直接成为同一账号的主登录。
    if (!restored.lite) {
      final concept = await _readVipAuthorization(restored.userid);
      if (concept != null) {
        try {
          await _persist(concept);
          restored = concept;
          await _safeDelete(_vipAuthorizationKey(concept.userid));
        } on Object {
          // 写入失败时保留原账号，下一次启动仍可迁移。
        }
      }
    }
    session = restored;
    _persisted = true;
    // 酷狗 token 没有自带过期时间，用一次资料请求确认仍然有效。
    unawaited(_verify(restored));
  }

  /// 后台校验已保存的凭证。
  ///
  /// **只有服务端明确拒绝（[KugouSessionExpired]）才清除凭证。**
  /// 网络异常、接口下线、响应结构变化一律保留——之前用「拿不到资料就清掉」
  /// 的写法，遇上 `/v1/user/detail` 下线（返回 404），每次启动都会把人踢
  /// 下线，用户看到的就是「歌单一直 20017 / 登录莫名其妙没了」。
  Future<void> _verify(KugouSession restored) async {
    final KugouAuth? authApi = auth;
    if (authApi == null) return;
    try {
      final profile = await authApi.fetchProfile(restored);
      if (_disposed || session?.token != restored.token) return;
      if (profile == null) {
        // 拿到了响应但解析不出账号信息：可能只是字段变了，
        // 不做任何破坏性操作，等用户主动刷新时再看。
        debugPrint('[凭证] 校验未取得资料，保留现有登录（不清凭证）');
        return;
      }
      session = profile;
      if (_persisted) {
        try {
          await _persist(profile);
        } on Object {
          // 缓存写入失败时，当前会话仍使用服务端返回的新资料。
        }
      }
      _publish();
      debugPrint('[凭证] 校验通过，已刷新账号资料：${profile.nickname}');
    } on KugouSessionExpired {
      if (_disposed || session?.token != restored.token) return;
      debugPrint('[凭证] 服务端明确判定失效，清除本地登录');
      await _invalidate();
    } on KugouFailure catch (error) {
      // 网络问题交给下次启动或用户主动操作时再判断。
      debugPrint('[凭证] 校验失败但保留登录：${error.message}');
    }
  }

  /// 凭证被服务端拒绝：清除并提示用户重新登录。
  Future<void> _invalidate() async {
    session = null;
    sessionExpired = true;
    if (!_persisted) {
      _publish();
      return;
    }
    _persisted = false;
    await _safeDelete(_sessionKey);
    _publish();
  }

  void dismissExpiry() {
    if (!sessionExpired) return;
    sessionExpired = false;
    _publish();
  }

  Future<void> signIn(KugouSession newSession) async {
    if (busy) return;
    busy = true;
    storageWarning = null;
    sessionExpired = false;
    _publish();
    try {
      await _persist(newSession);
      session = newSession;
      _persisted = true;
    } catch (_) {
      // 存不进去也让本次会话可用，只是重启后要重新登录。
      storageWarning = '系统密钥存储暂不可用，重启后需要重新登录。';
      session = newSession;
      _persisted = false;
    } finally {
      // 登录凭证更新后，可以重试当天因凭证被拒的步骤。
      if (newSession.lite) await _resetRejectedDailyVip(newSession.userid);
      busy = false;
      _publish();
    }
  }

  Future<void> _resetRejectedDailyVip(int id) async {
    final key = 'kugou_daily_vip_$id';
    final day = _vipDay();
    final current = _dailyVip[id];
    final notice = current?.day == day ? current?.notice : await _readDailyVip(key, day);
    final rejected = const DailyVipAuthorizationExpired().message;
    if (notice == rejected) {
      _dailyVip.remove(id);
      await _safeDelete(key);
    } else if (notice == '$_baseVipReceipt 概念版升级未完成。$rejected') {
      _dailyVip[id] = (day: day, notice: _baseVipReceipt);
      await _saveDailyVip(key, day, _baseVipReceipt);
    }
  }

  Future<void> _persist(KugouSession value) =>
      _storage.write(key: _sessionKey, value: jsonEncode(value.toJson()));

  Future<void> signOut() async {
    if (busy) return;
    busy = true;
    _publish();
    try {
      final id = session?.userid;
      if (_persisted) await _storage.delete(key: _sessionKey);
      if (id != null) {
        await _safeDelete(_vipAuthorizationKey(id));
      }
      _persisted = false;
      session = null;
      storageWarning = null;
      sessionExpired = false;
    } catch (_) {
      storageWarning = '无法清除本机保存的登录状态，请检查系统密钥存储后重试。';
    } finally {
      busy = false;
      _publish();
    }
  }

  Future<bool> _safeDelete(String key) async {
    try {
      await _storage.delete(key: key);
      return true;
    } on Object {
      // 删除失败时下次启动还会遇到同样的数据，但不该阻塞界面。
      return false;
    }
  }

  void _publish() {
    // 客户端与账号状态保持同步：音乐库接口据此决定是否带 token。
    // 登录/退出/失效都走 _publish，因此只需要在这里同步一次。
    _client?.session = session;
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _client?.close();
    super.dispose();
  }
}

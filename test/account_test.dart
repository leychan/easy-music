import 'dart:convert';

import 'package:easy_music/account/account.dart';
import 'package:easy_music/account/account_page.dart';
import 'package:easy_music/account/kugou/kugou_auth.dart';
import 'package:easy_music/account/kugou/kugou_client.dart';
import 'package:easy_music/account/kugou/kugou_device.dart';
import 'package:easy_music/account/kugou/signature.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart'
    show AndroidOptions, FlutterSecureStorage;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';

const _session = KugouSession(
  userid: 12345,
  token: 'kugou-token',
  nickname: '测试账号',
  avatar: '',
  vipType: 1,
);

/// 等待 Account 完成首次初始化（读取设备标识并恢复会话）。
Future<void> _ready(Account account) async {
  while (account.loading) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  test('首次启动生成并持久化设备标识', () async {
    final account = Account();
    addTearDown(account.dispose);
    await _ready(account);

    final device = account.device!;
    expect(device.guid, isNotEmpty);
    expect(device.mid, isNotEmpty);

    final reopened = Account();
    addTearDown(reopened.dispose);
    await _ready(reopened);
    // 设备标识必须稳定，否则酷狗会当成新设备。
    expect(reopened.device!.guid, device.guid);
    expect(reopened.device!.mid, device.mid);
  });

  test('登录后写入凭证，重启仍能恢复', () async {
    final account = Account();
    addTearDown(account.dispose);
    await _ready(account);
    await account.signIn(_session);
    expect(account.session?.token, 'kugou-token');

    final reopened = Account(
      client: KugouClient(
        KugouDevice(guid: 'g', mac: 'AA:BB:CC:DD:EE:FF'),
        // 校验通过，返回账号资料。
        client: MockClient(
          (_) async => http.Response.bytes(
            utf8.encode(
              '{"status":1,"data":{"userid":12345,"nickname":"测试账号","vip_type":1}}',
            ),
            200,
          ),
        ),
      ),
    );
    addTearDown(reopened.dispose);
    await _ready(reopened);
    // 重启后直接从密钥存储恢复出同一个账号。
    expect(reopened.session?.token, 'kugou-token');
    expect(reopened.session?.userid, 12345);
  });

  test('自动签到沿用开启默认值，关闭后重启不请求，重新开启后可领取', () async {
    final activity = <String>[];
    Account open() {
      final account = Account(client: KugouClient(
        KugouDevice(guid: 'vip-preference', mac: '02:00:00:00:00:00'),
        client: MockClient((request) async {
          final path = request.url.path;
          if (path.startsWith('/youth/')) activity.add(path);
          return http.Response('{"status":1,"error_code":0,"data":{}}', 200);
        }),
      ));
      addTearDown(account.dispose);
      return account;
    }

    final account = open();
    await _ready(account);
    expect(account.autoDailyVip, isTrue);
    await account.setAutoDailyVip(false);
    await account.signIn(const KugouSession(
      userid: 12345, token: 'lite-token', nickname: '测试账号', avatar: '', lite: true,
    ));
    await account.checkDailyVip();
    expect(activity, isEmpty);

    final reopened = open();
    await _ready(reopened);
    expect(reopened.autoDailyVip, isFalse);
    await reopened.checkDailyVip();
    expect(activity, isEmpty);
    await reopened.setAutoDailyVip(true);
    await reopened.checkDailyVip();
    await reopened.checkDailyVip();
    expect(activity, [
      '/youth/v1/recharge/receive_vip_listen_song',
      '/youth/v1/listen_song/upgrade_vip_reward',
    ]);
  });

  test('每日 VIP 使用主登录领取并升级，按账号去重', () async {
    final activity = <String>[];
    Account openAccount() {
      final account = Account(client: KugouClient(
        KugouDevice(guid: 'vip-check', mac: '02:00:00:00:00:00'),
        client: MockClient((request) async {
          final path = request.url.path;
          if (path == '/v3/get_my_info') {
            return http.Response('{"status":1,"data":{"userid":12345,"nickname":"Concept","vip_type":1}}', 200);
          }
          if (!path.startsWith('/youth/')) {
            return http.Response('{"status":0,"data":null}', 200);
          }
          expect(request.method, 'POST');
          final query = Map<String, Object?>.of(request.url.queryParameters);
          expect(query['appid'], '3116');
          final signature = query.remove('signature');
          expect(signature, KugouSignature.liteAndroid(query, request.body));
          final userid = query['userid'].toString();
          expect(query['token'], 'lite-token-$userid');
          const storage = FlutterSecureStorage(
            aOptions: AndroidOptions(storageNamespace: 'EasyMusicAccount'),
          );
          final attempt = await storage.read(key: 'kugou_daily_vip_$userid');
          if (path == '/youth/v1/recharge/receive_vip_listen_song') {
            expect(query['source_id'], '90139');
            final day = DateTime.now().toUtc().add(const Duration(hours: 8)).toIso8601String().substring(0, 10);
            expect(query['receive_day'], day);
            expect(jsonDecode(request.body), {'receive_day': day});
            expect(attempt, contains('领取结果待确认'));
            activity.add('领取 $userid');
            return http.Response('{"status":1,"error_code":0}', 200);
          }
          expect(path, '/youth/v1/listen_song/upgrade_vip_reward');
          expect(query['kugouid'], userid);
          expect(query['ad_type'], '1');
          expect(attempt, contains('今日畅听 VIP 已领取。'));
          activity.add('升级 $userid');
          return http.Response.bytes(utf8.encode(userid == '12345'
              ? '{"status":1,"error_code":0}'
              : '{"status":0,"error_msg":"今日活动未达升级条件"}'), 200);
        }),
      ));
      addTearDown(account.dispose);
      return account;
    }

    final account = openAccount();
    await _ready(account);
    await account.checkDailyVip();
    expect(activity, isEmpty);
    await account.signIn(_session);
    await account.checkDailyVip();
    expect(activity, isEmpty);
    expect(account.dailyVipNeedsConceptLogin, isTrue);
    await account.signIn(const KugouSession(
      userid: 12345, token: 'lite-token-12345', nickname: '', avatar: '', lite: true,
    ));
    await Future.wait([account.checkDailyVip(), account.checkDailyVip()]);
    expect(account.dailyVipNeedsConceptLogin, isFalse);
    expect(account.dailyVipNotice, '今日畅听 VIP 已领取，概念版 VIP 已升级。');
    expect(activity, ['领取 12345', '升级 12345']);
    await Future<void>.delayed(Duration.zero);
    expect(account.session?.vipType, 1);

    final reopened = openAccount();
    await _ready(reopened);
    await reopened.checkDailyVip();
    expect(reopened.session?.lite, isTrue);
    expect(reopened.session?.token, 'lite-token-12345');
    expect(reopened.dailyVipNotice, account.dailyVipNotice);
    expect(activity, ['领取 12345', '升级 12345']);

    await reopened.signIn(const KugouSession(
      userid: 729, token: 'lite-token-729', nickname: '', avatar: '', lite: true,
    ));
    expect(reopened.dailyVipNotice, isNull);
    await reopened.checkDailyVip();
    await reopened.checkDailyVip();
    expect(reopened.dailyVipNotice, '今日畅听 VIP 已领取。 概念版升级未完成。今日活动未达升级条件');
    expect(activity, ['领取 12345', '升级 12345', '领取 729', '升级 729']);
  });

  test('旧概念版扫码凭证迁移到同账号，旧 51002 不阻挡当天领取', () async {
    final day = DateTime.now().toUtc().add(const Duration(hours: 8)).toIso8601String().substring(0, 10);
    const previous = KugouSession(userid: 12345, token: 'saved-lite', nickname: '', avatar: '');
    const legacyKey = 'kugou_daily_vip_authorization_12345';
    FlutterSecureStorage.setMockInitialValues({
      'kugou_session': jsonEncode(_session.toJson()),
      legacyKey: jsonEncode(previous.toJson()),
      'kugou_daily_vip_12345': jsonEncode({'day': day, 'notice': '酷狗未确认今日 VIP 领取（错误码 51002）。'}),
    });
    final activity = <String>[];
    final account = Account(client: KugouClient(
      KugouDevice(guid: 'daily-vip-token', mac: '02:00:00:00:00:00'),
      client: MockClient((request) async {
        final path = request.url.path;
        if (!path.startsWith('/youth/')) {
          return http.Response('{"status":0,"data":null}', 200);
        }
        expect(request.url.queryParameters['token'], 'saved-lite');
        activity.add(path);
        return http.Response(path.endsWith('/upgrade_vip_reward')
            ? '{"status":0,"error_code":20030}'
            : '{"status":0,"error_code":131001}', 200);
      }),
    ));
    addTearDown(account.dispose);
    await _ready(account);
    expect(account.session?.token, 'saved-lite');
    expect(account.session?.lite, isTrue);
    expect(account.dailyVipNeedsConceptLogin, isFalse);
    const storage = FlutterSecureStorage(
      aOptions: AndroidOptions(storageNamespace: 'EasyMusicAccount'),
    );
    expect(await storage.read(key: legacyKey), isNull);
    expect(await storage.read(key: 'kugou_session'), contains('"lite":true'));
    await account.checkDailyVip();
    expect(account.dailyVipNotice, '今日畅听 VIP 已领取，概念版 VIP 已升级。');
    expect(activity, [
      '/youth/v1/recharge/receive_vip_listen_song',
      '/youth/v1/listen_song/upgrade_vip_reward',
    ]);
  });

  test('活动凭证被拒后重新登录，只重试未完成的升级', () async {
    final activity = <String>[];
    final account = Account(client: KugouClient(
      KugouDevice(guid: 'vip-relogin', mac: '02:00:00:00:00:00'),
      client: MockClient((request) async {
        final path = request.url.path;
        if (path == '/v3/get_my_info') {
          return http.Response('{"status":0,"data":null}', 200);
        }
        if (path.endsWith('/receive_vip_listen_song')) {
          activity.add('领取');
          return http.Response('{"status":1}', 200);
        }
        expect(path, '/youth/v1/listen_song/upgrade_vip_reward');
        final token = request.url.queryParameters['token'];
        activity.add('升级 $token');
        return http.Response(token == 'fresh-lite'
            ? '{"status":1}'
            : '{"status":0,"error_code":51002}', 200);
      }),
    ));
    addTearDown(account.dispose);
    await _ready(account);
    await account.signIn(const KugouSession(
      userid: 12345, token: 'old-lite', nickname: '', avatar: '', lite: true,
    ));
    await account.checkDailyVip();
    expect(account.dailyVipNotice, contains('概念版升级未完成'));
    expect(account.session?.token, 'old-lite');
    await account.signIn(const KugouSession(
      userid: 12345, token: 'fresh-lite', nickname: '', avatar: '', lite: true,
    ));
    await account.checkDailyVip();
    expect(account.dailyVipNotice, '今日畅听 VIP 已领取，概念版 VIP 已升级。');
    expect(activity, ['领取', '升级 old-lite', '升级 fresh-lite']);
  });

  test('退出登录清除凭证但保留设备标识', () async {
    final account = Account();
    addTearDown(account.dispose);
    await _ready(account);
    final guid = account.device!.guid;
    await account.signIn(_session);
    await account.signOut();

    expect(account.session, isNull);
    const storage = FlutterSecureStorage(
      aOptions: AndroidOptions(storageNamespace: 'EasyMusicAccount'),
    );
    expect(await storage.read(key: 'kugou_session'), isNull);
    expect(await storage.read(key: 'kugou_device'), contains(guid));
  });

  test('损坏的会话数据不会阻塞启动', () async {
    FlutterSecureStorage.setMockInitialValues({
      'kugou_device': KugouDevice(guid: 'g-1', mac: 'AA:BB:CC:DD:EE:FF').encode(),
      'kugou_session': 'not-json',
    });
    final account = Account();
    addTearDown(account.dispose);
    await _ready(account);
    expect(account.session, isNull);
    expect(account.loading, isFalse);
  });

  test('过期提示可以单独清除，不影响存储故障提示', () async {
    final account = Account();
    addTearDown(account.dispose);
    await _ready(account);
    account.sessionExpired = true;
    account.storageWarning = '密钥存储异常';
    account.dismissExpiry();
    expect(account.sessionExpired, isFalse);
    expect(account.storageWarning, '密钥存储异常');
  });

  test('服务端明确拒绝已保存凭证时清除并标记失效', () async {
    FlutterSecureStorage.setMockInitialValues({
      'kugou_device': KugouDevice(guid: 'g-1', mac: 'AA:BB:CC:DD:EE:FF').encode(),
      'kugou_session': jsonEncode(_session.toJson()),
    });
    final account = Account(
      client: KugouClient(
        KugouDevice(guid: 'g-1', mac: 'AA:BB:CC:DD:EE:FF'),
        // 20018：服务端明确说 token 无效。只有这种明确拒绝才该清凭证。
        client: MockClient(
          (_) async => http.Response('{"status":0,"error_code":20018}', 200),
        ),
      ),
    );
    addTearDown(account.dispose);
    await _ready(account);
    // 等后台校验跑完。
    for (var i = 0; i < 20 && account.sessionExpired == false; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(account.session, isNull);
    expect(account.sessionExpired, isTrue);
  });

  test('资料接口解析不出内容时不删凭证', () async {
    // 这是真实踩过的坑：/v1/user/detail 下线后返回 404，
    // 旧实现把「拿不到资料」当成「token 失效」，每次启动都清凭证，
    // 用户看到「登录莫名其妙没了、歌单一直 20017」。
    FlutterSecureStorage.setMockInitialValues({
      'kugou_device': KugouDevice(guid: 'g-1', mac: 'AA:BB:CC:DD:EE:FF').encode(),
      'kugou_session': jsonEncode(_session.toJson()),
    });
    final account = Account(
      client: KugouClient(
        KugouDevice(guid: 'g-1', mac: 'AA:BB:CC:DD:EE:FF'),
        // 200 + data:null，但没有明确的 20017/20018 错误码。
        client: MockClient(
          (_) async => http.Response('{"status":0,"data":null}', 200),
        ),
      ),
    );
    addTearDown(account.dispose);
    await _ready(account);
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    // 凭证必须还在。
    expect(account.session, isNotNull);
    expect(account.sessionExpired, isFalse);
  });

  test('网络失败时保留已保存凭证，不误判为失效', () async {
    FlutterSecureStorage.setMockInitialValues({
      'kugou_device': KugouDevice(guid: 'g-1', mac: 'AA:BB:CC:DD:EE:FF').encode(),
      'kugou_session': jsonEncode(_session.toJson()),
    });
    final account = Account(
      client: KugouClient(
        KugouDevice(guid: 'g-1', mac: 'AA:BB:CC:DD:EE:FF'),
        client: MockClient((_) async => throw http.ClientException('offline')),
      ),
    );
    addTearDown(account.dispose);
    await _ready(account);
    await Future<void>.delayed(Duration.zero);
    expect(account.session?.token, 'kugou-token');
    expect(account.sessionExpired, isFalse);
  });

  testWidgets('未登录时默认展示手机号登录，可切换到账号密码', (tester) async {
    final account = Account();
    addTearDown(account.dispose);
    await tester.pumpWidget(MaterialApp(home: AccountPage(account: account)));
    await tester.pumpAndSettle();

    expect(find.text('登录酷狗账号'), findsOneWidget);
    final phone = find.widgetWithText(ChoiceChip, '手机号');
    final password = find.widgetWithText(ChoiceChip, '账号密码');
    expect(tester.widget<ChoiceChip>(phone).selected, isTrue);
    expect(find.text('获取验证码'), findsOneWidget);
    expect(find.text('扫码'), findsNothing);
    expect(find.text('获取二维码'), findsNothing);

    await tester.tap(password);
    await tester.pumpAndSettle();
    expect(tester.widget<ChoiceChip>(password).selected, isTrue);
    expect(find.text('密码'), findsOneWidget);
  });

  testWidgets('退出登录需要确认', (tester) async {
    final account = Account();
    addTearDown(account.dispose);
    await tester.pumpWidget(MaterialApp(home: AccountPage(account: account)));
    await tester.pumpAndSettle();
    await account.signIn(_session);
    await tester.pumpAndSettle();

    await tester.tap(find.text('退出登录'));
    await tester.pumpAndSettle();
    expect(find.text('退出登录？'), findsOneWidget);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(account.session, isNotNull);

    await tester.tap(find.text('退出登录'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('退出登录').last);
    await tester.pumpAndSettle();
    expect(account.session, isNull);
  });

  testWidgets('手机号格式错误时本地直接提示，不发请求', (tester) async {
    final account = Account();
    addTearDown(account.dispose);
    await tester.pumpWidget(MaterialApp(home: AccountPage(account: account)));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, '123');
    await tester.tap(find.text('登录'));
    await tester.pumpAndSettle();
    expect(find.text('请输入 11 位手机号。'), findsOneWidget);
  });

  testWidgets('手机号绑定多个账号时可选择指定账号登录', (tester) async {
    final selectedIds = <Object?>[];
    final account = Account(
      client: KugouClient(
        KugouDevice(guid: 'g-1', mac: 'AA:BB:CC:DD:EE:FF'),
        client: MockClient((request) async {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          selectedIds.add(body['userid']);
          if (body['userid'] == null) {
            return http.Response.bytes(utf8.encode(
              '{"error_code":"34175","data":{"info_list":['
              '{"userid":"101","nickname":"甲账号"},'
              '{"userid":"102","nickname":"乙账号"}]}}',
            ), 502);
          }
          return http.Response.bytes(utf8.encode(
            '{"status":1,"data":{"token":"test-token","userid":"102","nickname":"乙账号"}}',
          ), 200);
        }),
      ),
    );
    addTearDown(account.dispose);
    await tester.pumpWidget(MaterialApp(home: AccountPage(account: account)));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, '13800138000');
    await tester.enterText(find.byType(TextField).last, '123456');
    await tester.tap(find.text('登录'));
    await tester.pumpAndSettle();

    expect(find.byType(TextField), findsNothing);
    expect(find.text('甲账号'), findsOneWidget);
    await tester.tap(find.text('乙账号'));
    await tester.pumpAndSettle();

    expect(selectedIds, [null, 102]);
    expect(account.session?.userid, 102);
    expect(find.text('酷狗账号 102'), findsOneWidget);
  });
}

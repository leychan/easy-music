import 'dart:convert';
import 'dart:io';

import 'package:easy_music/account/kugou/kugou_auth.dart';
import 'package:easy_music/account/kugou/kugou_client.dart';
import 'package:easy_music/account/kugou/kugou_device.dart';
import 'package:easy_music/account/kugou/signature.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 真实网络验证：酷狗服务端必须接受我们算出的签名与设备标识。
///
/// 默认跳过，用 `KUGOU_NET=1 flutter test test/kugou_live_test.dart` 时才执行。
final _enabled = Platform.environment['KUGOU_NET'] == '1';

void main() {
  test('申请二维码并识别初始状态', () async {
    final device = KugouDevice.generate();
    final client = KugouClient(device);
    addTearDown(client.close);
    final auth = KugouAuth(client);

    final key = await auth.requestQrCode();
    expect(key, isNotEmpty);

    final result = await auth.checkQrCode(key);
    // 刚创建的二维码一定还没被扫，允许 waiting 或已过期（网络耗时）。
    expect(result.state, anyOf(QrLoginState.waiting, QrLoginState.expired));
  }, skip: _enabled ? false : '需要网络，设置 KUGOU_NET=1 后运行');

  test('扫码地址指向酷狗官方 H5 页面', () {
    expect(
      KugouAuth.qrContent('abc'),
      'https://h5.kugou.com/apps/loginQRCode/html/index.html?qrcode=abc',
    );
  });

  test('申请二维码和轮询状态使用 H5 签名', () async {
    final client = KugouClient(
      KugouDevice(guid: 'g-1', mac: 'AA:BB:CC:DD:EE:FF'),
      client: MockClient((request) async {
        final params = Map.of(request.url.queryParameters);
        final signature = params.remove('signature');
        expect(signature, KugouSignature.web(params));
        if (request.url.path == '/v2/qrcode') {
          return http.Response('{"status":1,"data":{"qrcode":"test-qr"}}', 200);
        }
        expect(request.url.path, '/v2/get_userinfo_qrcode');
        expect(params['qrcode'], 'test-qr');
        return http.Response('{"status":1,"data":{"status":"1"}}', 200);
      }),
    );
    addTearDown(client.close);
    final auth = KugouAuth(client);
    final key = await auth.requestQrCode();
    expect((await auth.checkQrCode(key)).state, QrLoginState.waiting);
  });

  test('验证码请求走明文 HTTP 入口', () async {
    // 这个域名没有可用的 HTTPS 入口：同一主机名 TLS 握手会直接失败，
    // 换成其他域名服务端不认签名。曾经因为改成 https 导致「获取验证码」
    // 一直失败，这里固定住协议以防再被误改。用 mock 传输层，不联网。
    Uri? captured;
    final client = KugouClient(
      KugouDevice(guid: 'g-1', mac: 'AA:BB:CC:DD:EE:FF'),
      client: MockClient((request) async {
        captured = request.url;
        return http.Response('{"status":"1","data":{"count":"5"}}', 200);
      }),
    )..session = const KugouSession(
      userid: 123,
      token: 'existing-session',
      nickname: '账号',
      avatar: '',
    );
    final remaining = await KugouAuth(client).sendSmsCode('13800138000');
    expect(captured!.scheme, 'http');
    expect(captured!.host, 'login.user.kugou.com');
    expect(captured!.path, '/v7/send_mobile_code');
    expect(captured!.queryParameters, isNot(contains('token')));
    expect(captured!.queryParameters, isNot(contains('userid')));
    expect(remaining, 5);
  });

  test('用登录请求的种子解密 JSON 凭证和裸 token', () {
    const seed = 'example-seed-001';
    // 密文由独立的 Node AES-256-CBC 实现生成。
    expect(
      KugouClient.decryptSecuParams(
        'cff1ce06937ef9266f7fb539cc1dad3ec9433940a036f5a2a10e85edb4ec2fb7'
        '9c2140d78fb4bfb2f04c8e7028ce40ae',
        seed,
      ),
      {'token': 'session-token', 'userid': '12345'},
    );
    expect(
      KugouClient.decryptSecuParams(
        '20f9ea14d8f326c2f290a0e448f576293cf740a60807a181d217aee99741cffa',
        seed,
      ),
      {'token': 'plain-session-token'},
    );
    expect(KugouClient.decryptSecuParams('not-a-cipher', seed), isEmpty);
  });

  test('登录凭证解不开时不会把密文写成 token', () async {
    final client = KugouClient(
      KugouDevice(guid: 'g-1', mac: 'AA:BB:CC:DD:EE:FF'),
      client: MockClient((_) async => http.Response(
        '{"status":"1","data":{"userid":"123","secu_params":"not-a-cipher"}}',
        200,
      )),
    );
    addTearDown(client.close);
    await expectLater(
      KugouAuth(client).loginWithSms('13800138000', '123456'),
      throwsA(isA<KugouFailure>().having(
        (e) => e.message,
        'message',
        contains('完整的登录凭证'),
      )),
    );
  });

  test('短信登录请求体必须带 t1/t2', () async {
    // 服务端把 t1/t2 当必填：缺任意一个就返回 20010，表现为「登录失败」，
    // 极易被误判成密码错或参数错。用 mock 固定住这两个字段，防止再被删掉。
    String? capturedBody;
    Uri? capturedUrl;
    final client = KugouClient(
      KugouDevice(guid: 'g-1', mac: 'AA:BB:CC:DD:EE:FF'),
      client: MockClient((request) async {
        capturedUrl = request.url;
        capturedBody = request.body;
        return http.Response.bytes(
          utf8.encode('{"status":0,"error_code":20021,"data":"验证码错误"}'),
          200,
        );
      }),
    );

    await expectLater(
      KugouAuth(client).loginWithSms('13800138000', '1234'),
      throwsA(isA<KugouFailure>()),
    );

    expect(capturedUrl!.host, 'loginserviceretry.kugou.com');
    expect(capturedUrl!.path, '/v7/login_by_verifycode');

    final body = jsonDecode(capturedBody!) as Map<String, dynamic>;
    expect(body['t1'], isA<String>());
    expect(body['t1'], isNotEmpty);
    expect(body['t2'], isA<String>());
    expect(body['t2'], isNotEmpty);
    // t2 带设备指纹与平台，长度应长于只含时间戳的 t1。
    expect((body['t2'] as String).length, greaterThan((body['t1'] as String).length));
    expect(body['plat'], 1);
    expect(body['mobile'], '13*****0');
  });

  test('短信登录服务端不再返回 20010', () async {
    // 端到端验证：用一个必然错误的验证码，服务端应当在真正校验过请求结构后
    // 返回业务错误（20021 验证码错误），而不是结构错误 20010。
    final client = KugouClient(KugouDevice.generate());
    addTearDown(client.close);
    final auth = KugouAuth(client);

    Object? failure;
    try {
      await auth.loginWithSms('13800138000', '000000');
    } on KugouFailure catch (error) {
      failure = error;
    }
    expect(failure, isNotNull, reason: '假验证码不应登录成功');
    expect(
      (failure! as KugouFailure).message,
      isNot(contains('20010')),
      reason: '20010 表示请求缺字段（t1/t2），不应再出现',
    );
  }, skip: _enabled ? false : '需要网络，设置 KUGOU_NET=1 后运行');

  test('34175 表示手机号绑定了多个账号，需选择后重登', () async {
    // 酷狗对该手机号不直接登录，而是返回 34175 + info_list。
    // 这不是失败：验证码已经校验通过，只差指定 userid。
    final requests = <Map<String, dynamic>>[];
    final client = KugouClient(
      KugouDevice(guid: 'g-1', mac: 'AA:BB:CC:DD:EE:FF'),
      client: MockClient((request) async {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        requests.add(body);
        // 首次不带 userid -> 返回多账号；带 userid 后登录成功。
        if (!body.containsKey('userid')) {
          return http.Response.bytes(
            utf8.encode(jsonEncode({
              'status': 0,
              'error_code': '34175',
              'data': {
                'info_list': [
                  {
                    'userid': 111111111,
                    'nickname': '账号A',
                    'username': '13*****0',
                    'appid': 1000,
                  },
                  {
                    'userid': '222222222',
                    'nickname': '账号B',
                    'username': '13*****0',
                  },
                ],
              },
            })),
            502,
          );
        }
        return http.Response.bytes(
          utf8.encode(jsonEncode({
            'status': '1',
            'data': {'token': 'tok-xyz', 'userid': '${body['userid']}'},
          })),
          200,
        );
      }),
    );

    final auth = KugouAuth(client);

    // 第一步：应当抛出多账号异常，而不是普通失败
    late KugouMultiAccount multi;
    try {
      await auth.loginWithSms('13800138000', '123456');
      fail('应当抛出 KugouMultiAccount');
    } on KugouMultiAccount catch (error) {
      multi = error;
    }
    expect(multi.accounts, hasLength(2));
    expect(multi.accounts.first.userid, 111111111);
    expect(multi.accounts.first.label, '账号A');
    // 昵称为空时回退到掩码手机号，不显示空白项
    expect(multi.accounts[1].nickname, '账号B');
    expect(multi.accounts.every((a) => a.label.isNotEmpty), isTrue);

    // 第二步：选定账号后带 userid 重登，应当成功
    final session = await auth.loginWithSms(
      '13800138000',
      '123456',
      userid: 222222222,
    );
    expect(session.userid, 222222222);
    expect(session.token, 'tok-xyz');

    // 重登沿用了同一组手机号与验证码
    expect(requests, hasLength(2));
    expect(requests.last['userid'], 222222222);
    expect(requests.last['mobile'], '13*****0');
  });

  test('34175 但账号列表为空时给出明确提示', () async {
    final client = KugouClient(
      KugouDevice(guid: 'g-1', mac: 'AA:BB:CC:DD:EE:FF'),
      client: MockClient((request) async {
        return http.Response.bytes(
          utf8.encode(jsonEncode({
            'status': 0,
            'error_code': 34175,
            'data': {'info_list': <Object>[]},
          })),
          502,
        );
      }),
    );

    await expectLater(
      KugouAuth(client).loginWithSms('13800138000', '123456'),
      throwsA(
        isA<KugouFailure>()
            .having((e) => e.message, 'message', contains('换一种方式登录'))
            // 不能把原始错误码暴露给用户
            .having((e) => e.message, 'message', isNot(contains('34175'))),
      ),
    );
  });

  test('账号列表放在意外层级时仍能识别', () async {
    // 该结构没有官方文档，实测只确认过 data.info_list。
    // 这里验证即使服务端换了层级，也不会退化成“登录失败”。
    final client = KugouClient(
      KugouDevice(guid: 'g-1', mac: 'AA:BB:CC:DD:EE:FF'),
      client: MockClient((request) async {
        return http.Response.bytes(
          utf8.encode(jsonEncode({
            'status': 0,
            'error_code': 34175,
            'data': {
              'extra': {
                'accounts': [
                  {'userid': 333, 'nickname': '深处的账号'},
                ],
              },
            },
          })),
          502,
        );
      }),
    );

    await expectLater(
      KugouAuth(client).loginWithSms('13800138000', '123456'),
      throwsA(
        isA<KugouMultiAccount>().having(
          (e) => e.accounts.single.userid,
          'userid',
          333,
        ),
      ),
    );
  });

  test('短信接口真实联通', () async {
    // 注意：会真的发出短信。只在 KUGOU_NET=1 且通过 MOBILE 指定号码时执行。
    final mobile = Platform.environment['MOBILE'] ?? '';
    if (!RegExp(r'^1\d{10}$').hasMatch(mobile)) {
      markTestSkipped('未提供 MOBILE，跳过真实发送');
      return;
    }
    final client = KugouClient(KugouDevice.generate());
    addTearDown(client.close);
    final remaining = await KugouAuth(client).sendSmsCode(mobile);
    expect(remaining, isNotNull);
  }, skip: _enabled ? false : '需要网络，设置 KUGOU_NET=1 后运行');
}

import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../ui/app_dialog.dart';
import '../ui/workspace_page.dart';
import 'account.dart';
import 'kugou/kugou_auth.dart';

/// 登录页支持短信验证和账号密码。
enum LoginMethod { phone, password }

class AccountPage extends StatelessWidget {
  const AccountPage({
    super.key, required this.account, this.switchToConcept = false, this.returnToMyPage = false,
  });

  final Account account;
  final bool switchToConcept;
  final bool returnToMyPage;

  /// 退出会清除本机凭证，先让用户确认。
  Future<void> _confirmSignOut(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AppDialog(
        title: const Text('退出登录？'),
        content: const Text('将清除本机保存的酷狗登录凭证，下次使用需要重新登录。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('退出登录'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    await account.signOut();
    if (returnToMyPage && account.session == null && context.mounted) {
      await Navigator.of(context).maybePop();
    }
  }

  @override
  Widget build(BuildContext context) => WorkspacePage(
    title: Text(switchToConcept ? '切换到概念版登录' : '账号'),
    body: SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: ListenableBuilder(
            listenable: account,
            builder: (context, _) {
              final session = account.session;
              return ListView(
                padding: DesktopPageScope.bodyPadding(context, const EdgeInsets.all(24)),
                children: [
                  if (account.loading)
                    const Center(child: CircularProgressIndicator())
                  else if (session == null || switchToConcept)
                    _LoginForm(
                      account: account, switchToConcept: switchToConcept,
                      returnToMyPage: returnToMyPage,
                    )
                  else
                    _SignedIn(
                      account: account,
                      session: session,
                      onSignOut: () => _confirmSignOut(context),
                    ),
                  if (account.sessionExpired) _ExpiryNotice(account: account),
                  if (account.storageWarning case final warning?)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Text(warning),
                    ),
                  const SizedBox(height: 24),
                  Text(
                    '登录信息直接与酷狗官方接口交互，仅保存在本机密钥存储中。',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              );
            },
          ),
        ),
      ),
    ),
  );
}

class _SignedIn extends StatelessWidget {
  const _SignedIn({
    required this.account,
    required this.session,
    required this.onSignOut,
  });

  final Account account;
  final KugouSession session;
  final VoidCallback onSignOut;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Column(
      children: [
        ClipOval(
          child: session.avatar.isEmpty
              ? Container(
                  width: 58,
                  height: 58,
                  color: colors.surfaceContainerHighest,
                  child: const Icon(Icons.person, size: 32),
                )
              : Image.network(
                  session.avatar,
                  width: 58,
                  height: 58,
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => Container(
                    width: 58,
                    height: 58,
                    color: colors.surfaceContainerHighest,
                    child: const Icon(Icons.person, size: 32),
                  ),
                ),
        ),
        const SizedBox(height: 14),
        Text(
          session.nickname,
          style: Theme.of(context).textTheme.headlineSmall,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 4),
        Text('酷狗账号 ${session.userid}', textAlign: TextAlign.center),
        if (session.vipType > 0)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              'VIP',
              style: TextStyle(color: colors.primary, fontWeight: FontWeight.w600),
            ),
          ),
        const SizedBox(height: 24),
        // 自动签到需要概念版凭证，旧版登录可在账号详情里切换。
        if (account.autoDailyVip && account.dailyVipNeedsConceptLogin)
          TextButton(
            onPressed: account.busy ? null : () => Navigator.of(context).push<void>(
              MaterialPageRoute(builder: (_) => AccountPage(account: account, switchToConcept: true)),
            ),
            child: const Text('切换到概念版登录'),
          ),
        OutlinedButton(
          onPressed: account.busy ? null : onSignOut,
          child: const Text('退出登录'),
        ),
      ],
    );
  }
}

/// 登录过期提示。与密钥存储故障是两种状况，分开呈现。
class _ExpiryNotice extends StatelessWidget {
  const _ExpiryNotice({required this.account});

  final Account account;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Card(
        color: colors.errorContainer,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '登录已失效',
                style: Theme.of(
                  context,
                ).textTheme.titleSmall?.copyWith(color: colors.onErrorContainer),
              ),
              const SizedBox(height: 6),
              Text(
                '本机保存的酷狗凭证已被清除，请重新登录。',
                style: TextStyle(color: colors.onErrorContainer),
              ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: account.dismissExpiry,
                  style: TextButton.styleFrom(
                    foregroundColor: colors.onErrorContainer,
                  ),
                  child: const Text('知道了'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LoginForm extends StatefulWidget {
  const _LoginForm({
    required this.account, required this.switchToConcept, required this.returnToMyPage,
  });

  final Account account;
  final bool switchToConcept;
  final bool returnToMyPage;

  @override
  State<_LoginForm> createState() => _LoginFormState();
}

class _LoginFormState extends State<_LoginForm> {
  var _method = LoginMethod.phone;

  String? _error;
  bool _starting = false;

  final _mobile = TextEditingController();
  final _code = TextEditingController();
  final _username = TextEditingController();
  final _password = TextEditingController();
  bool _sendingCode = false;
  int _codeCountdown = 0;

  /// 验证码发出后的提示，例如剩余可获取次数。
  String? _codeHint;
  Timer? _countdownTimer;

  /// 手机号绑定多个账号时待选的账号列表；为空表示不走选择流程。
  List<KugouAccountOption> _accountOptions = const [];
  ({String mobile, String code})? _smsChallenge;

  /// 正在提交的账号，用于给对应列表项显示进度并禁用整列表防连点。
  int? _pendingUserId;

  @override
  void dispose() {
    _countdownTimer?.cancel();
    _mobile.dispose();
    _code.dispose();
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  void _selectMethod(LoginMethod method) {
    setState(() {
      _method = method;
      _error = null;
      _accountOptions = const [];
      _smsChallenge = null;
    });
  }

  Future<void> _sendCode() async {
    final auth = widget.account.auth;
    final mobile = _mobile.text.trim();
    if (auth == null || _sendingCode || _starting || _codeCountdown > 0) return;
    if (!RegExp(r'^1\d{10}$').hasMatch(mobile)) {
      setState(() => _error = '请输入 11 位手机号。');
      return;
    }
    setState(() {
      _sendingCode = true;
      _error = null;
    });
    try {
      final remaining = await auth.sendSmsCode(mobile, lite: true);
      if (!mounted) return;
      _code.clear();
      final resendAt = DateTime.now().add(const Duration(seconds: 60));
      setState(() {
        _codeHint = remaining == null
            ? '验证码已发送，请查看短信。'
            : '验证码已发送，本次还可再获取 $remaining 次。';
        _codeCountdown = 60;
      });
      _countdownTimer?.cancel();
      _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
        if (!mounted) {
          timer.cancel();
          return;
        }
        setState(() {
          final remainingMs = resendAt.difference(DateTime.now()).inMilliseconds;
          _codeCountdown = remainingMs <= 0 ? 0 : (remainingMs + 999) ~/ 1000;
          if (_codeCountdown <= 0) timer.cancel();
        });
      });
    } on KugouFailure catch (error) {
      if (mounted) setState(() => _error = error.message);
    } finally {
      if (mounted) setState(() => _sendingCode = false);
    }
  }

  Future<void> _acceptSession(KugouSession signedIn) async {
    final switching = widget.switchToConcept;
    if (switching && widget.account.session?.userid != signedIn.userid) {
      throw const KugouFailure('请用当前酷狗账号登录概念版。');
    }
    if (!mounted) return;
    final account = widget.account;
    final returnAfterLogin = switching || widget.returnToMyPage;
    final navigator = Navigator.of(context);
    final route = ModalRoute.of(context);
    await account.signIn(signedIn);
    // 登录后表单可能已被替换，只在原路由仍在前台时返回。
    if (returnAfterLogin && account.session != null && route?.isCurrent == true) {
      await navigator.maybePop();
    }
  }

  Future<void> _submit(
    Future<KugouSession> Function(KugouAuth auth) call, {
    ({String mobile, String code})? smsChallenge,
    int? userid,
  }) async {
    final auth = widget.account.auth;
    if (auth == null || _starting || _sendingCode) return;
    setState(() {
      _starting = true;
      _pendingUserId = userid;
      _error = null;
    });
    try {
      final session = await call(auth);
      if (!mounted) return;
      await _acceptSession(session);
    } on KugouMultiAccount catch (multi) {
      if (!mounted) return;
      setState(() {
        _accountOptions = multi.accounts;
        // 选账号时沿用已经验证过的手机号和验证码。
        _smsChallenge = smsChallenge;
        if (userid != null) _error = '酷狗暂未接受所选账号，请重试或返回重新获取验证码。';
      });
    } on KugouFailure catch (error) {
      if (mounted) setState(() => _error = error.message);
    } finally {
      if (mounted) {
        setState(() {
          _starting = false;
          _pendingUserId = null;
        });
      }
    }
  }

  Future<void> _loginBySms() async {
    final mobile = _mobile.text.trim();
    final code = _code.text.trim();
    if (!RegExp(r'^1\d{10}$').hasMatch(mobile)) {
      setState(() => _error = '请输入 11 位手机号。');
      return;
    }
    if (!RegExp(r'^\d{4,6}$').hasMatch(code)) {
      setState(() => _error = '请输入收到的验证码。');
      return;
    }
    await _submit(
      (auth) => auth.loginWithSms(mobile, code, lite: true),
      smsChallenge: (mobile: mobile, code: code),
    );
  }

  /// 选定账号后用同一组手机号与验证码重新登录。
  Future<void> _loginWithSelectedAccount(KugouAccountOption option) async {
    final challenge = _smsChallenge;
    if (challenge == null) return;
    await _submit(
      (auth) => auth.loginWithSms(
        challenge.mobile,
        challenge.code,
        userid: option.userid,
        lite: true,
      ),
      smsChallenge: challenge,
      userid: option.userid,
    );
  }

  Future<void> _loginByPassword() async {
    final username = _username.text.trim();
    final password = _password.text;
    if (username.isEmpty || password.isEmpty) {
      setState(() => _error = '请输入酷狗账号和密码。');
      return;
    }
    await _submit((auth) => auth.loginWithPassword(username, password, lite: true));
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('登录酷狗账号',
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          children: [
            for (final method in LoginMethod.values)
              ChoiceChip(
                label: Text(switch (method) {
                  LoginMethod.phone => '手机号',
                  LoginMethod.password => '账号密码',
                }),
                selected: method == _method,
                onSelected: _starting || _sendingCode
                    ? null
                    : (selected) {
                        if (selected) _selectMethod(method);
                      },
              ),
          ],
        ),
        const SizedBox(height: 18),
        switch (_method) {
          LoginMethod.phone =>
            _accountOptions.isEmpty ? _buildPhone() : _buildAccountChooser(),
          LoginMethod.password => _buildPassword(),
        },
        if (_error case final error?)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(error, style: TextStyle(color: colors.error)),
          ),
      ],
    );
  }

  Widget _buildPhone() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      TextField(
        controller: _mobile,
        enabled: !_starting && !_sendingCode,
        keyboardType: TextInputType.phone,
        autofillHints: const [AutofillHints.telephoneNumberNational],
        onChanged: (_) {
          _code.clear();
          setState(() {
            _codeHint = null;
            _error = null;
          });
        },
        decoration: const InputDecoration(labelText: '手机号'),
      ),
      const SizedBox(height: 12),
      Row(
        children: [
          Expanded(
            child: TextField(
              controller: _code,
              enabled: !_starting && !_sendingCode,
              keyboardType: TextInputType.number,
              autofillHints: const [AutofillHints.oneTimeCode],
              decoration: const InputDecoration(labelText: '验证码'),
            ),
          ),
          const SizedBox(width: 12),
          OutlinedButton(
            onPressed: _starting || _sendingCode || _codeCountdown > 0
                ? null
                : _sendCode,
            child: Text(
              _codeCountdown > 0
                  ? '$_codeCountdown 秒'
                  : (_sendingCode ? '发送中…' : '获取验证码'),
            ),
          ),
        ],
      ),
      if (_codeHint case final hint?)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(hint, style: Theme.of(context).textTheme.bodySmall),
        ),
      const SizedBox(height: 16),
      FilledButton(
        onPressed: _starting || _sendingCode ? null : _loginBySms,
        child: Text(_starting ? '登录中…' : '登录'),
      ),
    ],
  );

  /// 一个手机号绑多个账号时的选择列表。
  Widget _buildAccountChooser() {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '该手机号绑定了 ${_accountOptions.length} 个账号，请选择要登录的账号',
          style: theme.textTheme.bodyMedium,
        ),
        const SizedBox(height: 8),
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 320),
          child: SingleChildScrollView(
            child: Column(
              children: [
                for (final option in _accountOptions)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: CircleAvatar(
                      backgroundColor: colors.secondaryContainer,
                      foregroundImage:
                          option.avatar.isEmpty ? null : NetworkImage(option.avatar),
                      onForegroundImageError:
                          option.avatar.isEmpty ? null : (_, _) {},
                      child: Text(
                        option.label.characters.first,
                        style: TextStyle(color: colors.onSecondaryContainer),
                      ),
                    ),
                    title: Text(option.label),
                    subtitle: Text(
                      option.username.isEmpty
                          ? 'UID ${option.userid}'
                          : '${option.username} · UID ${option.userid}',
                    ),
                    // 整列表禁用，避免连点并发登录被风控。
                    trailing: _pendingUserId == option.userid
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.chevron_right),
                    enabled: _pendingUserId == null,
                    onTap: () => _loginWithSelectedAccount(option),
                  ),
              ],
            ),
          ),
        ),
        TextButton(
          onPressed: _pendingUserId == null
              ? () => setState(() {
                  _accountOptions = const [];
                  _smsChallenge = null;
                  _error = null;
                })
              : null,
          child: const Text('返回重新输入验证码'),
        ),
      ],
    );
  }

  Widget _buildPassword() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      TextField(
        controller: _username,
        decoration: const InputDecoration(labelText: '酷狗账号 / 手机号'),
      ),
      const SizedBox(height: 12),
      TextField(
        controller: _password,
        obscureText: true,
        decoration: const InputDecoration(labelText: '密码'),
        onSubmitted: (_) => _loginByPassword(),
      ),
      const SizedBox(height: 16),
      FilledButton(
        onPressed: _starting ? null : _loginByPassword,
        child: Text(_starting ? '登录中…' : '登录'),
      ),
    ],
  );
}

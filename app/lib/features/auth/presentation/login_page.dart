import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../data/auth_repository.dart';

/// 登录 / 注册页（全屏路由，不占底部导航）。
///
/// 未登录时路由守卫会把用户带到这里；登录成功后自动跳回课表页。
class LoginPage extends ConsumerStatefulWidget {
  const LoginPage({super.key});

  @override
  ConsumerState<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends ConsumerState<LoginPage> {
  final _formKey = GlobalKey<FormState>();
  final _accountController = TextEditingController(); // 登录：用户名或邮箱
  final _usernameController = TextEditingController(); // 注册：用户名
  final _emailController = TextEditingController(); // 注册：邮箱
  final _passwordController = TextEditingController();

  bool _isRegisterMode = false;
  bool _obscurePassword = true;
  bool _submitting = false;

  @override
  void dispose() {
    _accountController.dispose();
    _usernameController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _submitting = true);

    final notifier = ref.read(authStateProvider.notifier);
    final error = _isRegisterMode
        ? await notifier.register(
            _usernameController.text.trim(),
            _emailController.text.trim(),
            _passwordController.text,
          )
        : await notifier.login(
            _accountController.text.trim(),
            _passwordController.text,
          );

    if (!mounted) return;
    setState(() => _submitting = false);
    if (error != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(error)));
    }
    // 成功时无需手动跳转：路由守卫监听登录态自动切到课表页
  }

  Future<void> _showForgotPasswordDialog() async {
    final emailController = TextEditingController();
    final codeController = TextEditingController();
    final newPasswordController = TextEditingController();
    final repo = ref.read(authRepositoryProvider);
    var codeSent = false;

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('重置密码'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: emailController,
                keyboardType: TextInputType.emailAddress,
                decoration: const InputDecoration(labelText: '注册邮箱'),
              ),
              if (codeSent) ...[
                TextField(
                  controller: codeController,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: '邮箱验证码（6 位）'),
                ),
                TextField(
                  controller: newPasswordController,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: '新密码（至少 8 位）'),
                ),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () async {
                final messenger = ScaffoldMessenger.of(context);
                try {
                  if (!codeSent) {
                    await repo.sendResetCode(emailController.text.trim());
                    setDialogState(() => codeSent = true);
                    messenger.showSnackBar(
                      const SnackBar(content: Text('验证码已发送，请查收邮箱（10 分钟内有效）')),
                    );
                  } else {
                    await repo.resetPassword(
                      emailController.text.trim(),
                      codeController.text.trim(),
                      newPasswordController.text,
                    );
                    if (dialogContext.mounted) {
                      Navigator.of(dialogContext).pop();
                    }
                    messenger.showSnackBar(
                      const SnackBar(content: Text('密码已重置，请用新密码登录')),
                    );
                  }
                } catch (e) {
                  messenger.showSnackBar(
                    SnackBar(
                        content:
                            Text(apiErrorMessage(e, fallback: '操作失败，请稍后重试'))),
                  );
                }
              },
              child: Text(codeSent ? '确认重置' : '发送验证码'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Form(
              key: _formKey,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Icon(
                    Icons.calendar_month,
                    size: 64,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    '邗上课表',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 32),

                  // ---- 表单字段 ----
                  if (_isRegisterMode) ...[
                    TextFormField(
                      controller: _usernameController,
                      decoration: const InputDecoration(
                        labelText: '用户名',
                        prefixIcon: Icon(Icons.person_outline),
                        border: OutlineInputBorder(),
                      ),
                      validator: (v) => (v == null || v.trim().length < 2)
                          ? '用户名至少 2 个字符'
                          : null,
                    ),
                    const SizedBox(height: 16),
                    TextFormField(
                      controller: _emailController,
                      keyboardType: TextInputType.emailAddress,
                      decoration: const InputDecoration(
                        labelText: '邮箱',
                        prefixIcon: Icon(Icons.email_outlined),
                        border: OutlineInputBorder(),
                      ),
                      validator: (v) =>
                          (v == null || !v.contains('@')) ? '请输入有效邮箱' : null,
                    ),
                    const SizedBox(height: 16),
                  ] else ...[
                    TextFormField(
                      controller: _accountController,
                      decoration: const InputDecoration(
                        labelText: '用户名或邮箱',
                        prefixIcon: Icon(Icons.person_outline),
                        border: OutlineInputBorder(),
                      ),
                      validator: (v) =>
                          (v == null || v.trim().isEmpty) ? '请输入用户名或邮箱' : null,
                    ),
                    const SizedBox(height: 16),
                  ],
                  TextFormField(
                    controller: _passwordController,
                    obscureText: _obscurePassword,
                    decoration: InputDecoration(
                      labelText: '密码',
                      prefixIcon: const Icon(Icons.lock_outline),
                      border: const OutlineInputBorder(),
                      suffixIcon: IconButton(
                        icon: Icon(_obscurePassword
                            ? Icons.visibility_off_outlined
                            : Icons.visibility_outlined),
                        onPressed: () => setState(
                            () => _obscurePassword = !_obscurePassword),
                      ),
                    ),
                    validator: (v) {
                      if (v == null || v.isEmpty) return '请输入密码';
                      if (_isRegisterMode && v.length < 8) return '密码至少 8 位';
                      return null;
                    },
                  ),
                  const SizedBox(height: 24),

                  // ---- 主按钮 ----
                  FilledButton(
                    onPressed: _submitting ? null : _submit,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: _submitting
                          ? const SizedBox(
                              height: 20,
                              width: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Text(_isRegisterMode ? '注册并登录' : '登录'),
                    ),
                  ),
                  const SizedBox(height: 12),

                  // ---- 辅助操作 ----
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      TextButton(
                        onPressed: () =>
                            setState(() => _isRegisterMode = !_isRegisterMode),
                        child: Text(_isRegisterMode ? '已有账号？去登录' : '没有账号？去注册'),
                      ),
                      if (!_isRegisterMode)
                        TextButton(
                          onPressed: _showForgotPasswordDialog,
                          child: const Text('忘记密码'),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

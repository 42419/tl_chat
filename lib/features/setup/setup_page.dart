import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app.dart';
import '../../core/providers.dart';
import '../../core/settings/app_settings.dart';

/// 首次配置引导页（Material 3）。
///
/// 收集：昵称（也是 tailnet 主机名）、中心服务地址与端口、Auth key
/// （仅首次注册需要，不持久化）。保存后进入主界面并自动连接。
class SetupPage extends ConsumerStatefulWidget {
  const SetupPage({super.key, this.onComplete});

  final VoidCallback? onComplete;

  @override
  ConsumerState<SetupPage> createState() => _SetupPageState();
}

class _SetupPageState extends ConsumerState<SetupPage> {
  final _nickname = TextEditingController();
  final _serverHost = TextEditingController();
  final _serverPort = TextEditingController(text: '8600');
  final _authKey = TextEditingController();

  final _formKey = GlobalKey<FormState>();
  int _step = 0;

  @override
  void dispose() {
    _nickname.dispose();
    _serverHost.dispose();
    _serverPort.dispose();
    _authKey.dispose();
    super.dispose();
  }

  Future<void> _finish() async {
    final nickname = _nickname.text.trim();
    final host = _serverHost.text.trim();
    final port = int.tryParse(_serverPort.text.trim()) ?? 8600;
    final authKey = _authKey.text.trim();

    final settings = AppSettings(
      nickname: nickname,
      serverHost: host,
      serverPort: port,
    );
    await AppSettings.save(settings);
    SetupResult.authKey = authKey.isEmpty ? null : authKey;
    if (!mounted) return;
    ref.read(appSettingsProvider.notifier).state = settings;
    widget.onComplete?.call();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 32),
              // 步骤指示器。
              Row(
                children: [
                  for (var i = 0; i < 2; i++) ...[
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 300),
                      height: 4,
                      width: i == 0 ? 36 : 16,
                      decoration: BoxDecoration(
                        color: i <= _step
                            ? scheme.primary
                            : scheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    if (i == 0) const SizedBox(width: 6),
                  ],
                ],
              ),
              const SizedBox(height: 40),
              Expanded(
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 260),
                  switchInCurve: Curves.easeOutCubic,
                  child: _step == 0 ? _stepOne(scheme) : _stepTwo(scheme),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _stepOne(ColorScheme scheme) {
    return Column(
      key: const ValueKey('step1'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '设置你的昵称',
          style: Theme.of(context).textTheme.headlineSmall?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          '这是其他人在聊天中看到的名字，\n同时也是你在 tailnet 上的主机名。',
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: scheme.onSurfaceVariant,
            height: 1.5,
          ),
        ),
        const SizedBox(height: 28),
        TextField(
          controller: _nickname,
          autofocus: true,
          textInputAction: TextInputAction.next,
          decoration: const InputDecoration(
            labelText: '昵称',
            hintText: '例如：小明',
            prefixIcon: Icon(Icons.person_outline),
          ),
        ),
        const Spacer(),
        FilledButton.icon(
          onPressed: () {
            if (_nickname.text.trim().isEmpty) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('请输入昵称')),
              );
              return;
            }
            setState(() => _step = 1);
          },
          icon: const Icon(Icons.arrow_forward),
          label: const Text('下一步'),
        ),
        const SizedBox(height: 24),
      ],
    );
  }

  Widget _stepTwo(ColorScheme scheme) {
    return Form(
      key: _formKey,
      child: Column(
        key: const ValueKey('step2'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '连接聊天服务',
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '输入管理员提供的内网服务地址。\n首次注册需要 Auth key（向管理员获取）。',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: scheme.onSurfaceVariant,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 24),
          TextField(
            controller: _serverHost,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: '服务地址',
              hintText: '例如：armbian 或 100.x.x.x',
              prefixIcon: Icon(Icons.dns_outlined),
            ),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _serverPort,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: '端口',
              prefixIcon: Icon(Icons.numbers),
            ),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _authKey,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: 'Auth key',
              hintText: '首次注册必填，之后不再需要',
              prefixIcon: Icon(Icons.key_outlined),
            ),
          ),
          const Spacer(),
          Row(
            children: [
              TextButton(
                onPressed: () => setState(() => _step = 0),
                child: const Text('上一步'),
              ),
              const Spacer(),
              FilledButton.icon(
                onPressed: () {
                  final host = _serverHost.text.trim();
                  if (host.isEmpty) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('请输入服务地址')),
                    );
                    return;
                  }
                  final port = int.tryParse(_serverPort.text.trim());
                  if (port == null || port < 1 || port > 65535) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('端口范围 1-65535')),
                    );
                    return;
                  }
                  _finish();
                },
                icon: const Icon(Icons.check),
                label: const Text('完成'),
              ),
            ],
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

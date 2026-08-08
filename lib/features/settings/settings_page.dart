import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app.dart';
import '../../core/models/models.dart';
import '../../core/providers.dart';
import '../../core/settings/app_settings.dart';

/// 设置页。
class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(appSettingsProvider);
    final client = ref.watch(chatClientProvider);
    final themeMode = ref.watch(themeModeProvider);
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        children: [
          // 个人信息卡。
          ListTile(
            leading: CircleAvatar(
              radius: 26,
              backgroundColor: scheme.primaryContainer,
              child: Text(
                settings.nickname.isNotEmpty
                    ? settings.nickname[0].toUpperCase()
                    : '?',
                style: TextStyle(
                  fontSize: 20,
                  color: scheme.onPrimaryContainer,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            title: Text(
              settings.nickname.isEmpty ? '未设置昵称' : settings.nickname,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            subtitle: Text(
              client.status.isConnected
                  ? '已连接 · ${client.myNodeId ?? ''}'
                  : client.statusText,
            ),
          ),
          const Divider(height: 1),
          const SizedBox(height: 8),
          _groupLabel(context, '外观'),
          ListTile(
            leading: const Icon(Icons.brightness_6_outlined),
            title: const Text('深色模式'),
            trailing: SegmentedButton<ThemeMode>(
              segments: const [
                ButtonSegment(
                  value: ThemeMode.system,
                  icon: Icon(Icons.brightness_auto_outlined),
                  label: Text('跟随'),
                ),
                ButtonSegment(
                  value: ThemeMode.light,
                  icon: Icon(Icons.light_mode_outlined),
                  label: Text('浅色'),
                ),
                ButtonSegment(
                  value: ThemeMode.dark,
                  icon: Icon(Icons.dark_mode_outlined),
                  label: Text('深色'),
                ),
              ],
              selected: {themeMode},
              showSelectedIcon: false,
              onSelectionChanged: (s) =>
                  ref.read(themeModeProvider.notifier).state = s.first,
            ),
          ),
          const SizedBox(height: 8),
          _groupLabel(context, '连接'),
          ListTile(
            leading: const Icon(Icons.dns_outlined),
            title: const Text('服务地址'),
            subtitle: Text(
              '${settings.serverHost.isEmpty ? '未配置' : settings.serverHost}:${settings.serverPort}',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _editConnection(context, ref),
          ),
          ListTile(
            leading: const Icon(Icons.link_outlined),
            title: const Text('连接状态'),
            subtitle: Text(
              client.status == ConnectionStatus.connected
                  ? '已连接（断线自动重连）'
                  : client.statusText,
            ),
          ),
          if (client.status.isConnected)
            ListTile(
              leading: const Icon(Icons.link_off),
              title: const Text('断开连接'),
              onTap: () => ref.read(chatClientProvider).disconnect(),
            ),
          const SizedBox(height: 8),
          _groupLabel(context, '数据'),
          ListTile(
            leading: const Icon(Icons.delete_sweep_outlined),
            title: const Text('清除本地缓存'),
            subtitle: const Text('删除本机聊天记录，服务端记录不受影响'),
            onTap: () => _confirmClearCache(context, ref),
          ),
          const SizedBox(height: 8),
          _groupLabel(context, '关于'),
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: const Text('关于 TL Chat'),
            onTap: () => _showAbout(context, ref),
          ),
          const SizedBox(height: 32),
        ],
      ),
    );
  }

  Widget _groupLabel(BuildContext context, String text) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 2),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 13,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Future<void> _editConnection(BuildContext context, WidgetRef ref) async {
    final settings = ref.read(appSettingsProvider);
    final host = TextEditingController(text: settings.serverHost);
    final port = TextEditingController(text: '${settings.serverPort}');
    final authKey = TextEditingController();
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('连接设置'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: host,
              decoration: const InputDecoration(
                labelText: '服务地址',
                hintText: '例如：armbian 或 100.x.x.x',
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: port,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: '端口'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: authKey,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'Auth key（可选）',
                hintText: '首次注册 / 重新注册时填写',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (result != true) {
      host.dispose();
      port.dispose();
      authKey.dispose();
      return;
    }
    final newHost = host.text.trim();
    final newPort = int.tryParse(port.text.trim()) ?? settings.serverPort;
    final key = authKey.text.trim();
    host.dispose();
    port.dispose();
    authKey.dispose();

    if (newHost.isNotEmpty) {
      final updated = AppSettings(
        nickname: settings.nickname,
        serverHost: newHost,
        serverPort: newPort,
      );
      await AppSettings.save(updated);
      ref.read(appSettingsProvider.notifier).state = updated;
    }
    if (key.isNotEmpty) SetupResult.authKey = key;
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('设置已保存，正在重新连接…')),
    );
  }

  Future<void> _confirmClearCache(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清除本地缓存？'),
        content: const Text('将删除本机缓存的聊天记录（不影响服务端，重新连接后自动恢复）。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('清除'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await ref.read(chatClientProvider).clearLocalCache();
    }
  }

  void _showAbout(BuildContext context, WidgetRef ref) {
    final settings = ref.read(appSettingsProvider);
    showAboutDialog(
      context: context,
      applicationName: 'TL Chat',
      applicationVersion: '1.0.0',
      applicationLegalese:
          '基于 Tailscale 内网穿透的轻量聊天应用。\n\n服务地址：${settings.serverHost.isEmpty ? '—' : settings.serverHost}:${settings.serverPort}',
      children: [
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('技术栈'),
          subtitle: const Text('Flutter · Material 3 · tailscale_dart · Node.js'),
        ),
      ],
    );
  }
}

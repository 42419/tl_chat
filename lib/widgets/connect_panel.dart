import 'package:flutter/material.dart';

import 'package:tl_chat/theme/telegram_theme.dart';

/// Connection configuration panel rendered on the home page: hostname / hub
/// inputs, connect button, tailscale status line, and clear-cache action.
/// Extracted from the home page so its body stays focused on layout; all
/// state and callbacks are injected via the constructor.
class ConnectPanel extends StatefulWidget {
  const ConnectPanel({
    super.key,
    required this.showPanel,
    required this.hostname,
    required this.hubHost,
    required this.hubPort,
    required this.authKey,
    required this.lastError,
    required this.connected,
    required this.tailscaleNote,
    required this.tailscaleReady,
    required this.onClearLocalCache,
    required this.onConnect,
    required this.onHidePanel,
  });

  final bool showPanel;
  final TextEditingController hostname;
  final TextEditingController hubHost;
  final TextEditingController hubPort;
  final TextEditingController authKey;
  final String? lastError;
  final bool connected;
  final String tailscaleNote;
  final bool tailscaleReady;
  final VoidCallback onClearLocalCache;
  final VoidCallback onConnect;
  final VoidCallback onHidePanel;

  @override
  State<ConnectPanel> createState() => _ConnectPanelState();
}

class _ConnectPanelState extends State<ConnectPanel> {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = TgPalette.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Back out of the inline connect panel to offline browsing.
              if (widget.showPanel) ...[
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: widget.onHidePanel,
                    icon: const Icon(Icons.arrow_back, size: 16),
                    label: const Text('返回离线记录'),
                    style: TextButton.styleFrom(
                      foregroundColor: palette.subtext,
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                ),
                const SizedBox(height: 4),
              ],
              const SizedBox(height: 8),
              Center(
                child: Container(
                  width: 72,
                  height: 72,
                  decoration: BoxDecoration(
                    color: Tg.blue.withValues(alpha: 0.12),
                    shape: BoxShape.circle,
                  ),
                  alignment: Alignment.center,
                  child: const Icon(
                    Icons.hub_outlined,
                    size: 36,
                    color: Tg.blue,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Center(
                child: Text(
                  '接入 Hub',
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Center(
                child: Text(
                  '通过 Tailscale 内网连接聊天中心节点。',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: palette.subtext,
                  ),
                ),
              ),
              const SizedBox(height: 28),
              TextField(
                controller: widget.hostname,
                decoration: const InputDecoration(
                  labelText: '节点主机名',
                  hintText: '本机在 tailnet 中的名字',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: widget.hubHost,
                decoration: const InputDecoration(
                  labelText: 'Hub 主机',
                  hintText: '例如 armbian',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: widget.hubPort,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Hub 端口'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: widget.authKey,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'Auth key（可选）',
                  hintText: '首次注册时填写',
                ),
              ),
              if (widget.lastError != null) ...[
                const SizedBox(height: 14),
                Text(
                  widget.lastError!,
                  style: theme.textTheme.bodySmall?.copyWith(color: Tg.error),
                ),
              ],
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: widget.onClearLocalCache,
                  icon: const Icon(Icons.delete_outline, size: 16),
                  label: const Text('清除本地缓存'),
                  style: TextButton.styleFrom(
                    foregroundColor: palette.subtext,
                    visualDensity: VisualDensity.compact,
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Text(
                widget.tailscaleNote,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: palette.subtext,
                ),
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: widget.tailscaleReady && !widget.connected
                      ? widget.onConnect
                      : null,
                  icon: const Icon(Icons.link, size: 18),
                  label: const Text('连接'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

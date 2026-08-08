import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tailscale/tailscale.dart';

import '../../app.dart';
import '../../core/models/models.dart';
import '../../core/network/chat_client.dart';
import '../../core/network/tailscale_service.dart';
import '../../core/providers.dart';
import '../../services/notification_service.dart';
import '../chat/chat_page.dart';
import '../chat/conversation_list_page.dart';
import '../contacts/contacts_page.dart';
import '../settings/settings_page.dart';

/// 主界面：底部 NavigationBar（消息 / 通讯录 / 设置）。
///
/// 负责连接生命周期：进入即自动连接（微信式无感）；首次连接用全屏
/// overlay 展示；之后的断线由顶部横幅 + 自动重连处理。
class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key});

  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell> {
  int _tab = 0;

  bool _connecting = false;
  String? _connectError;
  bool _connectedOnce = false;
  StreamSubscription<ChatMessage>? _notifSub;

  @override
  void initState() {
    super.initState();
    unawaited(_initNotifications());
    unawaited(_connect());
  }

  @override
  void dispose() {
    _notifSub?.cancel();
    super.dispose();
  }

  /// 初始化通知系统并订阅入站消息（非当前会话 / 后台时弹通知）。
  Future<void> _initNotifications() async {
    final notifications = NotificationService.instance;
    final client = ref.read(chatClientProvider); // await 前捕获，避免用后失效
    await notifications.init();
    if (!mounted) return;
    _notifSub = client.incomingMessages.listen((msg) {
      final appVisible =
          WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
      final convActive =
          ref.read(activeConversationProvider) == msg.conversationId;
      if (appVisible && convActive) return; // 正在看这个会话，不打扰
      unawaited(
        notifications.showMessageNotification(
          title: client.displayName(msg.senderId),
          body: msg.text,
        ),
      );
    });
  }

  Future<void> _connect() async {
    final client = ref.read(chatClientProvider);
    final settings = ref.read(appSettingsProvider);
    if (settings.serverHost.isEmpty) return;
    if (client.status.isConnected) return;

    setState(() {
      _connecting = true;
      _connectError = null;
    });
    try {
      // 1. Tailscale 上线（首次注册/登录需要 authKey）。
      final tailscale = ref.read(tailscaleServiceProvider);
      final state = (await tailscale.status()).state;
      final needAuth =
          state == NodeState.noState ||
          state == NodeState.needsLogin ||
          state == NodeState.needsMachineAuth;
      final authKey = needAuth ? SetupResult.authKey : null;
      await tailscale.up(hostname: settings.nickname, authKey: authKey);
      // 注册/登录成功：state 已持久化到磁盘，此后不再需要 key。
      // 立即从内存清除（敏感信息）。失败时此行不会执行，key 保留供重试。
      SetupResult.authKey = null;

      // 2. 解析服务地址（主机名 → tailnet IP）。
      final address = await _resolveAddress(settings.serverHost, tailscale);

      // 3. 连接。
      await client.connect(
        hubHost: address,
        hubPort: settings.serverPort,
        hostname: settings.nickname,
      );
      // 连接成功后启动前台保活（防止后台被系统杀掉导致断线）。
      unawaited(NotificationService.instance.startKeepAlive());
      if (mounted) {
        setState(() {
          _connectedOnce = true;
          _connecting = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _connecting = false;
          _connectError = e is ChatException
              ? e.message
              : e.toString().replaceFirst('Exception: ', '');
        });
      }
    }
  }

  /// 设置页改了服务地址：先断开（关掉自动重连），再按新配置连接。
  Future<void> _reconnectAfterSettingsChange() async {
    final client = ref.read(chatClientProvider);
    await client.disconnect();
    await _connect();
  }

  Future<String> _resolveAddress(
    String host,
    TailscaleService tailscale,
  ) async {
    final trimmed = host.trim();
    if (RegExp(r'^\d+\.\d+\.\d+\.\d+$').hasMatch(trimmed)) return trimmed;
    final lower = trimmed.toLowerCase();
    final deadline = DateTime.now().add(const Duration(seconds: 15));
    while (DateTime.now().isBefore(deadline)) {
      try {
        final nodes = await tailscale.nodes();
        for (final node in nodes) {
          final name = node.hostName.toLowerCase();
          final dns = node.dnsName.toLowerCase();
          if (name == lower || dns == lower || dns.startsWith('$lower.')) {
            final ip = node.ipv4;
            if (ip != null) return ip;
          }
        }
      } catch (_) {}
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    return trimmed;
  }

  void _openChat(String peerId) {
    Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => ChatPage(peerId: peerId)));
  }

  @override
  Widget build(BuildContext context) {
    final client = ref.watch(chatClientProvider);
    // 服务地址/端口变更（设置页保存后）→ 断开并重新连接。
    ref.listen(appSettingsProvider, (prev, next) {
      if (prev == null) return;
      if (next.serverHost != prev.serverHost ||
          next.serverPort != prev.serverPort) {
        unawaited(_reconnectAfterSettingsChange());
      }
    });
    // 首次连接：全屏 overlay。
    if (!_connectedOnce) {
      return Scaffold(body: _connectOverlay(context));
    }
    return Scaffold(
      body: Column(
        children: [
          if (_shouldShowBanner(client)) _connectionBanner(client),
          Expanded(
            child: IndexedStack(
              index: _tab,
              children: [
                ConversationListPage(onOpenChat: _openChat),
                ContactsPage(onOpenChat: _openChat),
                SettingsPage(),
              ],
            ),
          ),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.chat_bubble_outline),
            selectedIcon: Icon(Icons.chat_bubble),
            label: '消息',
          ),
          NavigationDestination(
            icon: Icon(Icons.people_outline),
            selectedIcon: Icon(Icons.people),
            label: '通讯录',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings),
            label: '设置',
          ),
        ],
      ),
    );
  }

  bool _shouldShowBanner(ChatClient client) {
    if (client.status.isConnected) return false;
    if (_connecting) return false;
    return true;
  }

  Widget _connectionBanner(ChatClient client) {
    final scheme = Theme.of(context).colorScheme;
    final reconnecting = client.status == ConnectionStatus.reconnecting;
    final text = reconnecting
        ? '连接断开，正在重连…'
        : client.status == ConnectionStatus.connecting
        ? '连接中…'
        : '网络连接失败，请检查网络设置';
    return Material(
      color: scheme.errorContainer,
      child: SafeArea(
        bottom: false,
        child: InkWell(
          onTap: reconnecting ? null : _connect,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                if (reconnecting ||
                    client.status == ConnectionStatus.connecting)
                  SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: scheme.onErrorContainer,
                    ),
                  )
                else
                  Icon(
                    Icons.cloud_off,
                    size: 16,
                    color: scheme.onErrorContainer,
                  ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    text,
                    style: TextStyle(
                      color: scheme.onErrorContainer,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                if (!reconnecting)
                  Text(
                    '重试',
                    style: TextStyle(
                      color: scheme.onErrorContainer,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _connectOverlay(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hasError = _connectError != null;
    return ColoredBox(
      color: scheme.surface,
      child: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 40),
            child: hasError
                ? Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.cloud_off, size: 64, color: scheme.outline),
                      const SizedBox(height: 20),
                      Text(
                        '连接失败',
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          color: scheme.error,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        _connectError!,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: scheme.onSurfaceVariant,
                          height: 1.5,
                        ),
                      ),
                      const SizedBox(height: 28),
                      FilledButton.icon(
                        onPressed: _connect,
                        icon: const Icon(Icons.refresh),
                        label: const Text('重试'),
                      ),
                    ],
                  )
                : Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      SizedBox(
                        width: 44,
                        height: 44,
                        child: CircularProgressIndicator(
                          strokeWidth: 3,
                          color: scheme.primary,
                        ),
                      ),
                      const SizedBox(height: 24),
                      Text(
                        '正在连接…',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '正在通过 Tailscale 连接到内网',
                        style: TextStyle(color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}

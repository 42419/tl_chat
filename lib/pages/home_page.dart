import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:tailscale/tailscale.dart';

import 'package:tl_chat/network/chat_client.dart';
import 'package:tl_chat/network/chat_settings.dart';
import 'package:tl_chat/services/notifications.dart';
import 'package:tl_chat/pages/chat_page.dart';
import 'package:tl_chat/theme/telegram_theme.dart';
import 'package:tl_chat/widgets/connect_panel.dart';
import 'package:tl_chat/widgets/conversation_tile.dart';
import 'package:tl_chat/widgets/skeleton_conversation_list.dart';

// ─── home: connection setup + conversation list ────────────────────────

class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.dark, required this.onToggleTheme});

  final bool dark;
  final VoidCallback onToggleTheme;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final ChatClient _client = ChatClient();
  final _hostname = TextEditingController(text: 'tl-chat-phone');
  final _hubHost = TextEditingController(text: 'armbian');
  final _hubPort = TextEditingController(text: '8600');
  final _authKey = TextEditingController();
  final _search = TextEditingController();

  String? _stateDir;
  bool _tailscaleReady = false;
  String _tailscaleNote = '初始化中…';
  String _searchQuery = '';

  /// True when the user tapped 去连接 from the offline-browsing banner, so the
  /// connect panel is shown inline (replacing the cached conversation list)
  /// and benefits from the home page's AnimatedBuilder rebuilds.
  bool _showPanel = false;

  /// Auto-login (WeChat/QQ style): once a node has registered, every later
  /// launch reconnects by itself instead of asking the user to tap 连接.
  bool _autoLoginInFlight = false;
  bool _autoLoginDone = false;

  /// 通知点击监听器 id（点击通知打开对应会话）。
  int? _notificationTapListener;

  @override
  void initState() {
    super.initState();
    unawaited(_init());
    _notificationTapListener = NotificationService.instance.addTapListener(
      _openConversationFromNotification,
    );
  }

  @override
  void dispose() {
    final listener = _notificationTapListener;
    if (listener != null) {
      NotificationService.instance.removeTapListener(listener);
    }
    _client.dispose();
    _hostname.dispose();
    _hubHost.dispose();
    _hubPort.dispose();
    _authKey.dispose();
    _search.dispose();
    super.dispose();
  }

  /// 通知点击 / 冷启动点击：打开对应会话（群聊或 1:1，payload 已编码类型）。
  void _openConversationFromNotification(NotificationConversation conv) {
    if (!mounted) return;
    _openChat(conv.id, isRoom: conv.isRoom);
  }

  /// Startup sequence: restore local history, load saved hub settings
  /// (prefilling the connect panel), then auto-login if the node was already
  /// registered in a previous session.
  Future<void> _init() async {
    // Restore locally cached history so chats are browsable offline before
    // (or without) connecting to the hub. Awaited (not fire-and-forget) so
    // the room-name registry is in memory before auto-login pulls history —
    // otherwise history-rebuilt conversations could win with roomId titles.
    await _client.loadLocalCache();
    final settings = await ChatSettings.load();
    if (!mounted) return;
    _hostname.text = settings.hostname;
    _hubHost.text = settings.hubHost;
    _hubPort.text = '${settings.hubPort}';
    await _loadStateDir();
    await _maybeAutoLogin();
  }

  Future<void> _loadStateDir() async {
    String path;
    try {
      final support = await getApplicationSupportDirectory();
      path = p.join(support.path, 'tailscale');
    } catch (_) {
      path = p.join(p.join('.'), 'tailscale_demo');
    }
    if (!mounted) return;
    setState(() {
      _stateDir = path;
      _tailscaleReady = true;
      _tailscaleNote = 'Tailscale 就绪';
    });
  }

  /// Auto-login (WeChat/QQ style): when the node was already registered in a
  /// previous session (persisted Tailscale credentials exist), reconnect
  /// automatically on launch — no auth key, no 连接 tap. First launch
  /// (NodeState.noState) leaves the connect panel up instead.
  Future<void> _maybeAutoLogin() async {
    final stateDir = _stateDir;
    if (!_tailscaleReady || stateDir == null) return;
    if (_autoLoginDone || _client.connected) return;

    NodeState state;
    try {
      Tailscale.init(stateDir: stateDir, logLevel: TailscaleLogLevel.error);
      state = (await Tailscale.instance.status()).state;
    } catch (_) {
      // Engine not ready yet — nothing to auto-login with; show the panel.
      return;
    }
    // noState = never authenticated. needsLogin / needsMachineAuth want the
    // auth flow (the latter: authenticated but awaiting admin approval) — all
    // of those intentionally fall through to the connect panel.
    if (state == NodeState.noState ||
        state == NodeState.needsLogin ||
        state == NodeState.needsMachineAuth) {
      return;
    }

    if (!mounted) return;
    setState(() {
      _autoLoginInFlight = true;
      _tailscaleNote = '自动连接中…';
    });
    try {
      await _connect();
    } catch (_) {
      // _connect already surfaced the error via _tailscaleNote (visible on the
      // connect panel); give immediate feedback here too since the user may be
      // browsing the cached conversation list instead.
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('自动连接失败'),
            action: SnackBarAction(label: '重试', onPressed: _showConnectPanel),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _autoLoginInFlight = false;
          _autoLoginDone = true;
        });
      }
    }
  }

  Future<void> _connect() async {
    if (!_tailscaleReady) return;
    final stateDir = _stateDir;
    if (stateDir == null) return;

    final hostname = _hostname.text.trim();
    final hubHost = _hubHost.text.trim();
    final port = int.tryParse(_hubPort.text.trim()) ?? 8600;

    setState(() => _tailscaleNote = '启动 Tailscale 节点…');

    try {
      Tailscale.init(stateDir: stateDir, logLevel: TailscaleLogLevel.error);
      await _tailscaleUp(hostname);
      setState(() => _tailscaleNote = 'Tailscale 已连接，解析 Hub 地址…');
      final hubAddress = await _resolveHubAddress(hubHost);
      setState(() => _tailscaleNote = 'Tailscale 已连接，接入 Hub…');
      await _client.connect(
        hubHost: hubAddress,
        hubPort: port,
        hostname: hostname,
      );
      if (mounted) {
        // Remember these settings so the next launch can auto-login.
        unawaited(
          ChatSettings.save(
            ChatSettings(hostname: hostname, hubHost: hubHost, hubPort: port),
          ),
        );
        // 连接成功后启动前台服务，保证后台持续接收消息。
        unawaited(NotificationService.instance.startKeepAlive());
        setState(() => _showPanel = false);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _tailscaleNote = '连接失败：$e');
      }
    }
  }

  /// Resolves a tailnet hostname to a node IP via the inventory, retrying
  /// briefly while a freshly (re)connected node syncs its netmap — dialing
  /// by MagicDNS name too early fails with `lookup <host>: no such host`.
  /// Returns the host unchanged when it's already an IP or resolution times
  /// out, so the underlying dial error surfaces instead of being swallowed.
  Future<String> _resolveHubAddress(String hubHost) async {
    final host = hubHost.trim();
    if (host.isEmpty) return host;
    if (RegExp(r'^\d+\.\d+\.\d+\.\d+$').hasMatch(host)) return host;
    final lower = host.toLowerCase();
    final deadline = DateTime.now().add(const Duration(seconds: 15));
    while (DateTime.now().isBefore(deadline)) {
      try {
        final nodes = await Tailscale.instance.nodes();
        for (final node in nodes) {
          final name = node.hostName.toLowerCase();
          final dns = node.dnsName.toLowerCase();
          if (name == lower || dns == lower || dns.startsWith('$lower.')) {
            final ip = node.ipv4;
            if (ip != null) return ip;
          }
        }
      } catch (_) {
        // Inventory not ready yet; keep polling until the deadline.
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    return host;
  }

  Future<void> _tailscaleUp(String hostname) async {
    try {
      // Only pass the auth key on the very first registration. tailscale_dart's
      // Go Start() wipes the state dir and re-registers a brand-new node
      // whenever up() is called with an authKey while the engine is already
      // running — retrying a failed connect would otherwise spawn duplicate
      // devices in the tailnet. After first registration, omit the auth key so
      // up() reconnects from persisted credentials instead.
      final status = await Tailscale.instance.status();
      final firstRegistration = status.state == NodeState.noState;
      final authKey = _authKey.text.trim();
      if (firstRegistration && authKey.isEmpty) {
        throw const TailscaleUpException('首次注册需要填写 Auth key');
      }
      await Tailscale.instance.up(
        hostname: hostname,
        authKey: firstRegistration && authKey.isNotEmpty ? authKey : null,
        timeout: const Duration(seconds: 45),
      );
    } on TailscaleUpException catch (e) {
      if (mounted) {
        setState(() => _tailscaleNote = 'Tailscale 启动异常：${e.message}');
      }
      rethrow;
    }
  }

  Future<void> _disconnect() async {
    await _client.disconnect();
    // 断开后无需再保活，停止前台服务。
    await NotificationService.instance.stopKeepAlive();
    if (mounted) setState(() {});
  }

  /// Switches the home body to the connect panel (used from the offline
  /// banner). Inline swap keeps the home page's AnimatedBuilder rebuilding the
  /// panel with live connection progress/errors.
  void _showConnectPanel() {
    setState(() => _showPanel = true);
  }

  Future<void> _clearLocalCache() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: TgPalette.of(context).elevated,
        title: const Text('清除本地缓存？'),
        content: const Text('将删除本机缓存的聊天记录（不影响 Hub 上的服务器记录，重新连接后会自动恢复）。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('清除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _client.clearLocalCache();
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('本地缓存已清除')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = TgPalette.of(context);
    return Scaffold(
      backgroundColor: palette.panel,
      appBar: AppBar(
        title: Row(
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: const BoxDecoration(
                color: Tg.blue,
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: const Icon(Icons.send, size: 17, color: Colors.white),
            ),
            const SizedBox(width: 10),
            const Text('TL Chat'),
          ],
        ),
        actions: [
          _connectionBadge(theme),
          IconButton(
            onPressed: widget.onToggleTheme,
            icon: Icon(
              widget.dark
                  ? Icons.light_mode_outlined
                  : Icons.dark_mode_outlined,
            ),
            tooltip: '切换主题',
          ),
          if (_client.connected)
            IconButton(
              onPressed: _disconnect,
              icon: const Icon(Icons.link_off, size: 20),
              tooltip: '断开连接',
            ),
          const SizedBox(width: 4),
        ],
      ),
      body: SafeArea(
        child: AnimatedBuilder(
          animation: _client,
          builder: (context, _) {
            // First launch / auto-login with no cached history: show a
            // skeleton instead of a blank connect panel.
            if (_client.phase == ConnectionPhase.connecting && !_showPanel) {
              return const SkeletonConversationList();
            }
            // Offline browsing: show cached conversations even when not
            // connected (they were restored from the local cache). The connect
            // panel shows inline when there is nothing cached yet or when the
            // user explicitly chose 去连接 from the offline banner.
            if (_client.connected ||
                (_client.conversations.isNotEmpty && !_showPanel)) {
              return _conversationList(context);
            }
            return ConnectPanel(
              showPanel: _showPanel,
              hostname: _hostname,
              hubHost: _hubHost,
              hubPort: _hubPort,
              authKey: _authKey,
              lastError: _client.lastError,
              connected: _client.connected,
              tailscaleNote: _tailscaleNote,
              tailscaleReady: _tailscaleReady,
              onClearLocalCache: _clearLocalCache,
              onConnect: _connect,
              onHidePanel: () => setState(() => _showPanel = false),
            );
          },
        ),
      ),
      floatingActionButton: AnimatedSwitcher(
        duration: const Duration(milliseconds: 250),
        transitionBuilder: (child, anim) => ScaleTransition(
          scale: CurvedAnimation(parent: anim, curve: Curves.easeOutBack),
          child: child,
        ),
        child: _client.connected
            ? FloatingActionButton(
                key: const ValueKey('fab-connected'),
                onPressed: _newChatSheet,
                backgroundColor: Tg.blue,
                foregroundColor: Colors.white,
                shape: const CircleBorder(),
                tooltip: '新建会话',
                child: const Icon(Icons.edit, size: 22),
              )
            : const SizedBox.shrink(key: ValueKey('fab-hidden')),
      ),
    );
  }

  /// Bottom sheet to start a new 1:1 chat with an online node or create a
  /// group room (Telegram-style "new message" FAB).
  void _newChatSheet() {
    final palette = TgPalette.of(context);
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: palette.elevated,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '发起会话',
                  style: Theme.of(sheetContext).textTheme.titleMedium,
                ),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.group_add, color: Tg.blue),
              title: const Text('新建群聊'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                _createRoomDialog();
              },
            ),
            ListTile(
              leading: const Icon(Icons.group_outlined, color: Tg.blue),
              title: const Text('加入群聊'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                _joinRoomSheet();
              },
            ),
            if (_client.onlineNodes.isEmpty)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  '暂无在线节点',
                  style: Theme.of(
                    sheetContext,
                  ).textTheme.bodySmall?.copyWith(color: palette.subtext),
                ),
              )
            else
              for (final node in _client.onlineNodes)
                ListTile(
                  leading: TgAvatar(
                    id: node,
                    size: 42,
                    title: _client.displayName(node),
                    online: true,
                  ),
                  title: Text(_client.displayName(node)),
                  subtitle: const Text('在线'),
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    _openChat(node, isRoom: false);
                  },
                ),
          ],
        ),
      ),
    );
  }

  Widget _connectionBadge(ThemeData theme) {
    final text = switch (_client.phase) {
      ConnectionPhase.connected => '已连接',
      ConnectionPhase.connecting => '连接中',
      ConnectionPhase.reconnecting => '重连中',
      ConnectionPhase.failed => '连接失败',
      ConnectionPhase.unconnected => '未连接',
    };
    final color = switch (_client.phase) {
      ConnectionPhase.connected => Tg.online,
      ConnectionPhase.failed => Tg.error,
      _ => Tg.sent,
    };
    return Center(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(9999),
        ),
        child: Text(
          text,
          style: theme.textTheme.labelMedium?.copyWith(
            color: color,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }

  // ─── conversation list (Telegram style) ────────────────────────────

  Widget _conversationList(BuildContext context) {
    final theme = Theme.of(context);
    final palette = TgPalette.of(context);
    final conversations = _client.conversations.toList()
      ..sort((a, b) {
        // Pinned conversations float to the top; the rest by recency.
        if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
        return b.lastTs.compareTo(a.lastTs);
      });
    final query = _searchQuery.trim().toLowerCase();
    final filtered = query.isEmpty
        ? conversations
        : conversations
              .where((c) => c.title.toLowerCase().contains(query))
              .toList();
    final reconnecting = _client.phase == ConnectionPhase.reconnecting;

    return Column(
      children: [
        // Offline browsing banner: cached history is viewable without a
        // connection; offer a way back to the connect panel. While auto-login
        // or auto-reconnect is running, show progress instead (Telegram-style
        // silent reconnection).
        if (!_client.connected)
          Material(
            color: palette.chatBg,
            child: InkWell(
              onTap: _autoLoginInFlight || reconnecting
                  ? null
                  : _showConnectPanel,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                child: Row(
                  children: [
                    if (_autoLoginInFlight || reconnecting)
                      const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    else
                      Icon(Icons.cloud_off, size: 16, color: palette.subtext),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        reconnecting
                            ? '连接断开，正在重连…'
                            : _autoLoginInFlight
                            ? '正在自动连接…'
                            : '离线模式：显示本地缓存记录',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: palette.subtext,
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: _autoLoginInFlight || reconnecting
                          ? null
                          : _showConnectPanel,
                      child: Text(
                        _autoLoginInFlight || reconnecting ? '连接中' : '去连接',
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        // Search bar
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
          child: TextField(
            controller: _search,
            onChanged: (v) => setState(() => _searchQuery = v),
            decoration: InputDecoration(
              hintText: '搜索',
              prefixIcon: const Icon(Icons.search, size: 20),
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 10,
              ),
              fillColor: palette.chatBg,
              filled: true,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide.none,
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide.none,
              ),
            ),
          ),
        ),
        // Online nodes strip
        if (_client.onlineNodes.isNotEmpty) _onlineStrip(context),
        // Conversation list (pull-to-refresh: re-sync when connected, else
        // retry connecting; swipe actions on each tile via Slidable).
        Expanded(
          child: RefreshIndicator(
            onRefresh: () => _client.connected ? _client.refresh() : _connect(),
            child: filtered.isEmpty
                ? LayoutBuilder(
                    builder: (context, constraints) => SingleChildScrollView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      child: SizedBox(
                        height: constraints.maxHeight,
                        child: Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.forum_outlined,
                                size: 46,
                                color: palette.subtext.withValues(alpha: 0.6),
                              ),
                              const SizedBox(height: 10),
                              Text(
                                query.isEmpty
                                    ? '暂无会话\n点击右上角新建群聊，或从在线节点发起私聊'
                                    : '没有匹配的会话',
                                textAlign: TextAlign.center,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: palette.subtext,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  )
                : SlidableAutoCloseBehavior(
                    child: ListView.builder(
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: const EdgeInsets.only(bottom: 8),
                      itemCount: filtered.length,
                      itemBuilder: (context, i) {
                        final conv = filtered[i];
                        return ConversationTile(
                          conv: conv,
                          online: !conv.isRoom &&
                              _client.onlineNodes.contains(conv.id),
                          isMine: conv.id == _client.myNodeId,
                          onTogglePinned: () =>
                              _client.togglePinned(conv.id),
                          onMarkRead: () =>
                              _client.markConversationRead(conv.id),
                          onConfirmDelete: () =>
                              _confirmDeleteConversation(context, conv),
                          onOpenChat: () =>
                              _openChat(conv.id, isRoom: conv.isRoom),
                        );
                      },
                    ),
                  ),
          ),
        ),
      ],
    );
  }

  Widget _onlineStrip(BuildContext context) {
    final theme = Theme.of(context);
    final online = _client.onlineNodes;
    return SizedBox(
      height: 86,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        children: [
          for (final node in online)
            InkWell(
              onTap: () => _openChat(node, isRoom: false),
              borderRadius: BorderRadius.circular(12),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                child: Column(
                  children: [
                    TgAvatar(
                      id: node,
                      size: 52,
                      title: _client.displayName(node),
                      online: true,
                    ),
                    const SizedBox(height: 5),
                    SizedBox(
                      width: 64,
                      child: Text(
                        _client.displayName(node),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// Confirms deletion with the user, then removes the conversation locally
  /// and clears its history on the hub (both sides lose the messages).
  Future<void> _confirmDeleteConversation(
    BuildContext context,
    Conversation conv,
  ) async {
    final palette = TgPalette.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: palette.elevated,
        title: Text('删除「${conv.title}」？'),
        content: const Text('将清空双方的聊天记录，且无法恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Tg.error),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await _client.deleteConversation(conv.id);
    }
  }

  /// Bottom sheet listing existing rooms to join (P3: 查看/加入已有群).
  Future<void> _joinRoomSheet() async {
    final palette = TgPalette.of(context);
    List<RoomSummary> rooms;
    try {
      rooms = await _client.listRooms();
    } on HubException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(e.message)));
      }
      return;
    }
    if (!mounted) return;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: palette.elevated,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '加入群聊',
                  style: Theme.of(sheetContext).textTheme.titleMedium,
                ),
              ),
            ),
            if (rooms.isEmpty)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  '暂无群聊，先创建一个吧',
                  style: Theme.of(
                    sheetContext,
                  ).textTheme.bodySmall?.copyWith(color: palette.subtext),
                ),
              )
            else
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: rooms.length,
                  itemBuilder: (context, i) {
                    final room = rooms[i];
                    return ListTile(
                      leading: TgAvatar(
                        id: room.id,
                        size: 42,
                        title: room.name,
                        isRoom: true,
                      ),
                      title: Text(room.name),
                      subtitle: Text(
                        room.isMember
                            ? '${room.memberCount} 名成员 · 已加入'
                            : '${room.memberCount} 名成员',
                      ),
                      trailing: room.isMember
                          ? const Icon(
                              Icons.check_circle,
                              size: 20,
                              color: Tg.online,
                            )
                          : null,
                      onTap: () {
                        Navigator.of(sheetContext).pop();
                        _joinRoom(room);
                      },
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _joinRoom(RoomSummary room) async {
    if (!_client.connected) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('未连接，无法加入群聊')));
      return;
    }
    // Already a member — just open the (possibly cached) conversation.
    if (room.isMember) {
      _openChat(room.id, isRoom: true);
      return;
    }
    try {
      final joined = await _client.joinRoom(room.id);
      if (!joined) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('群不存在或无法加入')));
        }
        return;
      }
    } on HubException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(e.message)));
      }
      return;
    }
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('已加入群聊「${room.name}」')));
      _openChat(room.id, isRoom: true);
    }
  }

  Future<void> _createRoomDialog() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: TgPalette.of(context).elevated,
        title: const Text('新建群聊'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: '群聊名称'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('创建'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name == null || name.isEmpty) return;
    try {
      final roomId = await _client.createRoom(name);
      if (mounted && roomId.isNotEmpty) {
        _openChat(roomId, isRoom: true);
      }
    } on HubException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(e.message)));
      }
    }
  }

  void _openChat(String id, {required bool isRoom}) {
    // Create the conversation on demand so tapping an online node (with no
    // prior chat) starts a new 1:1 thread, and a room we already joined but
    // have no local conversation for (e.g. after cache clear) reopens
    // instead of silently doing nothing.
    final conv = isRoom
        ? (_client.conversationById(id) ??
              _client.ensureRoomConversation(id, id))
        : _client.openConversation(id);
    // Custom transition (fade + slight upward slide) instead of the default
    // Material push: feels like Telegram's secondary-screen transition.
    Navigator.of(context).push(
      PageRouteBuilder<void>(
        transitionDuration: const Duration(milliseconds: 300),
        reverseTransitionDuration: const Duration(milliseconds: 260),
        pageBuilder: (context, animation, secondaryAnimation) => ChatPage(
          client: _client,
          conversation: conv,
          onToggleTheme: widget.onToggleTheme,
        ),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          final curved = CurvedAnimation(
            parent: animation,
            curve: Curves.easeOutCubic,
            reverseCurve: Curves.easeInCubic,
          );
          return FadeTransition(
            opacity: curved,
            child: SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0, 0.06),
                end: Offset.zero,
              ).animate(curved),
              child: child,
            ),
          );
        },
      ),
    );
  }
}

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:tailscale/tailscale.dart';

import 'net/chat_client.dart';
import 'ui/telegram_theme.dart';

void main() {
  runApp(const ChatApp());
}

class ChatApp extends StatefulWidget {
  const ChatApp({super.key});

  @override
  State<ChatApp> createState() => _ChatAppState();
}

class _ChatAppState extends State<ChatApp> {
  bool _dark = false;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'TL Chat',
      debugShowCheckedModeBanner: false,
      theme: telegramLightTheme(),
      darkTheme: telegramDarkTheme(),
      themeMode: _dark ? ThemeMode.dark : ThemeMode.light,
      home: HomePage(dark: _dark, onToggleTheme: () {
        setState(() => _dark = !_dark);
      }),
    );
  }
}

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

  @override
  void initState() {
    super.initState();
    unawaited(_loadStateDir());
    // Restore locally cached history so chats are browsable offline before
    // (or without) connecting to the hub.
    unawaited(_client.loadLocalCache());
  }

  @override
  void dispose() {
    _client.dispose();
    _hostname.dispose();
    _hubHost.dispose();
    _hubPort.dispose();
    _authKey.dispose();
    _search.dispose();
    super.dispose();
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
        backgroundColor: TgPalette.of(context).panel,
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
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('本地缓存已清除')),
      );
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
              widget.dark ? Icons.light_mode_outlined : Icons.dark_mode_outlined,
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
            // Offline browsing: show cached conversations even when not
            // connected (they were restored from the local cache). The connect
            // panel shows inline when there is nothing cached yet or when the
            // user explicitly chose 去连接 from the offline banner.
            if (_client.connected || (_client.conversations.isNotEmpty && !_showPanel)) {
              return _conversationList(context);
            }
            return _connectPanel(theme);
          },
        ),
      ),
      floatingActionButton: _client.connected
          ? FloatingActionButton(
              onPressed: _newChatSheet,
              backgroundColor: Tg.blue,
              foregroundColor: Colors.white,
              shape: const CircleBorder(),
              tooltip: '新建会话',
              child: const Icon(Icons.edit, size: 22),
            )
          : null,
    );
  }

  /// Bottom sheet to start a new 1:1 chat with an online node or create a
  /// group room (Telegram-style "new message" FAB).
  void _newChatSheet() {
    final palette = TgPalette.of(context);
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: palette.panel,
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
            if (_client.onlineNodes.isEmpty)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  '暂无在线节点',
                  style: Theme.of(sheetContext).textTheme.bodySmall?.copyWith(
                    color: palette.subtext,
                  ),
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
    final text = _client.phase == ConnectionPhase.connected
        ? '已连接'
        : _client.phase == ConnectionPhase.connecting
        ? '连接中'
        : _client.phase == ConnectionPhase.failed
        ? '连接失败'
        : '未连接';
    final color = _client.phase == ConnectionPhase.connected
        ? Tg.online
        : _client.phase == ConnectionPhase.failed
        ? Tg.error
        : Tg.sent;
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

  // ─── connection panel ──────────────────────────────────────────────

  Widget _connectPanel(ThemeData theme) {
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
              if (_showPanel) ...[
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: () => setState(() => _showPanel = false),
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
                  child: const Icon(Icons.hub_outlined, size: 36, color: Tg.blue),
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
                controller: _hostname,
                decoration: const InputDecoration(
                  labelText: '节点主机名',
                  hintText: '本机在 tailnet 中的名字',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _hubHost,
                decoration: const InputDecoration(
                  labelText: 'Hub 主机',
                  hintText: '例如 armbian',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _hubPort,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Hub 端口'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _authKey,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'Auth key（可选）',
                  hintText: '首次注册时填写',
                ),
              ),
              if (_client.lastError != null) ...[
                const SizedBox(height: 14),
                Text(
                  _client.lastError!,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: Tg.error,
                  ),
                ),
              ],
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: _clearLocalCache,
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
                _tailscaleNote,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: palette.subtext,
                ),
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed:
                      _tailscaleReady && !_client.connected ? _connect : null,
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

  // ─── conversation list (Telegram style) ────────────────────────────

  Widget _conversationList(BuildContext context) {
    final theme = Theme.of(context);
    final palette = TgPalette.of(context);
    final conversations = _client.conversations.toList()
      ..sort((a, b) => b.lastTs.compareTo(a.lastTs));
    final query = _searchQuery.trim().toLowerCase();
    final filtered = query.isEmpty
        ? conversations
        : conversations
              .where((c) => c.title.toLowerCase().contains(query))
              .toList();

    return Column(
      children: [
        // Offline browsing banner: cached history is viewable without a
        // connection; offer a way back to the connect panel.
        if (!_client.connected)
          Material(
            color: palette.chatBg,
            child: InkWell(
              onTap: _showConnectPanel,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                child: Row(
                  children: [
                    Icon(Icons.cloud_off, size: 16, color: palette.subtext),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '离线模式：显示本地缓存记录',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: palette.subtext,
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: _showConnectPanel,
                      child: const Text('去连接'),
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
        // Conversation list
        Expanded(
          child: filtered.isEmpty
              ? Center(
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
                )
              : ListView.builder(
                  padding: const EdgeInsets.only(bottom: 8),
                  itemCount: filtered.length,
                  itemBuilder: (context, i) {
                    final conv = filtered[i];
                    return _conversationTile(context, conv);
                  },
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



  Widget _conversationTile(BuildContext context, Conversation conv) {
    final theme = Theme.of(context);
    final palette = TgPalette.of(context);
    final online = !conv.isRoom && _client.onlineNodes.contains(conv.id);
    final isMine = conv.id == _client.myNodeId;

    return InkWell(
      onTap: () => _openChat(conv.id, isRoom: conv.isRoom),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        child: Row(
          children: [
            TgAvatar(
              id: conv.id,
              size: 54,
              title: conv.title,
              online: online,
              isRoom: conv.isRoom,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          conv.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                            fontSize: 16,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        _tileTime(conv.lastTs),
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontSize: 13,
                          color: conv.unread > 0
                              ? Tg.blue
                              : palette.subtext,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          conv.lastPreview.isEmpty
                              ? '暂无消息'
                              : conv.lastPreview,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            fontSize: 14,
                            color: conv.unread > 0
                                ? palette.text
                                : palette.subtext,
                            fontWeight: conv.unread > 0
                                ? FontWeight.w500
                                : FontWeight.w400,
                          ),
                        ),
                      ),
                      if (conv.unread > 0) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 7,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: Tg.blue,
                            borderRadius: BorderRadius.circular(9999),
                          ),
                          constraints: const BoxConstraints(minWidth: 20),
                          alignment: Alignment.center,
                          child: Text(
                            conv.unread > 99 ? '99+' : '${conv.unread}',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ] else if (isMine && conv.messages.isNotEmpty)
                        Icon(
                          Icons.done_all,
                          size: 16,
                          color: Tg.sent.withValues(alpha: 0.7),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _tileTime(int ts) {
    if (ts == 0) return '';
    final t = DateTime.fromMillisecondsSinceEpoch(ts);
    final now = DateTime.now();
    final sameDay =
        t.year == now.year && t.month == now.month && t.day == now.day;
    if (sameDay) {
      final h = t.hour.toString().padLeft(2, '0');
      final m = t.minute.toString().padLeft(2, '0');
      return '$h:$m';
    }
    return '${t.month}/${t.day}';
  }

  Future<void> _createRoomDialog() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: TgPalette.of(context).panel,
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
    // prior chat) starts a new 1:1 thread instead of silently doing nothing.
    final conv = isRoom
        ? _client.conversationById(id)
        : _client.openConversation(id);
    if (conv == null) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => ChatPage(
          client: _client,
          conversation: conv,
          onToggleTheme: widget.onToggleTheme,
        ),
      ),
    );
  }
}

// ─── chat page: message bubbles + composer ────────────────────────────

class ChatPage extends StatefulWidget {
  const ChatPage({
    super.key,
    required this.client,
    required this.conversation,
    required this.onToggleTheme,
  });

  final ChatClient client;
  final Conversation conversation;
  final VoidCallback onToggleTheme;

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  final _composer = TextEditingController();
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    // Mark this conversation as the active one so incoming messages don't
    // bump its unread counter; clear its badge; and acknowledge everything
    // we've received so far to the peer (Telegram-style read receipt).
    widget.client.activeConversationId = widget.conversation.id;
    widget.client.markConversationRead(widget.conversation.id);
    widget.client.sendReadReceipt(widget.conversation.id);
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
  }

  @override
  void dispose() {
    if (widget.client.activeConversationId == widget.conversation.id) {
      widget.client.activeConversationId = null;
    }
    _composer.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _send() {
    final text = _composer.text;
    if (text.trim().isEmpty) return;
    if (!widget.client.connected) {
      // Offline browsing: cached history is readable, sending is not.
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('未连接，无法发送消息')),
      );
      return;
    }
    try {
      if (widget.conversation.isRoom) {
        widget.client.sendRoomMessage(widget.conversation.id, text);
      } else {
        widget.client.sendMessage(widget.conversation.id, text);
      }
    } on HubException catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.message)),
      );
      return;
    }
    _composer.clear();
    _scrollToBottom();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = TgPalette.of(context);
    return Scaffold(
      backgroundColor: palette.chatBg,
      appBar: AppBar(
        titleSpacing: 0,
        leadingWidth: 64,
        leading: IconButton(
          onPressed: () => Navigator.of(context).pop(),
          icon: const Icon(Icons.arrow_back, size: 22),
        ),
        title: Row(
          children: [
            TgAvatar(
              id: widget.conversation.id,
              size: 38,
              title: widget.conversation.title,
              isRoom: widget.conversation.isRoom,
              online: _clientIsOnline(widget.conversation.id),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.conversation.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    widget.conversation.isRoom
                        ? '群聊'
                        : (_clientIsOnline(widget.conversation.id)
                            ? '在线'
                            : '离线'),
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontSize: 12,
                      color: _clientIsOnline(widget.conversation.id)
                          ? Tg.online
                          : palette.subtext,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            onPressed: widget.onToggleTheme,
            // Read from the live theme (not a captured flag) so the affordance
            // stays correct after toggling inside this route.
            icon: Icon(
              Theme.of(context).brightness == Brightness.dark
                  ? Icons.light_mode_outlined
                  : Icons.dark_mode_outlined,
            ),
            tooltip: '切换主题',
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: AnimatedBuilder(
        animation: widget.client,
        builder: (context, _) => Column(
          children: [
            Expanded(
              child: widget.conversation.messages.isEmpty
                  ? _emptyState(theme)
                  : ListView.builder(
                      controller: _scroll,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 8,
                      ),
                      itemCount: widget.conversation.messages.length,
                      itemBuilder: (context, i) {
                        final msg = widget.conversation.messages[i];
                        final prev = i > 0
                            ? widget.conversation.messages[i - 1]
                            : null;
                        return Column(
                          children: [
                            if (prev == null || !_sameDay(prev.ts, msg.ts))
                              _dateChip(context, msg.ts),
                            _messageBubble(context, msg),
                          ],
                        );
                      },
                    ),
            ),
            _composerBar(),
          ],
        ),
      ),
    );
  }

  bool _sameDay(int a, int b) {
    final da = DateTime.fromMillisecondsSinceEpoch(a);
    final db = DateTime.fromMillisecondsSinceEpoch(b);
    return da.year == db.year && da.month == db.month && da.day == db.day;
  }

  Widget _dateChip(BuildContext context, int ts) {
    final theme = Theme.of(context);
    final palette = TgPalette.of(context);
    final t = DateTime.fromMillisecondsSinceEpoch(ts);
    final now = DateTime.now();
    final yesterday = now.subtract(const Duration(days: 1));
    final sameDay =
        t.year == now.year && t.month == now.month && t.day == now.day;
    final isYesterday = t.year == yesterday.year &&
        t.month == yesterday.month &&
        t.day == yesterday.day;
    final label = sameDay
        ? '今天'
        : isYesterday
        ? '昨天'
        : '${t.year}年${t.month}月${t.day}日';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          decoration: BoxDecoration(
            color: palette.panel.withValues(alpha: 0.85),
            borderRadius: BorderRadius.circular(9999),
          ),
          child: Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
              fontSize: 12,
              color: palette.subtext,
            ),
          ),
        ),
      ),
    );
  }

  bool _clientIsOnline(String nodeId) {
    if (nodeId == widget.client.myNodeId) return true;
    return widget.client.onlineNodes.contains(nodeId);
  }

  Widget _emptyState(ThemeData theme) {
    final palette = TgPalette.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            widget.conversation.isRoom
                ? Icons.forum_outlined
                : Icons.chat_bubble_outline,
            size: 46,
            color: palette.subtext.withValues(alpha: 0.6),
          ),
          const SizedBox(height: 12),
          Text(
            widget.conversation.isRoom
                ? '群聊已创建，说点什么吧'
                : '对方离线时消息会缓存，上线后自动送达',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
              color: palette.subtext,
            ),
          ),
        ],
      ),
    );
  }

  Widget _messageBubble(BuildContext context, ChatMessage msg) {
    final theme = Theme.of(context);
    final palette = TgPalette.of(context);
    final isMine = msg.isMine;
    final showSender =
        !isMine && widget.conversation.isRoom && msg.from != widget.client.myNodeId;
    final senderName = showSender ? widget.client.displayName(msg.from) : '';

    return Align(
      alignment: isMine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 5),
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 8),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.78,
        ),
        decoration: BoxDecoration(
          color: isMine ? palette.outgoing : palette.incoming,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(17),
            topRight: const Radius.circular(17),
            bottomLeft: Radius.circular(isMine ? 17 : 5),
            bottomRight: Radius.circular(isMine ? 5 : 17),
          ),
          boxShadow: const [
            BoxShadow(
              color: Color(0x0d000000),
              blurRadius: 1,
              offset: Offset(0, 0.5),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            if (showSender) ...[
              Padding(
                padding: const EdgeInsets.only(bottom: 3),
                child: Text(
                  senderName,
                  style: TextStyle(
                    color: Tg.avatarFor(msg.from),
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
            if (!isMine && msg.queued)
              Padding(
                padding: const EdgeInsets.only(bottom: 3),
                child: Text(
                  '离线补发',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: palette.subtext,
                    fontSize: 10,
                    letterSpacing: 0,
                  ),
                ),
              ),
            Text(
              msg.text,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: palette.text,
                fontSize: 16,
                height: 1.35,
              ),
            ),
            const SizedBox(height: 2),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _formatTime(msg.ts),
                  style: TextStyle(
                    color: isMine ? Tg.sent : palette.subtext,
                    fontSize: 11,
                    letterSpacing: 0,
                  ),
                ),
                if (isMine) ...[
                  const SizedBox(width: 3),
                  _statusIcon(msg.status),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _statusIcon(MessageStatus status) {
    final icon = switch (status) {
      MessageStatus.sending => Icons.schedule,
      MessageStatus.sent => Icons.done,
      MessageStatus.delivered || MessageStatus.read => Icons.done_all,
    };
    final color = switch (status) {
      MessageStatus.sending || MessageStatus.sent => Tg.sent,
      MessageStatus.delivered => Tg.sent,
      MessageStatus.read => Tg.read,
    };
    return Icon(icon, size: 14, color: color);
  }

  Widget _composerBar() {
    final palette = TgPalette.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 6, 8, 8),
      decoration: BoxDecoration(
        color: palette.panel,
        border: Border(top: BorderSide(color: palette.hairline)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              decoration: BoxDecoration(
                color: palette.chatBg,
                borderRadius: BorderRadius.circular(22),
              ),
              child: TextField(
                controller: _composer,
                minLines: 1,
                maxLines: 5,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => _send(),
                decoration: InputDecoration(
                  hintText: '消息',
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  contentPadding: const EdgeInsets.symmetric(vertical: 9),
                  isDense: true,
                ),
              ),
            ),
          ),
          const SizedBox(width: 4),
          IconButton(
            onPressed: _send,
            icon: const Icon(Icons.send, color: Tg.blue, size: 24),
            tooltip: '发送',
          ),
        ],
      ),
    );
  }

  String _formatTime(int ts) {
    final t = DateTime.fromMillisecondsSinceEpoch(ts);
    final h = t.hour.toString().padLeft(2, '0');
    final m = t.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }
}

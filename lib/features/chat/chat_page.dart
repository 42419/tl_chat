import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/models.dart';
import '../../core/network/chat_client.dart';
import '../../core/providers.dart';

/// 聊天页（Material 3）。
///
/// 关键实现：
///   - `ListView.builder(reverse: true)`：新消息自然贴底，向上滚动加载历史
///   - 乐观发送：`sending` → ack 后 `sent` → 对方已读 `read`
///   - 打字指示（防抖发送 / TTL 显示）
///   - 滚出底部时新消息计入悬浮计数，点击回到底部
class ChatPage extends ConsumerStatefulWidget {
  const ChatPage({super.key, required this.peerId});

  /// 对方 nodeId。
  final String peerId;

  @override
  ConsumerState<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends ConsumerState<ChatPage> {
  final _composer = TextEditingController();
  final _composerFocus = FocusNode();
  final _scroll = ScrollController();

  late String _convId;
  late String _peerTitle;

  bool _loadingHistory = false;
  int _newCount = 0;
  bool _atBottom = true;
  late int _lastCount;

  Timer? _typingDebounce;

  /// 多选模式（长按菜单进入；底部切换为批量操作栏）。
  bool _multiSelect = false;
  final Set<String> _selected = {};

  @override
  void initState() {
    super.initState();
    final client = ref.read(chatClientProvider);
    final conv = client.conversationWith(widget.peerId);
    _convId = conv.id;
    _peerTitle = conv.title;
    _lastCount = conv.messages.length;

    ref.read(activeConversationProvider.notifier).state = _convId;
    client.markRead(_convId);
    client.sendReadReceipt(_convId);
    client.resetHistoryPaging(_convId);

    _composerFocus.addListener(() {
      if (!_composerFocus.hasFocus) {
        _typingDebounce?.cancel();
        client.sendTyping(_convId, on: false);
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) _scroll.jumpTo(0);
      _scroll.addListener(_onScroll);
    });
  }

  @override
  void dispose() {
    final client = ref.read(chatClientProvider);
    _typingDebounce?.cancel();
    client.sendTyping(_convId, on: false);
    if (ref.read(activeConversationProvider) == _convId) {
      ref.read(activeConversationProvider.notifier).state = null;
    }
    _scroll.removeListener(_onScroll);
    _composer.dispose();
    _composerFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final pos = _scroll.position;
    final atBottom = pos.pixels <= 40;
    if (atBottom != _atBottom) {
      setState(() {
        _atBottom = atBottom;
        if (atBottom) _newCount = 0;
      });
    }
    // reverse 列表：接近顶部（最大偏移）时加载更早历史。
    if (pos.pixels >= pos.maxScrollExtent - 60 && !_loadingHistory) {
      _loadMoreHistory();
    }
  }

  Future<void> _loadMoreHistory() async {
    if (_loadingHistory) return;
    final client = ref.read(chatClientProvider);
    if (client.hasNoMoreHistory(_convId)) return;
    final conv = client.conversationById(_convId);
    if (conv == null) return;
    int? oldestSeq;
    for (final m in conv.messages) {
      final s = m.seq;
      if (s != null && (oldestSeq == null || s < oldestSeq)) oldestSeq = s;
    }
    if (oldestSeq == null) return;

    double? oldOffset;
    double? oldMax;
    if (_scroll.hasClients) {
      oldOffset = _scroll.position.pixels;
      oldMax = _scroll.position.maxScrollExtent;
    }
    setState(() => _loadingHistory = true);
    try {
      await client.fetchHistory(_convId, beforeSeq: oldestSeq);
    } finally {
      if (mounted) setState(() => _loadingHistory = false);
    }
    // 保持视口锚点：新页 PREPEND 后偏移量增加的量恰好是新增高度。
    if (mounted && oldOffset != null && oldMax != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_scroll.hasClients) return;
        final added = _scroll.position.maxScrollExtent - oldMax!;
        if (added > 0) _scroll.jumpTo(oldOffset! + added);
      });
    }
  }

  void _send() {
    final text = _composer.text.trim();
    if (text.isEmpty) return;
    final client = ref.read(chatClientProvider);
    _typingDebounce?.cancel();
    try {
      client.sendText(widget.peerId, text);
    } on ChatException catch (e) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(e.message)));
      return;
    }
    client.sendTyping(_convId, on: false);
    _composer.clear();
    _scrollToBottom();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          0,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
        );
      }
    });
  }

  void _onComposerChanged(String v) {
    final client = ref.read(chatClientProvider);
    _typingDebounce?.cancel();
    if (v.trim().isEmpty) {
      client.sendTyping(_convId, on: false);
      return;
    }
    _typingDebounce = Timer(const Duration(milliseconds: 1200), () {
      client.sendTyping(_convId, on: true);
    });
  }

  @override
  Widget build(BuildContext context) {
    final client = ref.watch(chatClientProvider);
    final conv = client.conversationById(_convId);
    final messages = conv?.messages ?? const <ChatMessage>[];
    final online = client.onlineNodes.contains(widget.peerId);
    final typing = client.isTyping(_convId);
    final scheme = Theme.of(context).colorScheme;

    // 新消息计数（滚出底部时）。
    final count = messages.length;
    if (count > _lastCount && !_atBottom) {
      _newCount += count - _lastCount;
    }
    _lastCount = count;

    return Scaffold(
      appBar: AppBar(
        leading: _multiSelect
            ? IconButton(
                icon: const Icon(Icons.close),
                tooltip: '取消',
                onPressed: _exitMultiSelect,
              )
            : null,
        title: _multiSelect
            ? Text(
                '已选 ${_selected.length} 条',
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                ),
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _peerTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    typing ? '正在输入…' : (online ? '在线' : '离线'),
                    style: TextStyle(
                      fontSize: 12,
                      color: typing
                          ? scheme.primary
                          : (online ? Colors.green : scheme.onSurfaceVariant),
                    ),
                  ),
                ],
              ),
      ),
      body: Column(
        children: [
          if (_loadingHistory) const LinearProgressIndicator(minHeight: 2),
          Expanded(
            child: messages.isEmpty
                ? _emptyState(scheme)
                : Stack(
                    children: [
                      ListView.builder(
                        controller: _scroll,
                        reverse: true,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        itemCount: messages.length,
                        itemBuilder: (context, i) {
                          final msg = messages[messages.length - 1 - i];
                          final older = i < messages.length - 1
                              ? messages[messages.length - 2 - i]
                              : null;
                          final showDate =
                              older == null ||
                              !_sameDay(older.createdAt, msg.createdAt);
                          return Column(
                            children: [
                              if (showDate) _dateChip(msg.createdAt, scheme),
                              if (msg.recalled)
                                _recalledLine(msg, scheme, client)
                              else
                                _MessageBubble(
                                  msg: msg,
                                  isMine: client.isMine(msg),
                                  peerTitle: _peerTitle,
                                  connected: client.status.isConnected,
                                  selected:
                                      _multiSelect &&
                                      _selected.contains(msg.clientId),
                                  onTap: _multiSelect
                                      ? () => _toggleSelect(msg.clientId)
                                      : null,
                                  onLongPress: _multiSelect
                                      ? () => _toggleSelect(msg.clientId)
                                      : () => _showMessageMenu(context, msg),
                                ),
                            ],
                          );
                        },
                      ),
                      if (_newCount > 0)
                        Positioned(
                          bottom: 12,
                          left: 0,
                          right: 0,
                          child: Center(
                            child: ActionChip(
                              avatar: const Icon(
                                Icons.arrow_downward,
                                size: 16,
                              ),
                              label: Text('$_newCount 条新消息'),
                              onPressed: () {
                                setState(() => _newCount = 0);
                                _scrollToBottom();
                              },
                            ),
                          ),
                        ),
                    ],
                  ),
          ),
          _multiSelect ? _batchBar(scheme) : _inputBar(scheme, client),
        ],
      ),
    );
  }

  Widget _emptyState(ColorScheme scheme) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.waving_hand_outlined, size: 52, color: scheme.outline),
          const SizedBox(height: 12),
          Text('打个招呼吧', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            '对方离线时消息会暂存在服务端，上线后自动送达',
            style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
          ),
        ],
      ),
    );
  }

  Widget _dateChip(int ts, ColorScheme scheme) {
    final label = _formatDay(ts);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Text(
        label,
        style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
      ),
    );
  }

  Widget _inputBar(ColorScheme scheme, ChatClient client) {
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 8),
      decoration: BoxDecoration(
        color: scheme.surface,
        border: Border(top: BorderSide(color: scheme.outlineVariant)),
      ),
      child: SafeArea(
        top: false,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: TextField(
                controller: _composer,
                focusNode: _composerFocus,
                minLines: 1,
                maxLines: 4,
                textInputAction: TextInputAction.send,
                onChanged: _onComposerChanged,
                onSubmitted: (_) => _send(),
                decoration: InputDecoration(
                  hintText: '消息',
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 10,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: _composer,
              builder: (context, value, _) {
                final hasText = value.text.trim().isNotEmpty;
                return IconButton.filled(
                  onPressed: hasText ? _send : null,
                  icon: Icon(hasText ? Icons.send : Icons.send_outlined),
                  tooltip: '发送',
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showMessageMenu(BuildContext context, ChatMessage msg) async {
    final client = ref.read(chatClientProvider);
    final messenger = ScaffoldMessenger.of(context);
    final isMine = client.isMine(msg);
    final failed = isMine && msg.status == MessageStatus.failed;
    // 可撤回：自己的、非失败、未被撤回、已有 serverId（已到达服务端）。
    final canRecall =
        isMine && !msg.recalled && !failed && msg.serverId != null;
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.copy_outlined),
              title: const Text('复制'),
              onTap: () => Navigator.pop(ctx, 'copy'),
            ),
            ListTile(
              leading: const Icon(Icons.forward_outlined),
              title: const Text('转发'),
              onTap: () => Navigator.pop(ctx, 'forward'),
            ),
            if (canRecall)
              ListTile(
                leading: const Icon(Icons.undo),
                title: const Text('撤回'),
                onTap: () => Navigator.pop(ctx, 'recall'),
              ),
            if (failed)
              ListTile(
                leading: const Icon(Icons.refresh),
                title: const Text('重发'),
                onTap: () => Navigator.pop(ctx, 'resend'),
              ),
            ListTile(
              leading: const Icon(Icons.library_add_check_outlined),
              title: const Text('多选'),
              onTap: () => Navigator.pop(ctx, 'select'),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('删除（本机）'),
              onTap: () => Navigator.pop(ctx, 'delete'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || action == null) return;
    switch (action) {
      case 'copy':
        await Clipboard.setData(ClipboardData(text: msg.text));
        messenger.showSnackBar(
          const SnackBar(content: Text('已复制'), duration: Duration(seconds: 1)),
        );
        break;
      case 'forward':
        await _forwardSingle(msg);
        break;
      case 'recall':
        if (!client.status.isConnected) {
          messenger.showSnackBar(const SnackBar(content: Text('离线状态无法撤回')));
        } else {
          client.recallMessage(msg.serverId!);
          messenger.showSnackBar(
            const SnackBar(
              content: Text('已撤回'),
              duration: Duration(seconds: 1),
            ),
          );
        }
        break;
      case 'resend':
        client.resend(msg.clientId);
        break;
      case 'select':
        setState(() {
          _multiSelect = true;
          _selected.add(msg.clientId);
        });
        break;
      case 'delete':
        client.deleteMessageLocally(_convId, msg.clientId);
        break;
    }
  }

  // ─── 多选 / 转发 ────────────────────────────────────────────────────

  void _exitMultiSelect() {
    setState(() {
      _selected.clear();
      _multiSelect = false;
    });
  }

  void _toggleSelect(String clientId) {
    setState(() {
      if (!_selected.remove(clientId)) _selected.add(clientId);
    });
  }

  /// 选择转发目标（在线节点 + 最近聊过的人），返回 null 表示取消。
  Future<String?> _pickForwardTarget(ChatClient client) async {
    final list = client.contactCandidates()
      ..sort((a, b) {
        if (a.online != b.online) return a.online ? -1 : 1;
        return a.name.compareTo(b.name);
      });
    if (list.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('暂无可转发对象')));
      return null;
    }
    return showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Row(
                children: [
                  Text(
                    '转发给',
                    style: Theme.of(ctx).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: list.length,
                itemBuilder: (ctx, i) {
                  final c = list[i];
                  return ListTile(
                    leading: CircleAvatar(
                      radius: 18,
                      backgroundColor: Theme.of(
                        ctx,
                      ).colorScheme.secondaryContainer,
                      child: Text(
                        c.name.isNotEmpty ? c.name[0].toUpperCase() : '?',
                        style: TextStyle(
                          fontSize: 14,
                          color: Theme.of(ctx).colorScheme.onSecondaryContainer,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    title: Text(c.name),
                    subtitle: Text(c.online ? '在线' : '离线'),
                    onTap: () => Navigator.pop(ctx, c.id),
                  );
                },
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Future<void> _forwardSingle(ChatMessage msg) async {
    final client = ref.read(chatClientProvider);
    final target = await _pickForwardTarget(client);
    if (target == null || !mounted) return;
    client.forwardMessage(target, msg);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已转发'), duration: Duration(seconds: 1)),
    );
  }

  Future<void> _forwardSelected() async {
    final client = ref.read(chatClientProvider);
    final target = await _pickForwardTarget(client);
    if (target == null || !mounted) return;
    final conv = client.conversationById(_convId);
    final msgs = (conv?.messages ?? const <ChatMessage>[])
        .where((m) => _selected.contains(m.clientId))
        .toList();
    for (final m in msgs) {
      client.forwardMessage(target, m);
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('已转发 ${msgs.length} 条'),
        duration: const Duration(seconds: 1),
      ),
    );
    _exitMultiSelect();
  }

  Future<void> _deleteSelected() async {
    final client = ref.read(chatClientProvider);
    final count = _selected.length;
    if (count == 0) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除消息'),
        content: Text('确定删除选中的 $count 条消息？（仅本机删除）'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final conv = client.conversationById(_convId);
    final msgs = (conv?.messages ?? const <ChatMessage>[])
        .where((m) => _selected.contains(m.clientId))
        .toList();
    for (final m in msgs) {
      client.deleteMessageLocally(_convId, m.clientId);
    }
    _exitMultiSelect();
  }

  Widget _recalledLine(ChatMessage msg, ColorScheme scheme, ChatClient client) {
    final who = client.isMine(msg) ? '你' : _peerTitle;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Center(
        child: Text(
          '$who 撤回了一条消息',
          style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
        ),
      ),
    );
  }

  /// 多选模式下的批量操作栏（转发 / 删除）。
  Widget _batchBar(ColorScheme scheme) {
    final count = _selected.length;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: scheme.surface,
        border: Border(top: BorderSide(color: scheme.outlineVariant)),
      ),
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            TextButton.icon(
              onPressed: count == 0 ? null : _forwardSelected,
              icon: const Icon(Icons.forward_outlined),
              label: const Text('转发'),
            ),
            const Spacer(),
            Text(
              '已选 $count 条',
              style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
            ),
            const Spacer(),
            TextButton.icon(
              onPressed: count == 0 ? null : _deleteSelected,
              icon: Icon(Icons.delete_outline, color: scheme.error),
              label: Text('删除', style: TextStyle(color: scheme.error)),
            ),
          ],
        ),
      ),
    );
  }

  static bool _sameDay(int a, int b) {
    final da = DateTime.fromMillisecondsSinceEpoch(a);
    final db = DateTime.fromMillisecondsSinceEpoch(b);
    return da.year == db.year && da.month == db.month && da.day == db.day;
  }

  static String _formatDay(int ts) {
    final t = DateTime.fromMillisecondsSinceEpoch(ts);
    final now = DateTime.now();
    if (_sameDay(ts, now.millisecondsSinceEpoch)) return '今天';
    final yesterday = now.subtract(const Duration(days: 1));
    if (t.year == yesterday.year &&
        t.month == yesterday.month &&
        t.day == yesterday.day) {
      return '昨天';
    }
    return '${t.year}年${t.month}月${t.day}日';
  }
}

/// 单条消息气泡。
class _MessageBubble extends StatelessWidget {
  const _MessageBubble({
    required this.msg,
    required this.isMine,
    required this.peerTitle,
    required this.connected,
    required this.onLongPress,
    this.selected = false,
    this.onTap,
  });

  final ChatMessage msg;
  final bool isMine;
  final String peerTitle;
  final bool connected;
  final VoidCallback onLongPress;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bubbleColor = isMine
        ? scheme.primaryContainer
        : scheme.surfaceContainerHighest;
    final textColor = isMine ? scheme.onPrimaryContainer : scheme.onSurface;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisAlignment: isMine
            ? MainAxisAlignment.end
            : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (!isMine) ...[
            CircleAvatar(
              radius: 16,
              backgroundColor: scheme.secondaryContainer,
              child: Text(
                peerTitle.isNotEmpty ? peerTitle[0].toUpperCase() : '?',
                style: TextStyle(
                  fontSize: 13,
                  color: scheme.onSecondaryContainer,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(width: 8),
          ],
          Flexible(
            child: GestureDetector(
              onLongPress: onLongPress,
              onTap: onTap,
              child: Container(
                constraints: BoxConstraints(
                  maxWidth: MediaQuery.of(context).size.width * 0.68,
                ),
                padding: const EdgeInsets.symmetric(
                  horizontal: 13,
                  vertical: 9,
                ),
                decoration: BoxDecoration(
                  color: bubbleColor,
                  borderRadius: BorderRadius.only(
                    topLeft: const Radius.circular(16),
                    topRight: const Radius.circular(16),
                    bottomLeft: Radius.circular(isMine ? 16 : 4),
                    bottomRight: Radius.circular(isMine ? 4 : 16),
                  ),
                  border: selected
                      ? Border.all(color: scheme.primary, width: 2)
                      : null,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (msg.forwardedFrom != null &&
                        msg.forwardedFrom!.isNotEmpty) ...[
                      Text(
                        '转发自 ${msg.forwardedFrom}',
                        style: TextStyle(
                          fontSize: 11,
                          color: textColor.withValues(alpha: 0.7),
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 3),
                    ],
                    Text(
                      msg.text,
                      style: TextStyle(
                        fontSize: 16,
                        height: 1.35,
                        color: textColor,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          _formatTime(msg.createdAt),
                          style: TextStyle(
                            fontSize: 10,
                            color: textColor.withValues(alpha: 0.55),
                          ),
                        ),
                        if (isMine) ...[
                          const SizedBox(width: 4),
                          _statusIcon(msg.status, scheme, textColor),
                          if (msg.status == MessageStatus.sending && !connected)
                            Padding(
                              padding: const EdgeInsets.only(right: 2),
                              child: Text(
                                '待发送',
                                style: TextStyle(
                                  fontSize: 10,
                                  color: textColor.withValues(alpha: 0.55),
                                ),
                              ),
                            ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  static String _formatTime(int ts) {
    final t = DateTime.fromMillisecondsSinceEpoch(ts);
    final h = t.hour.toString().padLeft(2, '0');
    final m = t.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }

  static Widget _statusIcon(
    MessageStatus status,
    ColorScheme scheme,
    Color textColor,
  ) {
    final icon = switch (status) {
      MessageStatus.sending => Icons.schedule,
      MessageStatus.sent => Icons.check,
      MessageStatus.delivered || MessageStatus.read => Icons.done_all,
      MessageStatus.failed => Icons.error_outline,
    };
    final color = switch (status) {
      MessageStatus.sending ||
      MessageStatus.sent ||
      MessageStatus.delivered => textColor.withValues(alpha: 0.55),
      MessageStatus.read => scheme.primary,
      MessageStatus.failed => scheme.error,
    };
    return Icon(icon, size: 13, color: color);
  }
}

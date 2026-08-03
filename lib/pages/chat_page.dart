import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:tl_chat/network/chat_client.dart';
import 'package:tl_chat/theme/telegram_theme.dart';
import 'package:tl_chat/widgets/animated_bubble.dart';
import 'package:tl_chat/widgets/typing_subtitle.dart';

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
  final _composerFocus = FocusNode();
  final _scroll = ScrollController();

  /// Ids of messages that already existed when the page opened — they render
  /// statically. New ids are added here the first time they're built so each
  /// message's entrance animation plays exactly once (scroll-in/out doesn't
  /// replay it, since the set check is id-based, not index-based).
  late final Set<String> _animatedIds;

  /// Last observed message count, for the near-bottom auto-scroll.
  late int _lastCount;

  @override
  void initState() {
    super.initState();
    // Mark this conversation as the active one so incoming messages don't
    // bump its unread counter; clear its badge; and acknowledge everything
    // we've received so far to the peer (Telegram-style read receipt).
    widget.client.activeConversationId = widget.conversation.id;
    widget.client.markConversationRead(widget.conversation.id);
    widget.client.sendReadReceipt(widget.conversation.id);
    // Phase 2.1: focus loss = stop typing (user navigated away / switched
    // app without leaving the page). Fires only on focus→unfocus transitions.
    _composerFocus.addListener(() {
      if (!_composerFocus.hasFocus) {
        widget.client.stopTyping(
          widget.conversation.id,
          isRoom: widget.conversation.isRoom,
        );
      }
    });
    _animatedIds = {for (final m in widget.conversation.messages) m.id};
    _lastCount = widget.conversation.messages.length;
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
  }

  @override
  void dispose() {
    // Phase 2.1: leaving the page = stop typing (clears our outbound state
    // and notifies the peer so their indicator clears immediately).
    widget.client.stopTyping(
      widget.conversation.id,
      isRoom: widget.conversation.isRoom,
    );
    if (widget.client.activeConversationId == widget.conversation.id) {
      widget.client.activeConversationId = null;
    }
    _composer.dispose();
    _composerFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _send() {
    final text = _composer.text;
    if (text.trim().isEmpty) return;
    // Phase 1.4: sending works offline too — the message lands locally as
    // `sending` and is flushed automatically on the next reconnect. The hub's
    // clientMessageId idempotency map makes the re-send safe.
    try {
      if (widget.conversation.isRoom) {
        widget.client.sendRoomMessage(widget.conversation.id, text);
      } else {
        widget.client.sendMessage(widget.conversation.id, text);
      }
    } on HubException catch (e) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(e.message)));
      return;
    }
    // Phase 2.1: a real send ends the typing burst — tell the peer to stop.
    widget.client.stopTyping(
      widget.conversation.id,
      isRoom: widget.conversation.isRoom,
    );
    _composer.clear();
    _scrollToBottom(animate: true);
  }

  void _scrollToBottom({bool animate = false}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      final target = _scroll.position.maxScrollExtent;
      if (animate) {
        _scroll.animateTo(
          target,
          duration: const Duration(milliseconds: 260),
          curve: Curves.easeOutCubic,
        );
      } else {
        _scroll.jumpTo(target);
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
            // Gentle entrance (fade + slight scale) for the header avatar —
            // replaces the Hero fly-through that crashed mid-flight.
            TweenAnimationBuilder<double>(
              tween: Tween(begin: 0.72, end: 1),
              duration: const Duration(milliseconds: 320),
              curve: Curves.easeOutBack,
              builder: (context, scale, child) =>
                  Transform.scale(scale: scale, child: child),
              child: TgAvatar(
                id: widget.conversation.id,
                size: 38,
                title: widget.conversation.title,
                isRoom: widget.conversation.isRoom,
                online: _clientIsOnline(widget.conversation.id),
              ),
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
                  // Phase 2.1: typing indicator subtitle. When any peer is
                  // typing in this conversation, show 「正在输入…」 with a
                  // three-dot pulse animation instead of the online/offline
                  // line. Falls back to the original status text otherwise.
                  ListenableBuilder(
                    listenable: widget.client,
                    builder: (context, _) {
                      final typing =
                          widget.client.isTyping(widget.conversation.id);
                      if (typing) {
                        return TypingSubtitle(
                          isRoom: widget.conversation.isRoom,
                          senders: widget.conversation.isRoom
                              ? widget.client
                                    .typingSenders(widget.conversation.id)
                                    .map((n) => widget.client.displayName(n))
                                    .toList()
                              : const [],
                          onlineColor: Tg.online,
                          subtextColor: palette.subtext,
                          baseStyle: theme.textTheme.bodySmall ?? const TextStyle(),
                        );
                      }
                      final online = _clientIsOnline(widget.conversation.id);
                      return Text(
                        widget.conversation.isRoom
                            ? '群聊'
                            : (online ? '在线' : '离线'),
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontSize: 12,
                          color: online ? Tg.online : palette.subtext,
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          if (widget.conversation.isRoom)
            IconButton(
              onPressed: _showRoomMembers,
              icon: const Icon(Icons.people_outline, size: 20),
              tooltip: '群成员',
            ),
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
        builder: (context, _) {
          _maybeAutoScroll();
          return Column(
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
                              AnimatedBubble(
                                animate: _animatedIds.add(msg.id),
                                child: _messageBubble(context, msg),
                              ),
                            ],
                          );
                        },
                      ),
              ),
              _composerBar(),
            ],
          );
        },
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
    final isYesterday =
        t.year == yesterday.year &&
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

  /// Bottom sheet with the room's member list (P3: 查看群成员).
  Future<void> _showRoomMembers() async {
    final palette = TgPalette.of(context);
    RoomInfo info;
    try {
      info = await widget.client.roomMembers(widget.conversation.id);
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
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '群成员（${info.members.length}）',
                      style: Theme.of(sheetContext).textTheme.titleMedium,
                    ),
                  ),
                ],
              ),
            ),
            if (info.members.isEmpty)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  '暂无成员',
                  style: Theme.of(
                    sheetContext,
                  ).textTheme.bodySmall?.copyWith(color: palette.subtext),
                ),
              )
            else
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: info.members.length,
                  itemBuilder: (context, i) {
                    final m = info.members[i];
                    final isMe = m.id == widget.client.myNodeId;
                    final title = isMe
                        ? '${widget.client.displayName(m.id)}（我）'
                        : widget.client.displayName(m.id);
                    return ListTile(
                      leading: TgAvatar(
                        id: m.id,
                        size: 42,
                        title: widget.client.displayName(m.id),
                        online: m.online,
                      ),
                      title: Text(title),
                      subtitle: Text(m.online ? '在线' : '离线'),
                      trailing: isMe
                          ? null
                          : Icon(
                              m.online ? Icons.circle : Icons.circle_outlined,
                              size: 12,
                              color: m.online ? Tg.online : palette.subtext,
                            ),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
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
            widget.conversation.isRoom ? '群聊已创建，说点什么吧' : '对方离线时消息会缓存，上线后自动送达',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(color: palette.subtext),
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
        !isMine &&
        widget.conversation.isRoom &&
        msg.from != widget.client.myNodeId;
    final senderName = showSender ? widget.client.displayName(msg.from) : '';
    final failed = isMine && msg.status == MessageStatus.failed;

    return GestureDetector(
      onLongPressStart: (details) => _showMessageMenu(context, msg, details),
      behavior: HitTestBehavior.translucent,
      child: Align(
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
            border: failed
                ? Border.all(color: Tg.error.withValues(alpha: 0.6), width: 1)
                : null,
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
                  if (failed)
                    Padding(
                      padding: const EdgeInsets.only(right: 4),
                      child: Text(
                        '发送失败',
                        style: TextStyle(
                          color: Tg.error,
                          fontSize: 11,
                          letterSpacing: 0,
                        ),
                      ),
                    ),
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
      ),
    );
  }

  /// Long-press context menu on a message bubble (Phase 1.3):
  /// - 重发 (resend): only for failed own messages — reuses the original
  ///   clientMessageId so the hub dedupes.
  /// - 复制 (copy): any message.
  /// - 删除 (delete): only for failed own messages — local-only removal
  ///   (the message never reached the hub, so nothing to clear server-side).
  Future<void> _showMessageMenu(
    BuildContext context,
    ChatMessage msg,
    LongPressStartDetails details,
  ) async {
    final isMine = msg.isMine;
    final failed = isMine && msg.status == MessageStatus.failed;
    final items = <PopupMenuEntry<String>>[
      if (failed)
        const PopupMenuItem<String>(value: 'resend', child: Text('重发')),
      const PopupMenuItem<String>(value: 'copy', child: Text('复制')),
      if (failed)
        const PopupMenuItem<String>(value: 'delete', child: Text('删除')),
    ];
    if (items.isEmpty) return;
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final position = RelativeRect.fromRect(
      Rect.fromPoints(
        details.globalPosition,
        details.globalPosition,
      ),
      Offset.zero & overlay.size,
    );
    if (!mounted) return;
    final result = await showMenu<String>(
      context: context,
      position: position,
      items: items,
    );
    if (!mounted || result == null) return;
    switch (result) {
      case 'resend':
        final cmid = msg.clientMessageId;
        if (cmid != null) {
          widget.client.resendMessage(widget.conversation.id, cmid);
        }
        break;
      case 'copy':
        await Clipboard.setData(ClipboardData(text: msg.text));
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('已复制'), duration: Duration(seconds: 1)),
          );
        }
        break;
      case 'delete':
        widget.client.removeMessage(widget.conversation.id, msg.id);
        break;
    }
  }

  Widget _statusIcon(MessageStatus status) {
    final icon = switch (status) {
      MessageStatus.sending => Icons.schedule,
      MessageStatus.sent => Icons.done,
      MessageStatus.delivered || MessageStatus.read => Icons.done_all,
      MessageStatus.failed => Icons.error_outline,
    };
    final color = switch (status) {
      MessageStatus.sending || MessageStatus.sent => Tg.sent,
      MessageStatus.delivered => Tg.sent,
      MessageStatus.read => Tg.read,
      MessageStatus.failed => Tg.error,
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
            // Input pill: subtle blue border glow on focus.
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOutCubic,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              decoration: BoxDecoration(
                color: palette.chatBg,
                borderRadius: BorderRadius.circular(22),
                border: Border.all(
                  color: _composerFocus.hasFocus
                      ? Tg.blue.withValues(alpha: 0.5)
                      : Colors.transparent,
                  width: 1.2,
                ),
              ),
              child: TextField(
                controller: _composer,
                focusNode: _composerFocus,
                minLines: 1,
                maxLines: 5,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => _send(),
                // Phase 2.1: notify the typing state machine on every
                // keystroke. It internally debounces (≤1 frame / 3s) so this
                // can fire on every onChanged without spamming the hub.
                onChanged: (v) {
                  if (v.trim().isNotEmpty) {
                    widget.client.onTypingKeystroke(
                      widget.conversation.id,
                      isRoom: widget.conversation.isRoom,
                    );
                  } else {
                    // Cleared the field without sending — stop typing.
                    widget.client.stopTyping(
                      widget.conversation.id,
                      isRoom: widget.conversation.isRoom,
                    );
                  }
                },
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
          // Send button lights up (gray -> Telegram blue) once there is text.
          ListenableBuilder(
            listenable: _composer,
            builder: (context, _) {
              final hasText = _composer.text.trim().isNotEmpty;
              return IconButton(
                onPressed: hasText ? _send : null,
                tooltip: '发送',
                icon: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 200),
                  transitionBuilder: (child, anim) => ScaleTransition(
                    scale: CurvedAnimation(
                      parent: anim,
                      curve: Curves.easeOutBack,
                    ),
                    child: child,
                  ),
                  child: Icon(
                    hasText ? Icons.send : Icons.send_outlined,
                    key: ValueKey(hasText),
                    color: hasText ? Tg.blue : palette.subtext,
                    size: 24,
                  ),
                ),
              );
            },
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

  /// Smoothly scrolls to the newest message when the user is already near the
  /// bottom (or just sent one) — never yanks the list out from under someone
  /// reading history.
  void _maybeAutoScroll() {
    final count = widget.conversation.messages.length;
    if (count == _lastCount) return;
    final grew = count > _lastCount;
    _lastCount = count;
    if (!grew) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      final pos = _scroll.position;
      if (pos.maxScrollExtent - pos.pixels < 120) {
        _scroll.animateTo(
          pos.maxScrollExtent,
          duration: const Duration(milliseconds: 260),
          curve: Curves.easeOutCubic,
        );
      }
    });
  }
}

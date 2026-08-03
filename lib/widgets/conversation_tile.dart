import 'package:flutter/material.dart';
import 'package:flutter_slidable/flutter_slidable.dart';

import 'package:tl_chat/network/chat_client.dart';
import 'package:tl_chat/theme/telegram_theme.dart';

/// A single conversation row in the home page list: avatar, title, last
/// message preview, timestamp, unread badge, and swipe-to-act actions
/// (pin / mark-read / delete). Extracted from the home page; all data and
/// callbacks are injected via the constructor.
class ConversationTile extends StatefulWidget {
  const ConversationTile({
    super.key,
    required this.conv,
    required this.online,
    required this.isMine,
    required this.onTogglePinned,
    required this.onMarkRead,
    required this.onConfirmDelete,
    required this.onOpenChat,
  });

  final Conversation conv;
  final bool online;
  final bool isMine;
  final VoidCallback onTogglePinned;
  final VoidCallback onMarkRead;
  final VoidCallback onConfirmDelete;
  final VoidCallback onOpenChat;

  @override
  State<ConversationTile> createState() => _ConversationTileState();
}

class _ConversationTileState extends State<ConversationTile> {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = TgPalette.of(context);
    final conv = widget.conv;
    final online = widget.online;
    final isMine = widget.isMine;

    return Slidable(
      key: ValueKey('slidable-${conv.id}'),
      endActionPane: ActionPane(
        motion: const ScrollMotion(),
        extentRatio: 0.62,
        children: [
          SlidableAction(
            onPressed: (_) => widget.onTogglePinned(),
            backgroundColor: Tg.blue,
            foregroundColor: Colors.white,
            icon: conv.pinned ? Icons.push_pin_outlined : Icons.push_pin,
            label: conv.pinned ? '取消置顶' : '置顶',
          ),
          // 已读 only makes sense when there is something unread; the list
          // rebuilds on every notifyListeners so this stays live.
          if (conv.unread > 0)
            SlidableAction(
              onPressed: (_) => widget.onMarkRead(),
              backgroundColor: Tg.online,
              foregroundColor: Colors.white,
              icon: Icons.done_all,
              label: '已读',
            ),
          SlidableAction(
            onPressed: (_) => widget.onConfirmDelete(),
            backgroundColor: Tg.error,
            foregroundColor: Colors.white,
            icon: Icons.delete,
            label: '删除',
          ),
        ],
      ),
      child: InkWell(
        onTap: widget.onOpenChat,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          child: Row(
            children: [
              // NOTE: no Hero here — a hero flight from this list crashed with
              // MultiChildRenderObjectElement.forgetChild (`_children.contains`)
              // whenever the list rebuilt (any notifyListeners) mid-flight. The
              // chat page uses a safe fade+slide PageRouteBuilder transition.
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
                        if (conv.pinned) ...[
                          const Padding(
                            padding: EdgeInsets.only(right: 5),
                            child: Icon(
                              Icons.push_pin,
                              size: 13,
                              color: Tg.blue,
                            ),
                          ),
                        ],
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
                            color: conv.unread > 0 ? Tg.blue : palette.subtext,
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
                          // Elastic pop when the unread count changes.
                          TweenAnimationBuilder<double>(
                            key: ValueKey('unread-${conv.id}-${conv.unread}'),
                            tween: Tween(begin: 0.4, end: 1),
                            duration: const Duration(milliseconds: 380),
                            curve: Curves.elasticOut,
                            builder: (context, scale, child) =>
                                Transform.scale(scale: scale, child: child),
                            child: Container(
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
}

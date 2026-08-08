import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/models.dart';
import '../../core/providers.dart';

/// 会话列表页（消息 Tab）。
class ConversationListPage extends ConsumerWidget {
  const ConversationListPage({super.key, required this.onOpenChat});

  final void Function(String peerId) onOpenChat;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final client = ref.watch(chatClientProvider);
    final conversations = client.conversations.toList()
      ..sort((a, b) => b.lastTs.compareTo(a.lastTs));
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('消息'),
        actions: [
          IconButton(
            onPressed: () => _showNewChatSheet(context, ref),
            icon: const Icon(Icons.edit_outlined),
            tooltip: '发起聊天',
          ),
        ],
      ),
      body: conversations.isEmpty
          ? _EmptyState(onStartChat: () => _showNewChatSheet(context, ref))
          : RefreshIndicator(
              onRefresh: () async {
                if (client.status.isConnected) {
                  // 重新拉取 presence / 刷新（轻量）。
                }
              },
              child: ListView.builder(
                itemCount: conversations.length,
                itemBuilder: (context, i) {
                  final conv = conversations[i];
                  final peerId = _peerOf(conv, client.myNodeId);
                  final online =
                      peerId != null && client.onlineNodes.contains(peerId);
                  return ListTile(
                    onTap: () {
                      client.markRead(conv.id);
                      onOpenChat(peerId ?? conv.id);
                    },
                    leading: _PeerAvatar(
                      id: peerId ?? conv.id,
                      title: conv.title,
                      online: online,
                    ),
                    title: Text(
                      conv.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w500),
                    ),
                    subtitle: Text(
                      conv.lastPreview.isEmpty ? '暂无消息' : conv.lastPreview,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          _formatTime(conv.lastTs),
                          style: Theme.of(context).textTheme.labelSmall
                              ?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                        const SizedBox(height: 4),
                        if (conv.unread > 0)
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 7,
                              vertical: 1,
                            ),
                            decoration: BoxDecoration(
                              color: scheme.error,
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: Text(
                              conv.unread > 99 ? '99+' : '${conv.unread}',
                              style: TextStyle(
                                color: scheme.onError,
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                      ],
                    ),
                  );
                },
              ),
            ),
    );
  }

  String? _peerOf(Conversation conv, String? myId) {
    final parts = conv.id.split(':');
    if (parts.length < 2 || parts[0].isEmpty || parts[1].isEmpty) {
      return null; // 脏 id（如 "a:a:b"）不在此展开，交给 client 归一化。
    }
    if (myId == null) return parts[0]; // 未连接时取任一方，避免把 convId 当 peer。
    for (final p in parts) {
      if (p != myId) return p;
    }
    return parts[0];
  }

  /// 发起聊天：底部弹层选择目标（在线节点 + 最近聊过的人）。
  Future<void> _showNewChatSheet(BuildContext context, WidgetRef ref) async {
    final client = ref.read(chatClientProvider);
    final list = client.contactCandidates()
      ..sort((a, b) {
        if (a.online != b.online) return a.online ? -1 : 1;
        return a.name.compareTo(b.name);
      });

    if (list.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('暂无可聊的对象，稍后再试')));
      return;
    }

    await showModalBottomSheet<void>(
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
                    '选择聊天对象',
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
                    leading: _PeerAvatar(
                      id: c.id,
                      title: c.name,
                      online: c.online,
                    ),
                    title: Text(c.name),
                    subtitle: Text(c.online ? '在线' : '离线'),
                    onTap: () {
                      Navigator.pop(ctx);
                      onOpenChat(c.id);
                    },
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

  static String _formatTime(int ts) {
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
    final yesterday = now.subtract(const Duration(days: 1));
    final isYesterday =
        t.year == yesterday.year &&
        t.month == yesterday.month &&
        t.day == yesterday.day;
    if (isYesterday) return '昨天';
    return '${t.month}/${t.day}';
  }
}

/// Material 3 风格圆形头像（首字母 + 在线点）。
class _PeerAvatar extends StatelessWidget {
  const _PeerAvatar({
    required this.id,
    required this.title,
    this.online = false,
  });

  final String id;
  final String title;
  final bool online;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final initial = title.isNotEmpty ? title[0].toUpperCase() : '?';
    return Stack(
      clipBehavior: Clip.none,
      children: [
        CircleAvatar(
          radius: 22,
          backgroundColor: scheme.primaryContainer,
          child: Text(
            initial,
            style: TextStyle(
              color: scheme.onPrimaryContainer,
              fontSize: 18,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        if (online)
          Positioned(
            right: -1,
            bottom: -1,
            child: Container(
              width: 12,
              height: 12,
              decoration: BoxDecoration(
                color: Colors.green,
                shape: BoxShape.circle,
                border: Border.all(color: scheme.surface, width: 2),
              ),
            ),
          ),
      ],
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.onStartChat});

  final VoidCallback onStartChat;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.chat_bubble_outline, size: 56, color: scheme.outline),
          const SizedBox(height: 14),
          Text('暂无会话', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 6),
          Text(
            '从通讯录选择一个节点开始聊天',
            style: TextStyle(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: onStartChat,
            icon: const Icon(Icons.edit_outlined),
            label: const Text('发起聊天'),
          ),
        ],
      ),
    );
  }
}

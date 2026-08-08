import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';

/// 通讯录页：tailnet 在线节点 + 最近聊过的人。
class ContactsPage extends ConsumerWidget {
  const ContactsPage({super.key, required this.onOpenChat});

  final void Function(String peerId) onOpenChat;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final client = ref.watch(chatClientProvider);
    final scheme = Theme.of(context).colorScheme;

    final online = client.onlineNodes.toList()..sort();
    final knownOffline = client.conversations
        .where((c) => !c.isGroup)
        .map((c) => c.id)
        .where((id) => !client.onlineNodes.contains(id))
        .where((id) => id != client.myNodeId)
        .toSet()
        .toList()
      ..sort();

    return Scaffold(
      appBar: AppBar(title: const Text('通讯录')),
      body: ListView(
        children: [
          if (online.isEmpty && knownOffline.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 120),
              child: Column(
                children: [
                  Icon(Icons.people_outline, size: 56, color: scheme.outline),
                  const SizedBox(height: 12),
                  Text('暂无联系人', style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 4),
                  Text(
                    'tailnet 上的节点会自动出现在这里',
                    style: TextStyle(color: scheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
          if (online.isNotEmpty) ...[
            _SectionTitle('在线（${online.length}）'),
            for (final id in online)
              _ContactTile(
                id: id,
                name: client.displayName(id),
                online: true,
                onTap: () => onOpenChat(id),
              ),
          ],
          if (knownOffline.isNotEmpty) ...[
            _SectionTitle('离线'),
            for (final id in knownOffline)
              _ContactTile(
                id: id,
                name: client.displayName(id),
                online: false,
                onTap: () => onOpenChat(id),
              ),
          ],
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 13,
          color: scheme.onSurfaceVariant,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _ContactTile extends StatelessWidget {
  const _ContactTile({
    required this.id,
    required this.name,
    required this.online,
    required this.onTap,
  });

  final String id;
  final String name;
  final bool online;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final initial = name.isNotEmpty ? name[0].toUpperCase() : '?';
    return ListTile(
      onTap: onTap,
      leading: Stack(
        clipBehavior: Clip.none,
        children: [
          CircleAvatar(
            radius: 22,
            backgroundColor: scheme.secondaryContainer,
            child: Text(
              initial,
              style: TextStyle(
                fontSize: 17,
                color: scheme.onSecondaryContainer,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (online)
            Positioned(
              right: -1,
              bottom: -1,
              child: Container(
                width: 13,
                height: 13,
                decoration: BoxDecoration(
                  color: Colors.green,
                  shape: BoxShape.circle,
                  border: Border.all(color: scheme.surface, width: 2),
                ),
              ),
            ),
        ],
      ),
      title: Text(name),
      subtitle: Text(online ? '在线' : '离线'),
      trailing: const Icon(Icons.chevron_right),
    );
  }
}

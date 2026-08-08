import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'network/chat_client.dart';
import 'network/tailscale_service.dart';
import 'settings/app_settings.dart';

/// 已加载的应用设置（main() 中预加载后 override；引导页保存后更新）。
final appSettingsProvider = StateProvider<AppSettings>(
  (ref) => const AppSettings(),
);

/// Tailscale 服务（懒加载单例）。
final tailscaleServiceProvider = Provider<TailscaleService>(
  (ref) => TailscaleService(),
);

/// 客户端核心（ChangeNotifier）。创建后即异步加载本地缓存。
final chatClientProvider = ChangeNotifierProvider<ChatClient>((ref) {
  final client = ChatClient(tailscale: ref.watch(tailscaleServiceProvider));
  client.init();
  return client;
});

/// 主题模式（v1 内存态，重启回跟随系统）。
final themeModeProvider = StateProvider<ThemeMode>((ref) => ThemeMode.system);

/// 当前打开的会话 id（聊天页维护：打开时设置、关闭时清空）。
/// 用于收到新消息时判断是否应自动清零未读并回执。
final activeConversationProvider = StateProvider<String?>((ref) => null);

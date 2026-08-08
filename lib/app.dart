import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/providers.dart';
import 'core/theme/app_theme.dart';
import 'features/home/home_shell.dart';
import 'features/setup/setup_page.dart';

/// 首次配置的 Auth key 中转（敏感，不持久化，仅本次会话有效）。
class SetupResult {
  SetupResult._();

  static String? authKey;
}

/// 应用根组件：主题 + 首页路由（未配置 → 引导页；已配置 → 主界面）。
class ChatApp extends ConsumerWidget {
  const ChatApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(appSettingsProvider);
    return MaterialApp(
      title: 'TL Chat',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      home: settings.isConfigured ? const HomeShell() : const SetupPage(),
    );
  }
}

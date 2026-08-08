import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/providers.dart';
import 'core/theme/app_theme.dart';
import 'features/home/home_shell.dart';
import 'features/setup/setup_page.dart';

/// 首次配置的敏感信息中转（不持久化，仅本次会话有效）。
///
/// - [authKey]：Tailscale 注册用；上线成功后立即清空。
/// - [pairSecret]：App 层身份配对码（服务端 --pair-secret / 启动时打印的
///   一次性配对码）；仅在该设备向服务端**首次** hello 注册时使用一次，
///   之后服务端签发的长期 [AppSettings.deviceToken] 会取代它。
class SetupResult {
  SetupResult._();

  static String? authKey;
  static String? pairSecret;
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

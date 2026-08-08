import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'core/providers.dart';
import 'core/settings/app_settings.dart';
import 'services/notification_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 预加载设置：决定进入引导页还是主界面。
  final settings = await AppSettings.load();
  // Android 前台保活 + 消息通知（非 Android 平台自动跳过）。
  await NotificationService.instance.init();
  runApp(
    ProviderScope(
      overrides: [appSettingsProvider.overrideWith((ref) => settings)],
      child: const ChatApp(),
    ),
  );
}

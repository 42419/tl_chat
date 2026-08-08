import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'core/providers.dart';
import 'core/settings/app_settings.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 预加载设置：决定进入引导页还是主界面。
  final settings = await AppSettings.load();
  runApp(
    ProviderScope(
      overrides: [appSettingsProvider.overrideWith((ref) => settings)],
      child: const ChatApp(),
    ),
  );
}

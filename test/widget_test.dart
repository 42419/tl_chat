// 应用级 widget 测试（新架构）。
//
// 注意：测试环境里 path_provider / sqflite 的平台通道不可用（挂起或抛
// MissingPluginException），因此这里直接注入 appSettingsProvider 驱动路由，
// 不经过 main() 的 AppSettings.load()。ChatClient.init() 已对平台错误做了
// 静默降级（纯内存运行）。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tl_chat/app.dart';
import 'package:tl_chat/core/providers.dart';
import 'package:tl_chat/core/settings/app_settings.dart';

Widget _app(AppSettings settings) => ProviderScope(
  overrides: [appSettingsProvider.overrideWith((ref) => settings)],
  child: const ChatApp(),
);

void main() {
  testWidgets('未配置时进入首次配置引导页', (tester) async {
    await tester.pumpWidget(_app(const AppSettings()));
    await tester.pump();

    expect(find.text('设置你的昵称'), findsOneWidget);
    expect(find.text('下一步'), findsOneWidget);
  });

  testWidgets('已配置时进入主界面（首连 overlay）', (tester) async {
    await tester.pumpWidget(
      _app(const AppSettings(nickname: '小明', serverHost: 'armbian')),
    );
    await tester.pump(const Duration(milliseconds: 100));

    // HomeShell 已挂载并开始连接（测试环境无 tailscale，停留连接中状态）。
    expect(find.text('正在连接…'), findsOneWidget);
    expect(find.text('正在通过 Tailscale 连接到内网'), findsOneWidget);
  });

  testWidgets('主界面路由：保存设置后切换主界面', (tester) async {
    final container = ProviderContainer(
      overrides: [
        appSettingsProvider.overrideWith((ref) => const AppSettings()),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: const ChatApp()),
    );
    await tester.pump();
    expect(find.text('设置你的昵称'), findsOneWidget);

    // 模拟引导页完成：更新设置 → 主界面出现。
    container.read(appSettingsProvider.notifier).state = const AppSettings(
      nickname: '小明',
      serverHost: 'armbian',
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('正在连接…'), findsOneWidget);
  });
}

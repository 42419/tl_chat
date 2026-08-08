import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 持久化的连接与应用设置。
///
/// Auth key 属于敏感信息，**不持久化**——只在首次配置会话中经内存传递。
class AppSettings {
  const AppSettings({
    this.nickname = '',
    this.serverHost = '',
    this.serverPort = 8600,
  });

  /// 本机节点在 tailnet 上的显示名（也是 tailscale hostname）。
  final String nickname;

  /// 中心服务在 tailnet 上的地址（主机名或 100.x 地址）。
  final String serverHost;

  final int serverPort;

  /// 是否已完成首次配置（等价于 serverHost 非空）。
  bool get isConfigured => serverHost.trim().isNotEmpty;

  static const _fileName = 'settings.json';

  static Future<File> _file() async {
    final support = await getApplicationSupportDirectory();
    return File(p.join(support.path, _fileName));
  }

  /// 读取本地设置；文件缺失/损坏/平台目录不可用时返回默认值（未配置）。
  static Future<AppSettings> load() async {
    try {
      final file = await _file();
      if (!file.existsSync()) return const AppSettings();
      final json = jsonDecode(await file.readAsString());
      if (json is! Map) return const AppSettings();
      return AppSettings(
        nickname: json['nickname'] as String? ?? '',
        serverHost: json['serverHost'] as String? ?? '',
        serverPort: (json['serverPort'] as num?)?.toInt() ?? 8600,
      );
    } catch (_) {
      return const AppSettings();
    }
  }

  /// 保存设置（best-effort，失败不阻塞使用）。
  static Future<void> save(AppSettings settings) async {
    try {
      final file = await _file();
      await file.writeAsString(
        jsonEncode({
          'nickname': settings.nickname,
          'serverHost': settings.serverHost,
          'serverPort': settings.serverPort,
        }),
      );
    } catch (_) {
      // best-effort
    }
  }
}

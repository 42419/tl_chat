// Persisted connection settings (WeChat/QQ-style auto-login support).
// On first launch the user fills the connect panel and the hub details are
// saved; subsequent launches auto-connect with these values instead of asking
// again. The Tailscale node credentials themselves already persist in the
// state dir — this only remembers which hub to talk to.

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class ChatSettings {
  const ChatSettings({
    this.hostname = 'tl-chat-phone',
    this.hubHost = 'armbian',
    this.hubPort = 8600,
  });

  final String hostname;
  final String hubHost;
  final int hubPort;

  static const _fileName = 'settings.json';

  static Future<File> _file() async {
    final support = await getApplicationSupportDirectory();
    return File(p.join(support.path, _fileName));
  }

  /// Loads saved settings, or defaults when none exist / the file is corrupt
  /// / the platform dir is unavailable (e.g. tests).
  static Future<ChatSettings> load() async {
    try {
      final file = await _file();
      if (!file.existsSync()) return const ChatSettings();
      final json = jsonDecode(await file.readAsString());
      if (json is! Map) return const ChatSettings();
      return ChatSettings(
        hostname: json['hostname'] as String? ?? 'tl-chat-phone',
        hubHost: json['hubHost'] as String? ?? 'armbian',
        hubPort: (json['hubPort'] as num?)?.toInt() ?? 8600,
      );
    } catch (_) {
      return const ChatSettings();
    }
  }

  /// Persists the settings (best-effort; failure never breaks chat).
  static Future<void> save(ChatSettings settings) async {
    try {
      final file = await _file();
      await file.writeAsString(
        jsonEncode({
          'hostname': settings.hostname,
          'hubHost': settings.hubHost,
          'hubPort': settings.hubPort,
        }),
      );
    } catch (_) {
      // best-effort
    }
  }
}

// Local chat history cache (Flutter role: offline browsing, fast search,
// send status — user-cleanable). One JSON file per conversation under
// <support>/chat_cache/. The hub remains the authoritative store; this cache
// is a convenience mirror that can be wiped without data loss.

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'chat_client.dart';

class ChatCache {
  ChatCache._();

  static Future<Directory> _dir() async {
    final support = await getApplicationSupportDirectory();
    final dir = Directory(p.join(support.path, 'chat_cache'));
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  /// Conversation id -> safe file name (node ids and room ids are URL-safe,
  /// but keep the path clean regardless).
  static String _fileName(String id) =>
      '${id.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_')}.json';

  /// Loads every cached conversation. Best-effort: corrupt/missing files and
  /// platform errors (e.g. tests) are swallowed — returns what it can.
  static Future<Map<String, Conversation>> loadAll() async {
    final out = <String, Conversation>{};
    try {
      final dir = await _dir();
      await for (final entry in dir.list()) {
        if (entry is! File || !entry.path.endsWith('.json')) continue;
        try {
          final json = jsonDecode(await entry.readAsString());
          if (json is! Map) continue;
          final conv = Conversation.fromJson(
            Map<String, dynamic>.from(json),
          );
          out[conv.id] = conv;
        } catch (_) {
          // skip corrupt file
        }
      }
    } catch (_) {
      // platform directory unavailable — return what we have
    }
    return out;
  }

  /// Saves one conversation. Best-effort (fire-and-forget from the client).
  static Future<void> save(Conversation conv) async {
    try {
      final dir = await _dir();
      final file = File(p.join(dir.path, _fileName(conv.id)));
      await file.writeAsString(jsonEncode(conv.toJson()));
    } catch (_) {
      // best-effort: never break chat because the cache failed
    }
  }

  /// Deletes the whole local cache (user-cleanable).
  static Future<void> clear() async {
    try {
      final dir = await _dir();
      if (dir.existsSync()) {
        await dir.delete(recursive: true);
      }
    } catch (_) {
      // best-effort
    }
  }
}

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
          final conv = Conversation.fromJson(Map<String, dynamic>.from(json));
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

  /// Deletes one conversation's cache file (used when a conversation is
  /// removed from the list). Best-effort: missing file / platform errors are
  /// swallowed.
  static Future<void> deleteOne(String id) async {
    try {
      final dir = await _dir();
      final file = File(p.join(dir.path, _fileName(id)));
      if (file.existsSync()) {
        await file.delete();
      }
    } catch (_) {
      // best-effort
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

/// Room-name registry: roomId -> display name.
///
/// Stored SEPARATELY from the chat-history cache (own JSON file), because a
/// room's name is metadata that survives the user clearing their chat history:
/// after re-login the client can render real group names immediately instead
/// of waiting for the network `room/list` round-trip. The hub stays
/// authoritative; this is only a fast-path mirror that may go stale.
class RoomNames {
  RoomNames._();

  static Future<File> _file() async {
    final support = await getApplicationSupportDirectory();
    return File(p.join(support.path, 'room_names.json'));
  }

  /// Loads the room-name registry. Best-effort: missing/corrupt file and
  /// platform errors (e.g. tests) return an empty map.
  static Future<Map<String, String>> load() async {
    final out = <String, String>{};
    try {
      final file = await _file();
      if (!file.existsSync()) return out;
      final json = jsonDecode(await file.readAsString());
      if (json is! Map) return out;
      for (final entry in json.entries) {
        if (entry.key is String && entry.value is String) {
          out[entry.key as String] = entry.value as String;
        }
      }
    } catch (_) {
      // corrupt file / platform unavailable — return what we have
    }
    return out;
  }

  /// Persists the whole registry (fire-and-forget from the client).
  static Future<void> save(Map<String, String> names) async {
    try {
      final file = await _file();
      await file.writeAsString(jsonEncode(names));
    } catch (_) {
      // best-effort: never break chat because the registry failed
    }
  }
}

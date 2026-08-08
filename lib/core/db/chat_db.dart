import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../models/models.dart';

/// 本地聊天数据库（sqflite / SQLite）。
///
/// 存储会话与消息的历史，支持离线浏览、增量同步与消息状态更新。
/// 服务端仍是权威数据源——本地库只做缓存与离线队列。
class ChatDb {
  ChatDb._(this._db);

  static const _dbName = 'chat.db';
  static const _dbVersion = 2;

  final Database _db;

  static Future<ChatDb> open() async {
    final dir = await getDatabasesPath();
    final db = await openDatabase(
      p.join(dir, _dbName),
      version: _dbVersion,
      onCreate: _createSchema,
      onUpgrade: _upgradeSchema,
    );
    return ChatDb._(db);
  }

  /// v1 → v2：新增 names 表（nodeId → 显示名，重启后恢复昵称）。
  static Future<void> _upgradeSchema(
    Database db,
    int oldVersion,
    int newVersion,
  ) async {
    if (oldVersion < 2) {
      await db.execute(
        'CREATE TABLE names (node_id TEXT PRIMARY KEY, name TEXT NOT NULL)',
      );
    }
  }

  static Future<void> _createSchema(Database db, int version) async {
    await db.execute('''
      CREATE TABLE conversations (
        id TEXT PRIMARY KEY,
        title TEXT NOT NULL,
        is_group INTEGER NOT NULL DEFAULT 0,
        last_seq INTEGER NOT NULL DEFAULT 0,
        unread INTEGER NOT NULL DEFAULT 0,
        last_ts INTEGER NOT NULL DEFAULT 0,
        last_preview TEXT NOT NULL DEFAULT ''
      )
    ''');
    await db.execute('''
      CREATE TABLE messages (
        client_id TEXT PRIMARY KEY,
        server_id TEXT,
        conv_id TEXT NOT NULL,
        sender TEXT NOT NULL,
        text TEXT NOT NULL,
        ts INTEGER NOT NULL,
        seq INTEGER,
        status TEXT NOT NULL DEFAULT 'sending',
        recalled INTEGER NOT NULL DEFAULT 0
      )
    ''');
    await db.execute(
      'CREATE INDEX idx_messages_conv ON messages(conv_id, seq)',
    );
    await db.execute(
      'CREATE TABLE names (node_id TEXT PRIMARY KEY, name TEXT NOT NULL)',
    );
  }

  Future<void> close() => _db.close();

  // ─── 会话 ──────────────────────────────────────────────────────────

  /// 写入或更新一个会话摘要（存在则合并 unread/lastSeq 取较大值）。
  Future<void> upsertConversation(Conversation conv) async {
    await _db.insert(
      'conversations',
      conv.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// 按最近活动排序的会话列表。
  Future<List<Conversation>> listConversations() async {
    final rows = await _db.query(
      'conversations',
      orderBy: 'last_ts DESC',
    );
    return rows.map(Conversation.fromMap).toList();
  }

  /// 会话未读计数 +1（用于收到离线/非活跃会话消息时）。
  Future<void> incrementUnread(String id) async {
    await _db.rawUpdate(
      'UPDATE conversations SET unread = unread + 1 WHERE id = ?',
      [id],
    );
  }

  Future<void> clearUnread(String id) async {
    await _db.update(
      'conversations',
      {'unread': 0},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> deleteMessage(String clientId) async {
    await _db.delete('messages', where: 'client_id = ?', whereArgs: [clientId]);
  }

  Future<void> clearAll() async {
    await _db.delete('messages');
    await _db.delete('conversations');
  }

  // ─── 节点显示名（持久化，重启后恢复）────────────────────────────────

  Future<void> upsertName(String nodeId, String name) async {
    await _db.insert(
      'names',
      {'node_id': nodeId, 'name': name},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<Map<String, String>> loadNames() async {
    final rows = await _db.query('names');
    return {
      for (final r in rows) r['node_id'] as String: r['name'] as String,
    };
  }

  // ─── 消息 ──────────────────────────────────────────────────────────

  Future<void> insertMessage(ChatMessage msg) async {
    await _db.insert(
      'messages',
      msg.toMap(),
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  Future<void> updateMessage(
    String clientId, {
    String? serverId,
    int? seq,
    MessageStatus? status,
    bool? recalled,
  }) async {
    final values = <String, Object?>{
      'server_id': ?serverId,
      'seq': ?seq,
      'status': ?status?.name,
      if (recalled != null) 'recalled': recalled ? 1 : 0,
    };
    if (values.isEmpty) return;
    await _db.update(
      'messages',
      values,
      where: 'client_id = ?',
      whereArgs: [clientId],
    );
  }

  /// 按 seq 降序取一页消息（最新在前）；[beforeSeq] 用于历史分页游标。
  Future<List<ChatMessage>> listMessages(
    String convId, {
    int limit = 100,
    int? beforeSeq,
  }) async {
    final rows = await _db.query(
      'messages',
      where: beforeSeq == null ? 'conv_id = ?' : 'conv_id = ? AND seq < ?',
      whereArgs: beforeSeq == null ? [convId] : [convId, beforeSeq],
      orderBy: 'seq DESC',
      limit: limit,
    );
    // 返回升序（旧→新），便于 UI 直接追加。
    return rows.reversed.map(ChatMessage.fromMap).toList();
  }
}

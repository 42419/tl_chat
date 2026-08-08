// SQLite 存储层（Node 内置 node:sqlite，零原生依赖）。
//
// 核心设计：
//   - 每会话单调递增 seq（单进程同步执行，SELECT MAX → INSERT 原子无竞态）
//   - (sender, client_id) 唯一索引实现发送幂等去重
//   - 历史按 (conv_id, seq) 索引游标分页
'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { DatabaseSync } = require('node:sqlite');

class Store {
  constructor(dbPath = ':memory:') {
    // SQLite 不会自动创建父目录；文件型数据库先确保目录存在。
    if (dbPath !== ':memory:') {
      fs.mkdirSync(path.dirname(path.resolve(dbPath)), { recursive: true });
    }
    this.db = new DatabaseSync(dbPath);
    this.db.exec('PRAGMA journal_mode = WAL');
    this._init();
  }

  _init() {
    this.db.exec(`
      CREATE TABLE IF NOT EXISTS conversations (
        conv_id TEXT PRIMARY KEY
      );
      CREATE TABLE IF NOT EXISTS messages (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        conv_id TEXT NOT NULL,
        sender TEXT NOT NULL,
        client_id TEXT NOT NULL,
        text TEXT NOT NULL,
        ts INTEGER NOT NULL,
        seq INTEGER NOT NULL,
        UNIQUE(conv_id, seq),
        UNIQUE(sender, client_id)
      );
      CREATE INDEX IF NOT EXISTS idx_messages_conv ON messages(conv_id, seq);
    `);
  }

  close() {
    this.db.close();
  }

  /** 会话 id（1:1：双方 nodeId 排序后拼接，两端一致）。 */
  static convIdFor(a, b) {
    return [a, b].sort().join(':');
  }

  /** 追加一条消息；重复 (sender, client_id) 返回已有记录（幂等）。 */
  append({ convId, sender, clientId, text, ts }) {
    this._ensureConversation(convId);
    const existing = this.db
      .prepare('SELECT id, seq FROM messages WHERE sender = ? AND client_id = ?')
      .get(sender, clientId);
    if (existing) {
      return { serverId: String(existing.id), seq: existing.seq, duplicate: true };
    }
    const row = this.db
      .prepare('SELECT COALESCE(MAX(seq), 0) + 1 AS next FROM messages WHERE conv_id = ?')
      .get(convId);
    const seq = row.next;
    const info = this.db
      .prepare(
        'INSERT INTO messages (conv_id, sender, client_id, text, ts, seq) VALUES (?, ?, ?, ?, ?, ?)'
      )
      .run(convId, sender, clientId, text, ts, seq);
    const id = Number(info.lastInsertRowid);
    return { serverId: String(id), seq, duplicate: false };
  }

  _ensureConversation(convId) {
    this.db
      .prepare('INSERT OR IGNORE INTO conversations (conv_id) VALUES (?)')
      .run(convId);
  }

  /** 某用户参与的全部会话 id。 */
  conversationsOf(nodeId) {
    const rows = this.db
      .prepare(
        `SELECT DISTINCT conv_id FROM messages
         WHERE conv_id LIKE ? OR conv_id LIKE ?`
      )
      .all(`${nodeId}:%`, `%:${nodeId}`);
    return rows.map((r) => r.conv_id);
  }

  /** 某会话中 seq > cursor 的消息（旧→新），用于增量同步 / 离线补发。 */
  afterCursor(convId, cursor = 0, limit = 500) {
    const rows = this.db
      .prepare(
        `SELECT * FROM messages WHERE conv_id = ? AND seq > ? ORDER BY seq ASC LIMIT ?`
      )
      .all(convId, cursor, limit);
    return rows.map(this._toWire);
  }

  /** 游标分页历史：seq < beforeSeq 的一页（旧→新）。 */
  historyBefore(convId, beforeSeq, limit = 30) {
    const rows = this.db
      .prepare(
        `SELECT * FROM messages WHERE conv_id = ? AND seq < ? ORDER BY seq DESC LIMIT ?`
      )
      .all(convId, beforeSeq, limit);
    return rows.reverse().map(this._toWire);
  }

  _toWire(row) {
    return {
      serverId: String(row.id),
      conv: row.conv_id,
      sender: row.sender,
      clientId: row.client_id,
      text: row.text,
      ts: row.ts,
      seq: row.seq,
    };
  }
}

module.exports = { Store };

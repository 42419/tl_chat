// SQLite persistence using Node's built-in node:sqlite (zero native deps).
//
// Authoritative message history (VPS role): every 1:1 and room message is
// persisted here — not just the offline queue. `delivered` distinguishes
// queued (undelivered, flushed on reconnect) from delivered rows. Room
// membership is persisted too so group history stays recoverable across hub
// restarts.

import { DatabaseSync } from 'node:sqlite';

import type { Room } from './router.js';

export interface StoredMessage {
  id: number;
  roomId: string | null;
  sender: string;
  recipient: string | null;
  payload: Record<string, unknown>;
  ts: number;
  delivered: boolean;
}

export class Store {
  private readonly db: DatabaseSync;

  constructor(path: string) {
    this.db = new DatabaseSync(path);
    this.db.exec(`
      PRAGMA journal_mode = WAL;
      CREATE TABLE IF NOT EXISTS messages (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        room_id TEXT,
        sender TEXT NOT NULL,
        recipient TEXT,
        payload TEXT NOT NULL,
        ts INTEGER NOT NULL,
        delivered INTEGER NOT NULL DEFAULT 0
      );
      CREATE TABLE IF NOT EXISTS rooms (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        owner TEXT NOT NULL,
        members TEXT NOT NULL
      );
      CREATE INDEX IF NOT EXISTS idx_messages_sender_recipient
        ON messages(sender, recipient, id);
      CREATE INDEX IF NOT EXISTS idx_messages_room
        ON messages(room_id, id);
    `);
  }

  close(): void {
    this.db.close();
  }

  /** Cap on queued (undelivered) messages per recipient; oldest dropped beyond it. */
  static readonly MAX_QUEUED_PER_RECIPIENT = 1000;

  /**
   * Persists one message (authoritative history). [delivered] marks whether
   * the message reached the recipient's live session; queued (delivered=false)
   * rows are flushed on reconnect. For room messages pass `recipient` = the
   * room id so 1:1 history queries never match them. Returns the row id.
   */
  insert(
    msg: {
      roomId: string | null;
      sender: string;
      recipient: string | null;
      payload: Record<string, unknown>;
      ts: number;
    },
    delivered = false,
  ): number {
    if (!delivered && msg.recipient) {
      // Guard against unbounded growth for a long-offline node: drop the
      // oldest undelivered messages past the cap. Keep Math.max(0, ...):
      // SQLite treats a NEGATIVE LIMIT as "no limit", which would delete
      // every undelivered message for this recipient.
      this.db
        .prepare(
          `DELETE FROM messages WHERE id IN (
             SELECT id FROM messages WHERE recipient = ? AND delivered = 0
             ORDER BY id LIMIT ?
           )`,
        )
        .run(
          msg.recipient,
          Math.max(0, this.countQueued(msg.recipient) - Store.MAX_QUEUED_PER_RECIPIENT),
        );
    }
    const stmt = this.db.prepare(
      'INSERT INTO messages (room_id, sender, recipient, payload, ts, delivered) VALUES (?, ?, ?, ?, ?, ?)',
    );
    const result = stmt.run(
      msg.roomId,
      msg.sender,
      msg.recipient,
      JSON.stringify(msg.payload),
      msg.ts,
      delivered ? 1 : 0,
    );
    return Number(result.lastInsertRowid);
  }

  private countQueued(recipient: string): number {
    const row = this.db
      .prepare('SELECT COUNT(*) AS c FROM messages WHERE recipient = ? AND delivered = 0')
      .get(recipient) as { c: number };
    return Number(row.c);
  }

  /** Undelivered (queued) messages for a recipient, oldest first. */
  queuedFor(recipient: string): StoredMessage[] {
    const rows = this.db
      .prepare('SELECT * FROM messages WHERE recipient = ? AND delivered = 0 ORDER BY id')
      .all(recipient) as unknown[];
    return rows.map((row) => this.rowToMessage(row));
  }

  /** Marks messages as delivered (after successful flush). */
  markDelivered(ids: number[]): void {
    const stmt = this.db.prepare('UPDATE messages SET delivered = 1 WHERE id = ?');
    for (const id of ids) stmt.run(id);
  }

  /**
   * History involving a node: 1:1 messages in BOTH directions plus room
   * messages for the rooms it belongs to (via [roomIds]). Oldest-first,
   * newest capped at [limit]. Used by the client's `offline` (history) pull.
   */
  historyFor(nodeId: string, roomIds: string[], limit = 200): StoredMessage[] {
    const roomClause =
      roomIds.length > 0 ? ` OR room_id IN (${roomIds.map(() => '?').join(', ')})` : '';
    const rows = this.db
      .prepare(
        `SELECT * FROM messages
         WHERE sender = ? OR recipient = ?${roomClause}
         ORDER BY id DESC LIMIT ?`,
      )
      .all(nodeId, nodeId, ...roomIds, limit) as unknown[];
    return rows.reverse().map((row) => this.rowToMessage(row));
  }

  // ─── room membership (cross-restart recovery) ──────────────────────

  /** Upserts a room's metadata + membership. */
  saveRoom(room: Room): void {
    this.db
      .prepare(
        `INSERT INTO rooms (id, name, owner, members) VALUES (?, ?, ?, ?)
         ON CONFLICT(id) DO UPDATE SET
           name = excluded.name, owner = excluded.owner, members = excluded.members`,
      )
      .run(room.id, room.name, room.owner, JSON.stringify([...room.members]));
  }

  loadRooms(): Room[] {
    const rows = this.db.prepare('SELECT id, name, owner, members FROM rooms').all() as unknown[];
    return rows.map((row) => {
      const r = row as Record<string, unknown>;
      return {
        id: r.id as string,
        name: r.name as string,
        owner: r.owner as string,
        members: new Set(JSON.parse(r.members as string) as string[]),
      };
    });
  }

  private rowToMessage(row: unknown): StoredMessage {
    const r = row as Record<string, unknown>;
    return {
      id: Number(r.id),
      roomId: (r.room_id as string | null) ?? null,
      sender: r.sender as string,
      recipient: (r.recipient as string | null) ?? null,
      payload: JSON.parse(r.payload as string) as Record<string, unknown>,
      ts: Number(r.ts),
      delivered: Boolean(r.delivered),
    };
  }
}

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

  /** Per-conversation monotonic sequence number (Phase 1.2 incremental sync). */
  seq: number;
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
    this.migrateSeq();
  }

  /**
   * Per-conversation sequence support (Phase 1.2).
   *
   * `messages.seq` is a monotonic counter scoped to ONE conversation
   * (1:1 pair or room), so clients can incrementally sync `WHERE seq > last`.
   * `conv_seq` holds the current counter per conversation key.
   *
   * Migration: adds the `seq` column if missing and backfills existing rows
   * (1..n per conversation, ordered by global id), seeding `conv_seq`.
   */
  private migrateSeq(): void {
    this.db.exec(
      'CREATE TABLE IF NOT EXISTS conv_seq (conv TEXT PRIMARY KEY, seq INTEGER NOT NULL)',
    );
    const cols = this.db.prepare('PRAGMA table_info(messages)').all() as unknown as {
      name: string;
    }[];
    if (cols.some((c) => c.name === 'seq')) return;
    this.db.exec('ALTER TABLE messages ADD COLUMN seq INTEGER NOT NULL DEFAULT 0');
    const rows = this.db
      .prepare('SELECT id, room_id, sender, recipient FROM messages ORDER BY id')
      .all() as unknown as {
      id: number;
      room_id: string | null;
      sender: string;
      recipient: string | null;
    }[];
    const counters = new Map<string, number>();
    const update = this.db.prepare('UPDATE messages SET seq = ? WHERE id = ?');
    for (const r of rows) {
      const key = this.convKey(r.room_id, r.sender, r.recipient ?? '');
      const s = (counters.get(key) ?? 0) + 1;
      counters.set(key, s);
      update.run(s, r.id);
    }
    const seed = this.db.prepare(
      'INSERT OR REPLACE INTO conv_seq (conv, seq) VALUES (?, ?)',
    );
    for (const [key, s] of counters) seed.run(key, s);
  }

  /**
   * Conversation key for seq scoping: rooms use `room:<id>`; 1:1 uses the
   * sorted node-id pair so both directions share one sequence space.
   */
  private convKey(roomId: string | null, sender: string, recipient: string): string {
    if (roomId) return `room:${roomId}`;
    return sender < recipient ? `1:1:${sender}:${recipient}` : `1:1:${recipient}:${sender}`;
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
   * room id so 1:1 history queries never match them. Returns the row id + the
   * per-conversation sequence number assigned to the row.
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
  ): { id: number; seq: number } {
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
    // Per-conversation seq: monotonic within the thread, shared across
    // directions of a 1:1 pair (and across members of a room).
    const key = this.convKey(msg.roomId, msg.sender, msg.recipient ?? '');
    this.db
      .prepare(
        `INSERT INTO conv_seq (conv, seq) VALUES (?, 1)
         ON CONFLICT(conv) DO UPDATE SET seq = seq + 1`,
      )
      .run(key);
    const counter = this.db
      .prepare('SELECT seq FROM conv_seq WHERE conv = ?')
      .get(key) as { seq: number };
    const seq = Number(counter.seq);

    const stmt = this.db.prepare(
      'INSERT INTO messages (room_id, sender, recipient, payload, ts, delivered, seq) VALUES (?, ?, ?, ?, ?, ?, ?)',
    );
    const result = stmt.run(
      msg.roomId,
      msg.sender,
      msg.recipient,
      JSON.stringify(msg.payload),
      msg.ts,
      delivered ? 1 : 0,
      seq,
    );
    return { id: Number(result.lastInsertRowid), seq };
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

  /** All 1:1 peers that have ever exchanged messages with [nodeId]. */
  private distinct1to1Peers(nodeId: string): string[] {
    const rows = this.db
      .prepare(
        `SELECT sender AS id FROM messages WHERE room_id IS NULL AND recipient = ?
         UNION
         SELECT recipient AS id FROM messages WHERE room_id IS NULL AND sender = ?`,
      )
      .all(nodeId, nodeId) as unknown as { id: string }[];
    return rows.map((r) => r.id).filter((id) => id !== nodeId);
  }

  /**
   * Incremental sync (Phase 1.2): per-conversation `after` cursors
   * (`convId -> lastKnownSeq`). Conversations the node knows about return only
   * messages with `seq > cursor`; conversations it doesn't know yet (new peer /
   * new room while offline) return their most recent messages instead, so the
   * first incremental pull still covers them. Merged oldest-first by global id.
   */
  incrementalFor(
    nodeId: string,
    roomIds: string[],
    after: Record<string, number>,
    limit = 200,
  ): StoredMessage[] {
    const out: StoredMessage[] = [];
    const recent = (sql: string, ...params: (string | number)[]): StoredMessage[] =>
      (this.db.prepare(sql).all(...params) as unknown[]).map((row) =>
        this.rowToMessage(row),
      );

    for (const peer of this.distinct1to1Peers(nodeId)) {
      const cursor = after[peer] ?? 0;
      if (cursor > 0) {
        out.push(
          ...recent(
            `SELECT * FROM messages WHERE room_id IS NULL AND seq > ?
             AND ((sender = ? AND recipient = ?) OR (sender = ? AND recipient = ?))
             ORDER BY id ASC LIMIT ?`,
            cursor,
            nodeId,
            peer,
            peer,
            nodeId,
            limit,
          ),
        );
      } else {
        out.push(
          ...recent(
            `SELECT * FROM messages WHERE room_id IS NULL
             AND ((sender = ? AND recipient = ?) OR (sender = ? AND recipient = ?))
             ORDER BY id DESC LIMIT ?`,
            nodeId,
            peer,
            peer,
            nodeId,
            limit,
          ).reverse(),
        );
      }
    }

    for (const roomId of roomIds) {
      const cursor = after[roomId] ?? 0;
      if (cursor > 0) {
        out.push(
          ...recent(
            `SELECT * FROM messages WHERE room_id = ? AND seq > ? ORDER BY id ASC LIMIT ?`,
            roomId,
            cursor,
            limit,
          ),
        );
      } else {
        out.push(
          ...recent(
            `SELECT * FROM messages WHERE room_id = ? ORDER BY id DESC LIMIT ?`,
            roomId,
            limit,
          ).reverse(),
        );
      }
    }

    out.sort((a, b) => a.id - b.id);
    return out;
  }

  /**
   * Deletes an entire conversation's history from the authoritative store:
   * for 1:1 both directions (room_id IS NULL), or every message of a room.
   * Queued (delivered=0) rows are rows in the same table, so clearing a
   * conversation also drops its offline queue — a deleted chat stays gone.
   */
  clearConversation(peerA: string, peerB: string | null, roomId: string | null): void {
    if (roomId) {
      this.db
        .prepare('DELETE FROM messages WHERE room_id = ? AND recipient = ?')
        .run(roomId, roomId);
    } else if (peerB) {
      this.db
        .prepare(
          `DELETE FROM messages WHERE room_id IS NULL
           AND ((sender = ? AND recipient = ?) OR (sender = ? AND recipient = ?))`,
        )
        .run(peerA, peerB, peerB, peerA);
    }
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
      seq: Number(r.seq ?? 0),
    };
  }
}

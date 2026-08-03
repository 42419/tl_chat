// TL Chat hub — Tailscale intranet chat relay.
// Listens on the tailnet interface (OS-level tailscaled provides it),
// authenticates clients via `tailscale whois`, routes 1:1 / room messages,
// and queues messages for offline nodes in SQLite.

import { createServer, type Socket } from 'node:net';
import { basename } from 'node:path';
import { fileURLToPath } from 'node:url';

import { FrameDecoder, encodeFrame, type ChatFrame } from './protocol.js';
import { runWhois } from './whois.js';
import { Store } from './store.js';
import { ChatRouter } from './router.js';

const HEARTBEAT_MS = 30_000; // idle interval before we ping
const PING_TIMEOUT_MS = 15_000; // grace after ping before dropping

export interface HubOptions {
  host?: string;
  port?: number;
  dbPath?: string;
  /** When true, require `tailscale whois` to confirm the connecting IP. Default true. */
  auth?: boolean;
}

interface Session {
  socket: Socket;
  decoder: FrameDecoder;
  nodeId: string | null;
  hostname: string | null;
  remoteIp: string;
  lastActivity: number;
  pingOutstanding: boolean;
}

interface IdempotentEntry {
  id: number;
  seq: number;
  ts: number;
  roomId: string | null;
  recipient: string | null;
  /** Epoch ms when this entry expires (24h after first insertion). */
  expiresAt: number;
}

export class Hub {
  readonly options: Required<HubOptions>;
  private readonly store: Store;
  private readonly router = new ChatRouter();
  // One node may hold several simultaneous connections (multi-device login).
  // The same nodeId on a phone + a PC both stay registered; messages are
  // pushed to EVERY session of the node so all devices stay in sync.
  private readonly sessions = new Map<string, Set<Session>>();
  private server?: ReturnType<typeof createServer>;
  private heartbeat?: NodeJS.Timeout;
  private startedPort = 0;

  // Phase 1.3 idempotency: (sender, clientMessageId) -> {id, seq, ts}.
  // A resend (e.g. after the client's 15s ack timeout) reuses the same
  // clientMessageId; the hub returns the original id/seq instead of
  // re-inserting and re-fan-out, so the recipient never sees a duplicate.
  // 24h TTL matches DESIGN §1.3. In-memory only: a hub restart drops it,
  // but a restart also drops the live socket so the client reconnects and
  // pulls history (deduped by hub id) — it never resends post-restart.
  private readonly idempotent = new Map<string, IdempotentEntry>();
  private static readonly IDEMPOTENT_TTL_MS = 24 * 60 * 60 * 1000;

  constructor(options: HubOptions = {}) {
    this.options = {
      host: options.host ?? '0.0.0.0',
      port: options.port ?? 8600,
      dbPath: options.dbPath ?? 'hub.db',
      auth: options.auth ?? true,
    };
    this.store = new Store(this.options.dbPath);
    // Restore room membership across restarts so group history stays
    // recoverable (VPS authoritative-storage role).
    for (const room of this.store.loadRooms()) {
      this.router.createRoom(room.id, room.name, room.owner);
      for (const member of room.members) this.router.joinRoom(room.id, member);
    }
  }

  /** Actual bound port (useful when port: 0). */
  get port(): number {
    return this.startedPort;
  }

  start(): Promise<void> {
    return new Promise((resolve, reject) => {
    this.server = createServer((socket) => this.onConnection(socket));
    // Log all server errors; reject only matters during startup (settled
    // promises ignore late reject calls, so this is safe after listen).
    this.server.on('error', (err) => {
      console.error('[hub] server error:', err);
      reject(err);
    });
    this.server.listen(this.options.port, this.options.host, () => {
        const addr = this.server!.address();
        this.startedPort =
          typeof addr === 'object' && addr !== null ? addr.port : this.options.port;
        console.log(
          `[hub] listening on ${this.options.host}:${this.startedPort} ` +
            `(auth=${this.options.auth ? 'on' : 'off'}, db=${this.options.dbPath})`,
        );
        this.heartbeat = setInterval(
          () => this.onHeartbeat(),
          Math.floor(HEARTBEAT_MS / 2),
        );
        this.heartbeat.unref();
        resolve();
      });
    });
  }

  stop(): Promise<void> {
    for (const set of this.sessions.values()) {
      for (const session of set) session.socket.destroy();
    }
    this.sessions.clear();
    this.idempotent.clear();
    this.store.close();
    if (this.heartbeat) clearInterval(this.heartbeat);
    return new Promise((resolve) => {
      if (!this.server) return resolve();
      this.server.close(() => resolve());
    });
  }

  // ─── Phase 1.3 idempotency ──────────────────────────────────────────
  // Keyed by `${sender}:${clientMessageId}`. Returns the cached insert
  // result if the same clientMessageId is reused within 24h, so a resend
  // (after the client's ack timeout) doesn't produce a duplicate row or a
  // duplicate fan-out. Expired entries are purged lazily on read/write.
  private idempotentKey(sender: string, clientMessageId: string): string {
    return `${sender}:${clientMessageId}`;
  }

  private idempotentGet(sender: string, clientMessageId: string): IdempotentEntry | null {
    const entry = this.idempotent.get(this.idempotentKey(sender, clientMessageId));
    if (!entry) return null;
    if (Date.now() > entry.expiresAt) {
      this.idempotent.delete(this.idempotentKey(sender, clientMessageId));
      return null;
    }
    return entry;
  }

  private idempotentSet(sender: string, clientMessageId: string, entry: IdempotentEntry): void {
    this.idempotent.set(this.idempotentKey(sender, clientMessageId), entry);
  }

  // ─── connection handling ───────────────────────────────────────────

  private onConnection(socket: Socket): void {
    const session: Session = {
      socket,
      decoder: new FrameDecoder(),
      nodeId: null,
      hostname: null,
      remoteIp: normalizeRemoteIp(socket.remoteAddress ?? ''),
      lastActivity: Date.now(),
      pingOutstanding: false,
    };
    socket.on('data', (chunk) => {
      try {
        for (const frame of session.decoder.push(chunk)) {
          session.lastActivity = Date.now();
          void this.onFrame(session, frame);
        }
      } catch (err) {
        console.error(`[hub] bad frame from ${session.remoteIp}: ${String(err)}`);
        socket.destroy();
      }
    });
    socket.on('error', (err) => {
      console.error(`[hub] socket error ${session.remoteIp}: ${err.message}`);
    });
    socket.on('close', () => this.onDisconnect(session));
  }

  private send(session: Session, frame: ChatFrame): void {
    session.socket.write(encodeFrame(frame));
  }

  private async onFrame(session: Session, frame: ChatFrame): Promise<void> {
    switch (frame.type) {
      case 'hello':
        return this.onHello(session, frame);
      case 'ping':
        return void this.send(session, { type: 'pong' });
      case 'pong':
        session.pingOutstanding = false;
        return;
      case 'bye':
        return void session.socket.end();
      case 'msg':
        return this.onDirectMessage(session, frame);
      case 'offline':
        return this.onOfflineRequest(session, frame);
      case 'read':
        return this.onReadReceipt(session, frame);
      case 'room/create':
        return this.onRoomCreate(session, frame);
      case 'room/join':
        return this.onRoomJoin(session, frame);
      case 'room/leave':
        return this.onRoomLeave(session, frame);
      case 'room/msg':
        return this.onRoomMessage(session, frame);
      case 'room/list':
        return this.onRoomList(session, frame);
      case 'room/members':
        return this.onRoomMembers(session, frame);
      case 'conv/clear':
        return void this.onConversationClear(session, frame);
      case 'typing':
        return void this.onTyping(session, frame);
      default:
        this.send(session, {
          type: 'ack',
          to: frame.from,
          payload: { ok: false, error: `unknown type: ${frame.type}` },
        });
    }
  }

  // ─── handlers ──────────────────────────────────────────────────────

  private async onHello(session: Session, frame: ChatFrame): Promise<void> {
    const nodeId = frame.from;
    if (!nodeId) {
      this.send(session, {
        type: 'ack',
        payload: { ok: false, error: 'hello requires from (stableNodeId)' },
      });
      return void session.socket.end();
    }
    // Computed after the null guard so `nodeId` is narrowed to string here.
    const hostname = (frame.payload?.['hostname'] as string | undefined) ?? nodeId;

    if (this.options.auth) {
      const identity = await runWhois(session.remoteIp);
      if (!identity || identity.nodeId !== nodeId) {
        const resolved = identity
          ? `${identity.nodeId}${identity.hostname ? ` (${identity.hostname})` : ''}`
          : 'none';
        console.warn(
          `[hub] whois rejected ${nodeId} from ${session.remoteIp} ` +
            `(resolved ${resolved})`,
        );
        // Self-diagnosing rejection: show the IP + what it resolved to (or
        // that it resolved to nothing) so the phone screen itself tells us
        // whether this was a netmap-sync race or a real identity mismatch.
        this.send(session, {
          type: 'ack',
          payload: {
            ok: false,
            error: identity
              ? `whois mismatch: ${session.remoteIp} 解析为 ${resolved}，客户端声称 ${nodeId}`
              : `whois: 未能在 tailnet 中解析 ${session.remoteIp}（netmap 未同步或设备已被删除）`,
          },
        });
        return void session.socket.end();
      }
    }

    // Multi-device: keep every existing session for this node instead of
    // replacing the old one, so a second device doesn't kick the first off.
    session.nodeId = nodeId;
    session.hostname = hostname;
    let set = this.sessions.get(nodeId);
    if (!set) {
      set = new Set();
      this.sessions.set(nodeId, set);
    }
    set.add(session);
    this.router.markOnline(nodeId);

    // Flush queued (offline) messages to the newly connected session. Mark
    // them delivered only when this is the node's ONLY session — if another
    // session was already live it may still be missing them, and history
    // pulls cover the rest.
    const queued = this.store.queuedFor(nodeId);
    for (const m of queued) {
      this.send(session, {
        type: 'msg',
        from: m.sender,
        to: nodeId,
        roomId: m.roomId ?? undefined,
        ts: m.ts,
        payload: { ...m.payload, queued: true, id: m.id, seq: m.seq },
      });
    }
    if (queued.length > 0 && set.size === 1) {
      this.store.markDelivered(queued.map((m) => m.id));
      console.log(`[hub] flushed ${queued.length} queued message(s) to ${nodeId}`);
    }

    this.send(session, { type: 'ack', to: nodeId, payload: { ok: true, hostname } });
    this.broadcastPresence();
    console.log(`[hub] online: ${nodeId} (${hostname}, ${session.remoteIp})`);
  }

  private onDisconnect(session: Session): void {
    const nodeId = session.nodeId;
    if (!nodeId) return;
    const set = this.sessions.get(nodeId);
    if (!set) return;
    set.delete(session);
    // Only drop the node when its LAST session left (other devices still on).
    if (set.size === 0) {
      this.sessions.delete(nodeId);
      this.router.markOffline(nodeId);
      console.log(`[hub] offline: ${nodeId}`);
    }
    this.broadcastPresence();
  }

  /** Every live session of a node (multi-device). */
  private sessionsOf(nodeId: string): Session[] {
    return [...(this.sessions.get(nodeId) ?? [])];
  }

  private onDirectMessage(session: Session, frame: ChatFrame): void {
    const sender = session.nodeId;
    const recipient = frame.to;
    if (!sender || !recipient) {
      return void this.send(session, {
        type: 'ack',
        to: sender ?? undefined,
        payload: { ok: false, error: 'msg requires from + to' },
      });
    }
    const ts = frame.ts ?? Date.now();
    const payload = frame.payload ?? {};
    // Phase 1.3 idempotency: a resend (client's 15s ack timeout fired but
    // the hub already inserted) reuses the same clientMessageId. Return the
    // original id/seq and skip both insert and fan-out so the recipient
    // never sees a duplicate.
    const clientMessageId = readClientMessageId(payload);
    if (clientMessageId) {
      const cached = this.idempotentGet(sender, clientMessageId);
      if (cached) {
        this.send(session, {
          type: 'ack',
          to: sender,
          ts: cached.ts,
          payload: {
            ok: true,
            ts: cached.ts,
            id: cached.id,
            seq: cached.seq,
            clientMessageId,
            deduped: true,
          },
        });
        return;
      }
    }
    // Authoritative storage: persist EVERY 1:1 message (VPS role), then
    // deliver live or queue for the offline recipient. `id` lets clients
    // dedup history against what they already have locally.
    const { id, seq } = this.store.insert(
      { roomId: null, sender, recipient, payload, ts },
      this.sessions.has(recipient),
    );
    if (clientMessageId) {
      this.idempotentSet(sender, clientMessageId, {
        id,
        seq,
        ts,
        roomId: null,
        recipient,
        expiresAt: Date.now() + Hub.IDEMPOTENT_TTL_MS,
      });
    }
    // Deliver to EVERY session of the recipient (all their devices), and also
    // to the sender's other sessions so their own devices see it live.
    const targets = this.sessionsOf(recipient);
    for (const t of targets) {
      this.send(t, { type: 'msg', from: sender, to: recipient, ts, payload: { ...payload, id, seq } });
    }
    for (const t of this.sessionsOf(sender)) {
      if (t !== session) this.send(t, { type: 'msg', from: sender, to: recipient, ts, payload: { ...payload, id, seq } });
    }
    if (targets.length === 0) {
      console.log(`[hub] queued msg ${sender} -> ${recipient}`);
    }
    this.send(session, {
      type: 'ack',
      to: sender,
      payload: { ok: true, ts, id, seq, ...(clientMessageId ? { clientMessageId } : {}) },
    });
  }

  private onOfflineRequest(session: Session, frame: ChatFrame): void {
    const nodeId = session.nodeId;
    if (!nodeId) return;
    const limit = (frame.payload?.['limit'] as number | undefined) ?? 200;
    // Incremental sync (Phase 1.2): client sends `after: {convId: lastSeq}`
    // on reconnect/refresh; the hub returns only newer messages per thread.
    const afterRaw = frame.payload?.['after'];
    const after =
      typeof afterRaw === 'object' && afterRaw !== null
        ? Object.fromEntries(
            Object.entries(afterRaw as Record<string, unknown>).filter(
              (entry): entry is [string, number] => typeof entry[1] === 'number',
            ),
          )
        : undefined;
    const messages = after
      ? this.store.incrementalFor(nodeId, this.router.roomsOf(nodeId), after, limit)
      : this.store.historyFor(nodeId, this.router.roomsOf(nodeId), limit);
    // `initial` marks the connect-time backlog so clients can suppress
    // notification spam for old messages (only live/queued-flush notify).
    this.send(session, {
      type: 'offline',
      to: nodeId,
      payload: { messages, initial: true },
    });
  }

  private onReadReceipt(session: Session, frame: ChatFrame): void {
    const reader = session.nodeId;
    const recipient = frame.to;
    if (!reader || !recipient) return;
    // Forward to every session of the recipient so read state (blue check)
    // syncs across their devices.
    for (const t of this.sessionsOf(recipient)) {
      this.send(t, {
        type: 'read',
        from: reader,
        to: recipient,
        ts: frame.ts,
        payload: frame.payload ?? {},
      });
    }
  }

  // Phase 2.1 typing indicator. The hub is a pure relay — typing state is
  // ephemeral and NEVER persisted (per DESIGN §1.6). Two routing shapes:
  //   1:1 (no roomId): forward to every session of `to` (the peer node).
  //   room (roomId set): forward to every session of every member EXCEPT the
  //     sender's own sessions (the sender's own devices don't need their own
  //     "typing" echo — unlike msgs, typing is not mirrored back to the sender).
  // No ack is sent: typing is fire-and-forget; a lost frame simply means the
  // indicator doesn't show, which is acceptable for a best-effort signal.
  private onTyping(session: Session, frame: ChatFrame): void {
    const sender = session.nodeId;
    if (!sender) return;
    const isStop = frame.payload?.['stop'] === true;
    const payload = { ...frame.payload, stop: isStop };
    const ts = frame.ts ?? Date.now();
    if (frame.roomId) {
      for (const member of this.router.roomMembers(frame.roomId)) {
        if (member === sender) continue;
        for (const t of this.sessionsOf(member)) {
          this.send(t, {
            type: 'typing',
            from: sender,
            roomId: frame.roomId,
            ts,
            payload,
          });
        }
      }
    } else {
      const recipient = frame.to;
      if (!recipient) return;
      for (const t of this.sessionsOf(recipient)) {
        this.send(t, {
          type: 'typing',
          from: sender,
          to: recipient,
          ts,
          payload,
        });
      }
    }
  }

  private onRoomCreate(session: Session, frame: ChatFrame): void {
    const owner = session.nodeId;
    const name = (frame.payload?.['name'] as string | undefined) ?? '群聊';
    if (!owner) return;
    const id = `room_${Date.now().toString(36)}${Math.random().toString(36).slice(2, 8)}`;
    this.router.createRoom(id, name, owner);
    this.store.saveRoom(this.router.roomById(id)!);
    this.send(session, {
      type: 'ack',
      to: owner,
      payload: { ok: true, roomId: id, name },
    });
  }

  private onRoomJoin(session: Session, frame: ChatFrame): void {
    const nodeId = session.nodeId;
    const roomId = frame.roomId;
    if (!nodeId || !roomId) return;
    const joined = this.router.joinRoom(roomId, nodeId);
    const room = this.router.roomById(roomId);
    if (room) this.store.saveRoom(room);
    // `joined` marker distinguishes this ack from room/create and room/msg acks
    // (all carry roomId) on the client side.
    this.send(session, {
      type: 'ack',
      to: nodeId,
      payload: { ok: joined, joined, roomId, name: room?.name },
    });
    if (joined) this.broadcastRoomPresence(roomId);
  }

  private onRoomLeave(session: Session, frame: ChatFrame): void {
    const nodeId = session.nodeId;
    const roomId = frame.roomId;
    if (!nodeId || !roomId) return;
    this.router.leaveRoom(roomId, nodeId);
    const room = this.router.roomById(roomId);
    if (room) this.store.saveRoom(room);
    this.send(session, { type: 'ack', to: nodeId, payload: { ok: true, roomId } });
    this.broadcastRoomPresence(roomId);
  }

  private onRoomMessage(session: Session, frame: ChatFrame): void {
    const sender = session.nodeId;
    const roomId = frame.roomId;
    if (!sender || !roomId) return;
    const ts = frame.ts ?? Date.now();
    const payload = frame.payload ?? {};
    // Phase 1.3 idempotency: same contract as 1:1 messages — a resend with
    // the same clientMessageId returns the original id/seq and skips both
    // the insert and the fan-out.
    const clientMessageId = readClientMessageId(payload);
    if (clientMessageId) {
      const cached = this.idempotentGet(sender, clientMessageId);
      if (cached) {
        this.send(session, {
          type: 'ack',
          to: sender,
          roomId,
          ts: cached.ts,
          payload: {
            ok: true,
            ts: cached.ts,
            id: cached.id,
            seq: cached.seq,
            clientMessageId,
            deduped: true,
          },
        });
        return;
      }
    }
    // Persist room messages too (authoritative history). recipient = roomId
    // so 1:1 history queries never match them.
    const { id, seq } = this.store.insert(
      { roomId, sender, recipient: roomId, payload, ts },
      true,
    );
    if (clientMessageId) {
      this.idempotentSet(sender, clientMessageId, {
        id,
        seq,
        ts,
        roomId,
        recipient: roomId,
        expiresAt: Date.now() + Hub.IDEMPOTENT_TTL_MS,
      });
    }
    // Deliver to every session of every member (multi-device), including the
    // sender's own other devices so their copies stay in sync live.
    for (const member of this.router.roomMembers(roomId)) {
      for (const t of this.sessionsOf(member)) {
        if (t !== session) {
          this.send(t, {
            type: 'room/msg',
            from: sender,
            roomId,
            ts,
            payload: { ...payload, id, seq },
          });
        }
      }
    }
    this.send(session, {
      type: 'ack',
      to: sender,
      roomId,
      payload: { ok: true, ts, id, seq, ...(clientMessageId ? { clientMessageId } : {}) },
    });
  }

  /**
   * Deletes a conversation's history on the hub: 1:1 (frame.to) or a room
   * (frame.roomId). Both sides lose the messages on their next history pull,
   * which is what the client's swipe-to-delete expects. The `cleared` marker
   * lets clients distinguish this ack from a plain msg ack.
   */
  private onConversationClear(session: Session, frame: ChatFrame): void {
    const nodeId = session.nodeId;
    const peer = frame.to; // 1:1 peer node
    const roomId = frame.roomId; // group room
    if (!nodeId || (!peer && !roomId)) return;
    this.store.clearConversation(nodeId, peer ?? null, roomId ?? null);
    this.send(session, {
      type: 'ack',
      to: nodeId,
      payload: { ok: true, cleared: roomId ?? peer },
    });
  }

  /** Lists all rooms so a client can browse and join existing groups (P3). */
  private onRoomList(session: Session, frame: ChatFrame): void {
    const nodeId = session.nodeId;
    if (!nodeId) return;
    const rooms = this.router.allRooms().map((room) => ({
      id: room.id,
      name: room.name,
      memberCount: room.members.size,
      isMember: room.members.has(nodeId),
    }));
    this.send(session, { type: 'room/list', to: nodeId, payload: { rooms } });
  }

  /** Returns a room's name + members with online status (P3). */
  private onRoomMembers(session: Session, frame: ChatFrame): void {
    const nodeId = session.nodeId;
    const roomId = frame.roomId;
    if (!nodeId || !roomId) return;
    const room = this.router.roomById(roomId);
    if (!room) {
      this.send(session, {
        type: 'room/members',
        to: nodeId,
        roomId,
        payload: { ok: false, error: '群不存在' },
      });
      return;
    }
    const members = [...room.members].map((id) => {
      const set = this.sessions.get(id);
      const online = set !== undefined && set.size > 0;
      return {
        id,
        hostname: online ? (set.values().next().value as Session | undefined)?.hostname ?? null : null,
        online,
      };
    });
    this.send(session, {
      type: 'room/members',
      to: nodeId,
      roomId,
      payload: { ok: true, name: room.name, members },
    });
  }

  // ─── presence & heartbeat ──────────────────────────────────────────

  private broadcastPresence(): void {
    // Carry hostnames so clients can show friendly titles instead of opaque
    // stable node ids (family-chat UX requirement). Dedupe by node id: a node
    // with several devices appears once in the presence list.
    const seen = new Set<string>();
    const online: { id: string; hostname: string }[] = [];
    for (const set of this.sessions.values()) {
      for (const s of set) {
        if (s.nodeId !== null && s.hostname !== null && !seen.has(s.nodeId)) {
          seen.add(s.nodeId);
          online.push({ id: s.nodeId, hostname: s.hostname });
        }
      }
    }
    const frame: ChatFrame = { type: 'presence', payload: { online } };
    for (const set of this.sessions.values()) {
      for (const session of set) this.send(session, frame);
    }
  }

  private broadcastRoomPresence(roomId: string): void {
    const members = this.router.roomMembers(roomId);
    const frame: ChatFrame = {
      type: 'presence',
      roomId,
      payload: { online: members },
    };
    // Deliver to every session of each member (multi-device).
    for (const member of members) {
      for (const target of this.sessionsOf(member)) this.send(target, frame);
    }
  }

  private onHeartbeat(): void {
    const now = Date.now();
    for (const set of this.sessions.values()) {
      for (const session of set) {
        const idle = now - session.lastActivity;
        if (idle > HEARTBEAT_MS && !session.pingOutstanding) {
          session.pingOutstanding = true;
          this.send(session, { type: 'ping' });
        } else if (session.pingOutstanding && idle > HEARTBEAT_MS + PING_TIMEOUT_MS) {
          console.warn(`[hub] heartbeat timeout, dropping ${session.nodeId ?? '?'}`);
          session.socket.destroy();
        }
      }
    }
  }
}

// Node's remoteAddress may be IPv6-mapped (`::ffff:a.b.c.d`) when the server
// listens on a dual-stack socket; strip the prefix so IP comparisons against
// TailscaleIPs (plain IPv4 / IPv6 strings) match.
function normalizeRemoteIp(ip: string): string {
  return ip.startsWith('::ffff:') ? ip.slice('::ffff:'.length) : ip;
}

// Phase 1.3: extracts the client-supplied idempotency key from a msg/room/msg
// payload. Returns null for legacy clients (no clientMessageId) so the hub
// stays backwards-compatible — those messages go through the original path.
function readClientMessageId(payload: Record<string, unknown>): string | null {
  const v = payload['clientMessageId'];
  return typeof v === 'string' && v.length > 0 ? v : null;
}

// ─── standalone entry point ──────────────────────────────────────────
// Compare basenames: tsx may pass argv[1] as a relative path on some setups,
// and Windows path separators differ from the file:// URL form.
const isMain =
  process.argv[1] !== undefined &&
  basename(fileURLToPath(import.meta.url)) === basename(process.argv[1]);

if (isMain) {
  const hub = new Hub({
    host: process.env.HUB_HOST ?? '0.0.0.0',
    port: Number(process.env.HUB_PORT ?? 8600),
    dbPath: process.env.HUB_DB ?? 'hub.db',
    auth: process.env.HUB_AUTH !== 'off',
  });
  hub.start().catch((err) => {
    console.error('[hub] failed to start:', err);
    process.exit(1);
  });
}

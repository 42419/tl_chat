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

export class Hub {
  readonly options: Required<HubOptions>;
  private readonly store: Store;
  private readonly router = new ChatRouter();
  private readonly sessions = new Map<string, Session>();
  private server?: ReturnType<typeof createServer>;
  private heartbeat?: NodeJS.Timeout;
  private startedPort = 0;

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
    for (const session of this.sessions.values()) session.socket.destroy();
    this.sessions.clear();
    this.store.close();
    if (this.heartbeat) clearInterval(this.heartbeat);
    return new Promise((resolve) => {
      if (!this.server) return resolve();
      this.server.close(() => resolve());
    });
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

    // Replace any existing session for this node (one connection per node).
    const existing = this.sessions.get(nodeId);
    if (existing && existing !== session) existing.socket.destroy();

    session.nodeId = nodeId;
    session.hostname = hostname;
    this.sessions.set(nodeId, session);
    this.router.markOnline(nodeId);

    // Flush queued (offline) messages.
    const queued = this.store.queuedFor(nodeId);
    for (const m of queued) {
      this.send(session, {
        type: 'msg',
        from: m.sender,
        to: nodeId,
        roomId: m.roomId ?? undefined,
        ts: m.ts,
        payload: { ...m.payload, queued: true, id: m.id },
      });
    }
    if (queued.length > 0) {
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
    if (this.sessions.get(nodeId) === session) {
      this.sessions.delete(nodeId);
      this.router.markOffline(nodeId);
      this.broadcastPresence();
      console.log(`[hub] offline: ${nodeId}`);
    }
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
    // Authoritative storage: persist EVERY 1:1 message (VPS role), then
    // deliver live or queue for the offline recipient. `id` lets clients
    // dedup history against what they already have locally.
    const id = this.store.insert(
      { roomId: null, sender, recipient, payload, ts },
      this.sessions.has(recipient),
    );
    const target = this.sessions.get(recipient);
    if (target) {
      this.send(target, {
        type: 'msg',
        from: sender,
        to: recipient,
        ts,
        payload: { ...payload, id },
      });
    } else {
      console.log(`[hub] queued msg ${sender} -> ${recipient}`);
    }
    this.send(session, {
      type: 'ack',
      to: sender,
      payload: { ok: true, ts, id },
    });
  }

  private onOfflineRequest(session: Session, frame: ChatFrame): void {
    const nodeId = session.nodeId;
    if (!nodeId) return;
    const limit = (frame.payload?.['limit'] as number | undefined) ?? 200;
    // Full history: 1:1 in both directions + the node's room messages.
    const messages = this.store.historyFor(nodeId, this.router.roomsOf(nodeId), limit);
    this.send(session, {
      type: 'offline',
      to: nodeId,
      payload: { messages },
    });
  }

  private onReadReceipt(session: Session, frame: ChatFrame): void {
    const reader = session.nodeId;
    const recipient = frame.to;
    if (!reader || !recipient) return;
    const target = this.sessions.get(recipient);
    if (target) {
      this.send(target, {
        type: 'read',
        from: reader,
        to: recipient,
        ts: frame.ts,
        payload: frame.payload ?? {},
      });
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
    this.send(session, { type: 'ack', to: nodeId, payload: { ok: joined, roomId } });
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
    // Persist room messages too (authoritative history). recipient = roomId
    // so 1:1 history queries never match them.
    const id = this.store.insert(
      { roomId, sender, recipient: roomId, payload, ts },
      true,
    );
    const members = this.router.roomMembers(roomId).filter((m) => m !== sender);
    for (const member of members) {
      const target = this.sessions.get(member);
      if (target) {
        this.send(target, {
          type: 'room/msg',
          from: sender,
          roomId,
          ts,
          payload: { ...payload, id },
        });
      }
    }
    this.send(session, {
      type: 'ack',
      to: sender,
      roomId,
      payload: { ok: true, ts, id },
    });
  }

  // ─── presence & heartbeat ──────────────────────────────────────────

  private broadcastPresence(): void {
    // Carry hostnames so clients can show friendly titles instead of opaque
    // stable node ids (family-chat UX requirement).
    const online = [...this.sessions.values()]
      .filter((s): s is Session & { nodeId: string; hostname: string } =>
        s.nodeId !== null && s.hostname !== null)
      .map((s) => ({ id: s.nodeId, hostname: s.hostname }));
    const frame: ChatFrame = { type: 'presence', payload: { online } };
    for (const session of this.sessions.values()) this.send(session, frame);
  }

  private broadcastRoomPresence(roomId: string): void {
    const members = this.router.roomMembers(roomId);
    const frame: ChatFrame = {
      type: 'presence',
      roomId,
      payload: { online: members },
    };
    for (const member of members) {
      const target = this.sessions.get(member);
      if (target) this.send(target, frame);
    }
  }

  private onHeartbeat(): void {
    const now = Date.now();
    for (const [nodeId, session] of this.sessions) {
      const idle = now - session.lastActivity;
      if (idle > HEARTBEAT_MS && !session.pingOutstanding) {
        session.pingOutstanding = true;
        this.send(session, { type: 'ping' });
      } else if (session.pingOutstanding && idle > HEARTBEAT_MS + PING_TIMEOUT_MS) {
        console.warn(`[hub] heartbeat timeout, dropping ${nodeId}`);
        session.socket.destroy();
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

// TL Chat 中心服务（轻量重写版）。
//
// 纯 Node.js 零框架：TCP 监听 → 帧分发 → SQLite 存储 → 在线转发/离线补发。
// 认证策略（轻量）：只接受来自 tailnet CGNAT 段（100.64.0.0/10）或回环地址
// 的连接，节点身份由 hello 帧的 stableNodeId 声明（tailnet 链路本身已加密）。
//
// 协议帧：见 PROTOCOL.md；编解码：protocol.js；存储：store.js。

'use strict';

const net = require('net');
const { Store } = require('./store');
const { encodeFrame, FrameDecoder } = require('./protocol');

const CGNAT = { start: ipToInt('100.64.0.0'), end: ipToInt('100.127.255.255') };

function ipToInt(ip) {
  return ip.split('.').reduce((acc, oct) => (acc << 8) + Number(oct), 0) >>> 0;
}

/** 是否允许该远端地址接入（tailnet CGNAT / IPv6 ULA 或回环，便于本机联调）。 */
function isAllowedRemote(remote) {
  const ip = remote.split(':')[0]; // IPv4 地址不包含 ':'
  if (ip === '::1' || ip === '127.0.0.1' || ip === '::ffff:127.0.0.1') return true;
  // Tailscale 的 IPv6 ULA 段：fd7a:115c:a1e0::/48。
  if (remote.startsWith('fd7a:115c:a1e0')) return true;
  const v4 = ip.replace(/^::ffff:/, '');
  const n = ipToInt(v4);
  return Number.isFinite(n) && n >= CGNAT.start && n <= CGNAT.end;
}

class Session {
  constructor(socket, remote) {
    this.socket = socket;
    this.remote = remote;
    this.decoder = new FrameDecoder();
    this.nodeId = null;
    this.hostname = null;
    this.lastActivity = Date.now();
    this.pendingPong = false;
  }
}

class Server {
  /**
   * @param {object} opts
   * @param {number} [opts.port=8600]  监听端口
   * @param {string} [opts.host='0.0.0.0']
   * @param {string} [opts.dbPath]      SQLite 路径（默认 data/chat.db）
   * @param {boolean} [opts.dev=false]  dev 模式：不校验远端地址
   */
  constructor(opts = {}) {
    this.port = opts.port ?? 8600;
    this.host = opts.host ?? '0.0.0.0';
    this.dev = opts.dev ?? false;
    this.store = new Store(opts.dbPath ?? 'data/chat.db');
    /** nodeId → Session（在线表）。 */
    this.sessions = new Map();
    this.netServer = null;
    this.sweeper = null;
  }

  start() {
    this.netServer = net.createServer((socket) => this._onConnection(socket));
    this.netServer.listen(this.port, this.host, () => {
      console.log(
        `[tl-chat] relay listening on ${this.host}:${this.port} (tailnet)` +
          (this.dev ? ' [dev]' : ''),
      );
    });
    // 每 15s 清扫：发送 ping + 判定失活连接。
    this.sweeper = setInterval(() => this._sweep(), 15_000);
    this.sweeper.unref();
  }

  stop() {
    clearInterval(this.sweeper);
    for (const s of this.sessions.values()) {
      s.socket.destroy();
    }
    this.sessions.clear();
    this.netServer?.close();
    this.store.close();
  }

  // ─── 连接生命周期 ─────────────────────────────────────────────────

  _onConnection(socket) {
    const remote = socket.remoteAddress || '?';
    if (!this.dev && !isAllowedRemote(remote)) {
      console.log(`[tl-chat] rejected non-tailnet peer ${remote}`);
      socket.write(encodeFrame({
        type: 'ack',
        payload: { ok: false, error: 'not a tailnet peer' },
      }));
      socket.destroy();
      return;
    }

    const session = new Session(socket, remote);
    socket.on('data', (chunk) => {
      session.lastActivity = Date.now();
      try {
        for (const frame of session.decoder.push(chunk)) {
          this._dispatch(session, frame);
        }
      } catch (e) {
        console.log(`[tl-chat] protocol error from ${remote}: ${e.message}`);
        socket.destroy();
      }
    });
    socket.on('error', () => {});
    socket.on('close', () => this._onClose(session));
  }

  _onClose(session) {
    if (session.nodeId && this.sessions.get(session.nodeId) === session) {
      this.sessions.delete(session.nodeId);
      console.log(`[tl-chat] peer offline: ${session.nodeId} (${session.hostname || '?'})`);
      this._broadcastPresence();
    }
  }

  // ─── 帧分发 ───────────────────────────────────────────────────────

  _dispatch(session, frame) {
    switch (frame.type) {
      case 'hello':
        return this._onHello(session, frame);
      case 'msg/send':
        return this._onMsgSend(session, frame);
      case 'msg/history':
        return this._onHistory(session, frame);
      case 'read':
        return this._relay(session, frame);
      case 'typing':
        return this._relay(session, frame);
      case 'ping':
        return this._send(session, { type: 'pong' });
      case 'pong':
        session.pendingPong = false;
        return;
      case 'bye':
        session.socket.end();
        return;
      default:
        this._send(session, {
          type: 'ack',
          to: session.nodeId ?? undefined,
          payload: { ok: false, error: `unknown frame: ${frame.type}` },
        });
    }
  }

  /** hello：注册身份 + 离线增量补发 + 广播 presence。 */
  _onHello(session, frame) {
    const nodeId = String(frame.from || '');
    if (!nodeId) {
      this._send(session, {
        type: 'ack',
        payload: { ok: false, error: 'hello requires from' },
      });
      return;
    }
    const hostname = String(frame.payload?.hostname || nodeId);
    const cursors = frame.payload?.cursors;

    // 同一节点重复连接：旧连接让位给新连接（新设备生效）。
    const prev = this.sessions.get(nodeId);
    if (prev && prev !== session) {
      prev.socket.destroy();
    }
    session.nodeId = nodeId;
    session.hostname = hostname;
    // 显示名落库：节点掉线/服务端重启后仍能找回，并下发给所有客户端。
    this.store.upsertName(nodeId, hostname);
    this.sessions.set(nodeId, session);
    console.log(`[tl-chat] peer online: ${nodeId} (${hostname})`);

    this._send(session, {
      type: 'ack',
      to: nodeId,
      payload: { ok: true, nodeId, names: this.store.allNames() },
    });

    // 离线增量补发：该用户参与的每个会话，推送 seq > 游标的消息。
    if (cursors instanceof Object && !Array.isArray(cursors)) {
      const limit = 500;
      for (const convId of this.store.conversationsOf(nodeId)) {
        const cursor = Number(cursors[convId]) || 0;
        const missing = this.store.afterCursor(convId, cursor, limit);
        for (const msg of missing) {
          this._pushMessage(session, msg, nodeId);
        }
      }
    }
    this._broadcastPresence();
  }

  /** msg/send：幂等落库 → ack 回发送者 → 在线则实时转发给收件人。 */
  _onMsgSend(session, frame) {
    const sender = session.nodeId;
    const peer = String(frame.to || '');
    const payload = frame.payload || {};
    const clientId = String(payload.clientId || '');
    const text = String(payload.text || '');
    const ts = Number(payload.ts) || Date.now();

    if (!sender || !peer || !clientId || !text) {
      this._send(session, {
        type: 'ack',
        to: sender ?? undefined,
        payload: { ok: false, error: 'msg/send requires to/clientId/text' },
      });
      return;
    }

    const convId = Store.convIdFor(sender, peer);
    const result = this.store.append({
      convId,
      sender,
      clientId,
      text,
      ts,
    });

    this._send(session, {
      type: 'ack',
      to: sender,
      payload: {
        ok: true,
        clientId,
        serverId: result.serverId,
        seq: result.seq,
        conv: convId,
      },
    });

    // 重复投递（重发）不再次推送；新消息则实时转发给在线的收件人。
    if (!result.duplicate) {
      const recipient = this.sessions.get(peer);
      if (recipient) {
        this._pushMessage(recipient, {
          conv: convId,
          sender,
          clientId,
          text,
          ts,
          serverId: result.serverId,
          seq: result.seq,
          hostname: session.hostname || this.store.nameOf(sender) || '',
        });
      }
    }
  }

  /** msg/history：游标分页（seq < beforeSeq），旧→新返回。 */
  _onHistory(session, frame) {
    const nodeId = session.nodeId;
    const peer = String(frame.to || '');
    const payload = frame.payload || {};
    const beforeSeq = Number(payload.beforeSeq);
    const limit = Math.max(1, Math.min(Number(payload.limit) || 30, 100));
    if (!nodeId || !peer || !Number.isFinite(beforeSeq) || beforeSeq <= 0) {
      this._send(session, {
        type: 'ack',
        to: nodeId ?? undefined,
        payload: { ok: false, error: 'msg/history requires to/beforeSeq' },
      });
      return;
    }
    const convId = Store.convIdFor(nodeId, peer);
    const messages = this.store.historyBefore(convId, beforeSeq, limit);
    this._send(session, {
      type: 'msg/history_result',
      to: nodeId,
      payload: { hasMore: messages.length >= limit, messages },
    });
  }

  /** read / typing：原样转发给收件人。 */
  _relay(session, frame) {
    const from = session.nodeId;
    const to = String(frame.to || '');
    if (!from || !to) return;
    const recipient = this.sessions.get(to);
    if (recipient) {
      this._send(recipient, {
        type: frame.type,
        from,
        to,
        payload: frame.payload ?? {},
      });
    }
  }

  // ─── 推送 / presence ──────────────────────────────────────────────

  _pushMessage(session, msg, toNodeId) {
    this._send(session, {
      type: 'msg/push',
      to: toNodeId,
      payload: { msg },
    });
  }

  _broadcastPresence() {
    const online = [];
    for (const s of this.sessions.values()) {
      if (s.nodeId) {
        online.push({
          id: s.nodeId,
          name: this.store.nameOf(s.nodeId) || s.hostname || s.nodeId,
        });
      }
    }
    const frame = encodeFrame({ type: 'presence', payload: { online } });
    for (const s of this.sessions.values()) {
      s.socket.write(frame);
    }
  }

  // ─── 心跳 / 失活检测 ──────────────────────────────────────────────

  _sweep() {
    const now = Date.now();
    for (const session of this.sessions.values()) {
      if (session.pendingPong && now - session.lastActivity > 45_000) {
        // 上次 ping 后 45s 无任何数据（含 pong）→ 判死。
        console.log(`[tl-chat] heartbeat timeout: ${session.nodeId}`);
        session.socket.destroy();
        continue;
      }
      if (!session.pendingPong) {
        session.pendingPong = true;
        this._send(session, { type: 'ping' });
      }
    }
  }

  _send(session, frame) {
    try {
      session.socket.write(encodeFrame(frame));
    } catch (_) {
      session.socket.destroy();
    }
  }
}

// ─── 入口 ────────────────────────────────────────────────────────────

function main() {
  const args = process.argv.slice(2);
  const opt = (name) => {
    const i = args.indexOf(name);
    return i >= 0 ? args[i + 1] : undefined;
  };
  const server = new Server({
    port: Number(opt('--port')) || 8600,
    host: opt('--host') || '0.0.0.0',
    dbPath: opt('--db') || 'data/chat.db',
    dev: args.includes('--dev'),
  });
  server.start();
  for (const sig of ['SIGINT', 'SIGTERM']) {
    process.on(sig, () => {
      console.log('\n[tl-chat] shutting down');
      server.stop();
      process.exit(0);
    });
  }
}

if (require.main === module) {
  main();
}

module.exports = { Server };

// TL Chat 中心服务（轻量重写版）。
//
// 纯 Node.js 零框架：TCP 监听 → 帧分发 → SQLite 存储 → 在线转发/离线补发。
// 网络层：只接受来自 tailnet CGNAT 段（100.64.0.0/10）或回环地址的连接
// （纵深防御的一层，不是身份认证——tailnet 链路加密只保证传输层安全）。
// 应用层身份：节点必须通过配对令牌校验（见 _onHello 上方注释），不再
// 单纯信任 hello 帧自报的 stableNodeId，防止任意 tailnet 设备冒充他人
// 接管会话 / 越权读取历史消息。
//
// 协议帧：见 PROTOCOL.md；编解码：protocol.js；存储：store.js。

"use strict";

const net = require("net");
const crypto = require("node:crypto");
const { Store } = require("./store");
const { encodeFrame, FrameDecoder } = require("./protocol");

const CGNAT = { start: ipToInt("100.64.0.0"), end: ipToInt("100.127.255.255") };

/** 单条消息文本上限（字符数）；防止单条超大消息拖垮存储/带宽。 */
const MAX_TEXT_LENGTH = 8000;

/** 简单令牌桶限流：每个连接每 10s 最多 20 条 msg/send。 */
const RATE_LIMIT_WINDOW_MS = 10_000;
const RATE_LIMIT_MAX = 20;

function sha256Hex(input) {
  return crypto.createHash("sha256").update(input, "utf8").digest("hex");
}

/** 常数时间比较两个十六进制哈希串，避免时序侧信道。 */
function hashEquals(a, b) {
  if (typeof a !== "string" || typeof b !== "string") return false;
  const bufA = Buffer.from(a, "hex");
  const bufB = Buffer.from(b, "hex");
  if (bufA.length !== bufB.length || bufA.length === 0) return false;
  return crypto.timingSafeEqual(bufA, bufB);
}

function ipToInt(ip) {
  return ip.split(".").reduce((acc, oct) => (acc << 8) + Number(oct), 0) >>> 0;
}

/** 是否允许该远端地址接入（tailnet CGNAT / IPv6 ULA 或回环，便于本机联调）。 */
function isAllowedRemote(remote) {
  const ip = remote.split(":")[0]; // IPv4 地址不包含 ':'
  if (ip === "::1" || ip === "127.0.0.1" || ip === "::ffff:127.0.0.1")
    return true;
  // Tailscale 的 IPv6 ULA 段：fd7a:115c:a1e0::/48。
  if (remote.startsWith("fd7a:115c:a1e0")) return true;
  const v4 = ip.replace(/^::ffff:/, "");
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
    // 限流：滑动窗口内已发送 msg/send 计数。
    this.sendWindowStart = Date.now();
    this.sendCount = 0;
  }
}

class Server {
  /**
   * @param {object} opts
   * @param {number} [opts.port=8600]  监听端口
   * @param {string} [opts.host='0.0.0.0']
   * @param {string} [opts.dbPath]      SQLite 路径（默认 data/chat.db）
   * @param {boolean} [opts.dev=false]  dev 模式：不校验远端地址，也不强制配对码
   * @param {string} [opts.pairSecret]  配对码：新设备首次注册时必须提供，
   *                                    防止任意 tailnet 节点自报他人身份接管会话。
   */
  constructor(opts = {}) {
    this.port = opts.port ?? 8600;
    this.host = opts.host ?? "0.0.0.0";
    this.dev = opts.dev ?? false;
    this.pairSecret = opts.pairSecret ?? null;
    this.store = new Store(opts.dbPath ?? "data/chat.db");
    /** nodeId → Session（在线表）。 */
    this.sessions = new Map();
    this.netServer = null;
    this.sweeper = null;
  }

  start() {
    if (this.dev) {
      console.log(
        "\n" +
          "########################################################\n" +
          "#  [tl-chat] 警告：--dev 模式已启用                    #\n" +
          "#  已关闭 tailnet 网段校验与配对码强制要求，任何能连到  #\n" +
          "#  本端口的连接都会被接受。仅限本机联调，切勿在真实     #\n" +
          "#  部署（尤其是端口可能被外部访问到）时使用此参数。     #\n" +
          "########################################################\n",
      );
    } else if (!this.pairSecret) {
      this.pairSecret = crypto.randomBytes(16).toString("hex");
      console.log(
        "\n########################################################\n" +
          "[tl-chat] 未指定配对码，已自动生成一次性配对码：\n\n" +
          `    ${this.pairSecret}\n\n` +
          "请把这段配对码告知需要加入的家人/设备（App 首次配置时填写）。\n" +
          "重启服务会生成新的配对码，已注册过的设备不受影响；建议改用\n" +
          "--pair-secret <固定值> 参数把配对码固定下来，避免每次重启变化。\n" +
          "########################################################\n",
      );
    }
    if (!this.dev && this.host === "0.0.0.0") {
      console.log(
        "[tl-chat] 提示：当前监听 0.0.0.0（所有网卡）。若本机除 " +
          "tailscale 外还有其他可达网络（公网/局域网），建议改用 " +
          "--host <本机 tailscale 100.x 地址> 只在 tailnet 网卡上监听，" +
          "而不要仅依赖源 IP 网段校验。",
      );
    }
    this.netServer = net.createServer((socket) => this._onConnection(socket));
    this.netServer.listen(this.port, this.host, () => {
      console.log(
        `[tl-chat] relay listening on ${this.host}:${this.port} (tailnet)` +
          (this.dev ? " [dev]" : ""),
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
    const remote = socket.remoteAddress || "?";
    if (!this.dev && !isAllowedRemote(remote)) {
      console.log(`[tl-chat] rejected non-tailnet peer ${remote}`);
      socket.write(
        encodeFrame({
          type: "ack",
          payload: { ok: false, error: "not a tailnet peer" },
        }),
      );
      socket.destroy();
      return;
    }

    const session = new Session(socket, remote);
    socket.on("data", (chunk) => {
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
    socket.on("error", () => {});
    socket.on("close", () => this._onClose(session));
  }

  _onClose(session) {
    if (session.nodeId && this.sessions.get(session.nodeId) === session) {
      this.sessions.delete(session.nodeId);
      console.log(
        `[tl-chat] peer offline: ${session.nodeId} (${session.hostname || "?"})`,
      );
      this._broadcastPresence();
    }
  }

  // ─── 帧分发 ───────────────────────────────────────────────────────

  _dispatch(session, frame) {
    switch (frame.type) {
      case "hello":
        return this._onHello(session, frame);
      case "msg/send":
        return this._onMsgSend(session, frame);
      case "msg/history":
        return this._onHistory(session, frame);
      case "msg/recall":
        return this._onMsgRecall(session, frame);
      case "read":
        return this._relay(session, frame);
      case "typing":
        return this._relay(session, frame);
      case "ping":
        return this._send(session, { type: "pong" });
      case "pong":
        session.pendingPong = false;
        return;
      case "bye":
        session.socket.end();
        return;
      default:
        this._send(session, {
          type: "ack",
          to: session.nodeId ?? undefined,
          payload: { ok: false, error: `unknown frame: ${frame.type}` },
        });
    }
  }

  /**
   * hello：身份校验（配对令牌） + 注册 + 离线增量补发 + 广播 presence。
   *
   * 安全说明：早期版本直接信任 hello 帧里客户端自报的 `from` 作为节点
   * 身份（"tailnet 链路本身加密"只保证传输层安全，不等于验证了应用层
   * 身份），导致任何能连上 tailnet 的设备都可以自报别人的 nodeId 接管
   * 会话、越权读取历史。现在改为：
   *   - 未注册过的 nodeId：必须携带正确的配对码（payload.pairSecret，
   *     启动服务时通过 --pair-secret 指定或首次启动自动生成并打印），
   *     校验通过后为该 nodeId 生成一个随机长期令牌，哈希后持久化，
   *     原始令牌通过 ack 一次性下发给客户端，由客户端本地持久化。
   *   - 已注册过的 nodeId：必须携带与库中哈希匹配的令牌
   *     （payload.token），否则拒绝——即使对方能连上 tailnet 且知道
   *     nodeId，没有令牌也无法接管这个身份。
   * --dev 模式下跳过校验，仅用于本机联调。
   */
  _onHello(session, frame) {
    const nodeId = String(frame.from || "");
    if (!nodeId) {
      this._send(session, {
        type: "ack",
        payload: { ok: false, error: "hello requires from" },
      });
      return;
    }
    const hostname = String(frame.payload?.hostname || nodeId);
    const cursors = frame.payload?.cursors;
    const providedToken = frame.payload?.token
      ? String(frame.payload.token)
      : null;
    const providedPairSecret = frame.payload?.pairSecret
      ? String(frame.payload.pairSecret)
      : null;

    let issuedToken = null;
    if (!this.dev) {
      const existingHash = this.store.tokenHashOf(nodeId);
      if (existingHash) {
        const okToken =
          providedToken && hashEquals(sha256Hex(providedToken), existingHash);
        if (!okToken) {
          console.log(
            `[tl-chat] hello 拒绝：${nodeId} 令牌校验失败（疑似身份伪造/需要重新配对）`,
          );
          this._send(session, {
            type: "ack",
            payload: {
              ok: false,
              error: "token 校验失败，请在设置中重新配对该设备",
            },
          });
          session.socket.destroy();
          return;
        }
      } else {
        const okPair =
          providedPairSecret &&
          this.pairSecret &&
          hashEquals(sha256Hex(providedPairSecret), sha256Hex(this.pairSecret));
        if (!okPair) {
          console.log(`[tl-chat] hello 拒绝：${nodeId} 配对码缺失或错误`);
          this._send(session, {
            type: "ack",
            payload: { ok: false, error: "配对码缺失或错误" },
          });
          session.socket.destroy();
          return;
        }
        issuedToken = crypto.randomBytes(24).toString("hex");
        this.store.bindToken(nodeId, sha256Hex(issuedToken));
        console.log(`[tl-chat] 新设备配对成功：${nodeId}`);
      }
    }

    // 同一节点重复连接：旧连接让位给新连接（新设备生效）。
    // 注意：走到这里说明已通过上面的令牌/配对码校验，不再是无条件信任。
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
      type: "ack",
      to: nodeId,
      payload: {
        ok: true,
        nodeId,
        names: this.store.allNames(),
        token: issuedToken || undefined,
      },
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

  /** msg/send：限流 + 长度校验 → 幂等落库 → ack 回发送者 → 在线则实时转发给收件人。 */
  _onMsgSend(session, frame) {
    const sender = session.nodeId;
    const peer = String(frame.to || "");
    const payload = frame.payload || {};
    const clientId = String(payload.clientId || "");
    const text = String(payload.text || "");
    const ts = Number(payload.ts) || Date.now();
    const forwardedFrom = String(payload.forwardedFrom || "");

    if (!sender || !peer || !clientId || !text) {
      this._send(session, {
        type: "ack",
        to: sender ?? undefined,
        payload: { ok: false, error: "msg/send requires to/clientId/text" },
      });
      return;
    }

    if (text.length > MAX_TEXT_LENGTH) {
      this._send(session, {
        type: "ack",
        to: sender,
        payload: {
          ok: false,
          clientId,
          error: `消息过长（上限 ${MAX_TEXT_LENGTH} 字符）`,
        },
      });
      return;
    }

    if (!this._checkRateLimit(session)) {
      this._send(session, {
        type: "ack",
        to: sender,
        payload: { ok: false, clientId, error: "发送过于频繁，请稍后再试" },
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
      forwardedFrom,
    });

    this._send(session, {
      type: "ack",
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
          hostname: session.hostname || this.store.nameOf(sender) || "",
          recalled: false,
          forwardedFrom: forwardedFrom || undefined,
        });
      }
    }
  }

  /**
   * msg/recall：发送者撤回自己的消息。服务端校验归属并落库 recalled=1，
   * ack 回发送者，并向收件人（在线会话）及发送者其他设备广播 msg/recalled。
   */
  _onMsgRecall(session, frame) {
    const sender = session.nodeId;
    if (!sender) return;
    const id = Number(frame.payload?.id);
    if (!Number.isFinite(id) || id <= 0) {
      this._send(session, {
        type: "ack",
        to: sender,
        payload: { ok: false, error: "msg/recall requires payload.id", id },
      });
      return;
    }
    const info = this.store.markRecalled(id, sender);
    if (!info) {
      this._send(session, {
        type: "ack",
        to: sender,
        payload: {
          ok: false,
          error: "recall denied (not owner or unknown id)",
          id,
        },
      });
      return;
    }
    const recalledAt = Date.now();
    const recipients = [];
    const recipientSession = info.recipient
      ? this.sessions.get(info.recipient)
      : undefined;
    if (recipientSession) recipients.push(recipientSession);
    // 发送者的其他会话（多设备）也要同步刷新。
    for (const s of this.sessions.values()) {
      if (s.nodeId === sender && s !== session) recipients.push(s);
    }
    for (const s of recipients) {
      this._send(s, {
        type: "msg/recalled",
        from: sender,
        to: info.recipient ?? undefined,
        ts: info.ts,
        payload: { id, recalledAt },
      });
    }
    this._send(session, {
      type: "ack",
      to: sender,
      payload: { ok: true, id, recalledAt },
    });
    console.log(`[tl-chat] recalled msg ${id} by ${sender}`);
  }

  /** msg/history：游标分页（seq < beforeSeq），旧→新返回。 */
  _onHistory(session, frame) {
    const nodeId = session.nodeId;
    const peer = String(frame.to || "");
    const payload = frame.payload || {};
    const beforeSeq = Number(payload.beforeSeq);
    const limit = Math.max(1, Math.min(Number(payload.limit) || 30, 100));
    if (!nodeId || !peer || !Number.isFinite(beforeSeq) || beforeSeq <= 0) {
      this._send(session, {
        type: "ack",
        to: nodeId ?? undefined,
        payload: { ok: false, error: "msg/history requires to/beforeSeq" },
      });
      return;
    }
    const convId = Store.convIdFor(nodeId, peer);
    const messages = this.store.historyBefore(convId, beforeSeq, limit);
    this._send(session, {
      type: "msg/history_result",
      to: nodeId,
      payload: { hasMore: messages.length >= limit, messages },
    });
  }

  /** read / typing：原样转发给收件人。 */
  _relay(session, frame) {
    const from = session.nodeId;
    const to = String(frame.to || "");
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
      type: "msg/push",
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
    const frame = encodeFrame({ type: "presence", payload: { online } });
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
        this._send(session, { type: "ping" });
      }
    }
  }

  /** 滑动窗口限流：每连接每 RATE_LIMIT_WINDOW_MS 最多 RATE_LIMIT_MAX 条消息。 */
  _checkRateLimit(session) {
    const now = Date.now();
    if (now - session.sendWindowStart >= RATE_LIMIT_WINDOW_MS) {
      session.sendWindowStart = now;
      session.sendCount = 0;
    }
    session.sendCount += 1;
    return session.sendCount <= RATE_LIMIT_MAX;
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
    port: Number(opt("--port")) || 8600,
    host: opt("--host") || "0.0.0.0",
    dbPath: opt("--db") || "data/chat.db",
    dev: args.includes("--dev"),
    pairSecret: opt("--pair-secret") || process.env.TL_CHAT_PAIR_SECRET,
  });
  server.start();
  for (const sig of ["SIGINT", "SIGTERM"]) {
    process.on(sig, () => {
      console.log("\n[tl-chat] shutting down");
      server.stop();
      process.exit(0);
    });
  }
}

if (require.main === module) {
  main();
}

module.exports = { Server };

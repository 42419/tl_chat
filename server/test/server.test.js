// 服务端集成测试（node --test）。
//
// 覆盖：hello 注册、消息收发与幂等去重、离线增量补发、历史分页、
// presence 广播、read/typing 转发、心跳存活。

"use strict";

const { test, beforeEach, afterEach } = require("node:test");
const assert = require("node:assert/strict");
const net = require("net");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");

const { Server } = require("../src/server");
const { encodeFrame, FrameDecoder } = require("../src/protocol");

let server;
let port;

// 每个用例独立服务实例 + 独立内存库，避免消息/会话跨用例泄漏。
beforeEach(async () => {
  server = new Server({
    port: 0,
    host: "127.0.0.1",
    dbPath: ":memory:",
    dev: true,
  });
  server.start();
  await new Promise((resolve) => server.netServer.once("listening", resolve));
  port = server.netServer.address().port;
});

afterEach(() => {
  server.stop();
});

// ─── 测试客户端 ──────────────────────────────────────────────────────

class TestClient {
  constructor(portOverride) {
    this.socket = net.connect({
      port: portOverride ?? port,
      host: "127.0.0.1",
    });
    this.decoder = new FrameDecoder();
    this.frames = [];
    this.waiters = [];
    this.socket.on("data", (chunk) => {
      for (const frame of this.decoder.push(chunk)) {
        this.frames.push(frame);
        for (let i = this.waiters.length - 1; i >= 0; i--) {
          const w = this.waiters[i];
          if (w.pred(frame)) {
            this.waiters.splice(i, 1);
            w.resolve(frame);
          }
        }
      }
    });
    this.ready = new Promise((r) => this.socket.once("connect", r));
  }

  send(frame) {
    this.socket.write(encodeFrame(frame));
  }

  /** 等待满足 pred 的帧（最多 2s）。 */
  waitFor(pred, timeoutMs = 2000) {
    const hit = this.frames.find(pred);
    if (hit) return Promise.resolve(hit);
    return new Promise((resolve, reject) => {
      const w = { pred, resolve };
      this.waiters.push(w);
      setTimeout(() => {
        const i = this.waiters.indexOf(w);
        if (i >= 0) this.waiters.splice(i, 1);
        reject(new Error("timeout waiting for frame"));
      }, timeoutMs);
    });
  }

  close() {
    this.socket.destroy();
  }
}

/** 等待两个客户端各自完成 hello。 */
async function helloPair() {
  const a = new TestClient();
  const b = new TestClient();
  await Promise.all([a.ready, b.ready]);
  a.send({ type: "hello", from: "node-a", payload: { hostname: "alice" } });
  b.send({ type: "hello", from: "node-b", payload: { hostname: "bob" } });
  const [ackA, ackB] = await Promise.all([
    a.waitFor((f) => f.type === "ack" && f.payload?.ok),
    b.waitFor((f) => f.type === "ack" && f.payload?.ok),
  ]);
  assert.equal(ackA.payload.nodeId, "node-a");
  assert.equal(ackB.payload.nodeId, "node-b");
  return { a, b };
}

test("hello 注册 + presence 广播", async () => {
  const { a, b } = await helloPair();
  const presence = await a.waitFor(
    (f) => f.type === "presence" && f.payload?.online?.length >= 2,
  );
  const ids = presence.payload.online.map((x) => x.id);
  assert.deepEqual(new Set(ids), new Set(["node-a", "node-b"]));
  a.close();
  b.close();
});

test("消息收发：ack 回执 + 实时 push + 幂等去重", async () => {
  const { a, b } = await helloPair();
  a.send({
    type: "msg/send",
    from: "node-a",
    to: "node-b",
    payload: { clientId: "c1", text: "你好", ts: 1000 },
  });
  const ack = await a.waitFor(
    (f) => f.type === "ack" && f.payload?.clientId === "c1",
  );
  assert.equal(ack.payload.ok, true);
  assert.equal(ack.payload.seq, 1);
  assert.equal(ack.payload.conv, "node-a:node-b");

  const push = await b.waitFor((f) => f.type === "msg/push");
  assert.equal(push.payload.msg.sender, "node-a");
  assert.equal(push.payload.msg.text, "你好");
  assert.equal(push.payload.msg.seq, 1);
  assert.equal(push.payload.msg.conv, "node-a:node-b");

  // 相同 clientId 重发 → ack 返回同一 serverId/seq，且不二次推送。
  const pushesBefore = b.frames.filter((f) => f.type === "msg/push").length;
  a.send({
    type: "msg/send",
    from: "node-a",
    to: "node-b",
    payload: { clientId: "c1", text: "你好", ts: 1000 },
  });
  const dupAck = await a.waitFor(
    (f) =>
      f.type === "ack" &&
      f.payload?.clientId === "c1" &&
      f.payload?.serverId === ack.payload.serverId,
  );
  assert.equal(dupAck.payload.ok, true);
  assert.equal(dupAck.payload.seq, ack.payload.seq);
  await new Promise((r) => setTimeout(r, 100));
  assert.equal(
    b.frames.filter((f) => f.type === "msg/push").length,
    pushesBefore,
  );
  a.close();
  b.close();
});

test("离线增量补发：游标之前的消息不下发，之后的下发", async () => {
  // b 先上线收一条，再离线。
  const { a, b } = await helloPair();
  a.send({
    type: "msg/send",
    from: "node-a",
    to: "node-b",
    payload: { clientId: "o1", text: "离线前", ts: 2000 },
  });
  await b.waitFor(
    (f) => f.type === "msg/push" && f.payload.msg.text === "离线前",
  );
  b.close();
  await new Promise((r) => setTimeout(r, 50));

  // a 在 b 离线时发一条。
  a.send({
    type: "msg/send",
    from: "node-a",
    to: "node-b",
    payload: { clientId: "o2", text: "离线中", ts: 3000 },
  });
  await a.waitFor((f) => f.type === "ack" && f.payload?.clientId === "o2");

  // b 重连：游标已到 seq 1 → 只应补发 seq 2。
  const b2 = new TestClient();
  await b2.ready;
  b2.send({
    type: "hello",
    from: "node-b",
    payload: { hostname: "bob", cursors: { "node-a:node-b": 1 } },
  });
  await b2.waitFor((f) => f.type === "ack" && f.payload?.ok);
  const pushed = await b2.waitFor((f) => f.type === "msg/push");
  assert.equal(pushed.payload.msg.text, "离线中");
  assert.equal(pushed.payload.msg.seq, 2);
  await new Promise((r) => setTimeout(r, 100));
  // 不应再有第二条 push（离线前的消息游标已覆盖）。
  assert.equal(b2.frames.filter((f) => f.type === "msg/push").length, 1);
  a.close();
  b2.close();
});

test("历史分页：beforeSeq 游标 + hasMore", async () => {
  const { a, b } = await helloPair();
  for (let i = 1; i <= 5; i++) {
    a.send({
      type: "msg/send",
      from: "node-a",
      to: "node-b",
      payload: { clientId: `h${i}`, text: `msg${i}`, ts: 4000 + i },
    });
    await a.waitFor((f) => f.type === "ack" && f.payload?.clientId === `h${i}`);
  }
  a.send({
    type: "msg/history",
    from: "node-a",
    to: "node-b",
    payload: { beforeSeq: 6, limit: 3 },
  });
  const result = await a.waitFor((f) => f.type === "msg/history_result");
  assert.equal(result.payload.messages.length, 3);
  assert.equal(result.payload.hasMore, true);
  assert.deepEqual(
    result.payload.messages.map((m) => m.text),
    ["msg3", "msg4", "msg5"],
  );
  // 第一页再往前 → hasMore=false。
  a.send({
    type: "msg/history",
    from: "node-a",
    to: "node-b",
    payload: { beforeSeq: 3, limit: 3 },
  });
  const page1 = await a.waitFor(
    (f) =>
      f.type === "msg/history_result" && f.payload.messages[0]?.text === "msg1",
  );
  assert.equal(page1.payload.messages.length, 2);
  assert.equal(page1.payload.hasMore, false);
  a.close();
  b.close();
});

test("read / typing 转发", async () => {
  const { a, b } = await helloPair();
  b.send({
    type: "read",
    from: "node-b",
    to: "node-a",
    payload: { upToTs: 9999 },
  });
  const read = await a.waitFor((f) => f.type === "read");
  assert.equal(read.from, "node-b");
  assert.equal(read.payload.upToTs, 9999);

  b.send({
    type: "typing",
    from: "node-b",
    to: "node-a",
    payload: { on: true },
  });
  const typing = await a.waitFor((f) => f.type === "typing");
  assert.equal(typing.from, "node-b");
  assert.equal(typing.payload.on, true);
  a.close();
  b.close();
});

test("节点显示名持久化：重启后 ack 仍带 names，离线补发带 hostname", async () => {
  const dbPath = path.join(
    os.tmpdir(),
    `tlchat-names-${process.pid}-${Date.now()}.db`,
  );
  let s1;
  let s2;
  const clients = [];
  const track = (c) => {
    clients.push(c);
    return c;
  };
  try {
    // 第一代服务：a 注册 alice。
    s1 = new Server({ port: 0, host: "127.0.0.1", dbPath, dev: true });
    s1.start();
    await new Promise((r) => s1.netServer.once("listening", r));
    const a = track(new TestClient(s1.netServer.address().port));
    await a.ready;
    a.send({ type: "hello", from: "node-a", payload: { hostname: "alice" } });
    const ackA = await a.waitFor((f) => f.type === "ack" && f.payload?.ok);
    assert.equal(ackA.payload.names["node-a"], "alice");
    a.close();
    s1.stop();
    s1 = null;

    // 第二代服务（同一 DB）：旧节点名字仍在，新节点名字立即可见。
    s2 = new Server({ port: 0, host: "127.0.0.1", dbPath, dev: true });
    s2.start();
    await new Promise((r) => s2.netServer.once("listening", r));
    const c = track(new TestClient(s2.netServer.address().port));
    await c.ready;
    c.send({ type: "hello", from: "node-c", payload: { hostname: "carol" } });
    const ackC = await c.waitFor((f) => f.type === "ack" && f.payload?.ok);
    assert.equal(ackC.payload.names["node-a"], "alice");
    assert.equal(ackC.payload.names["node-c"], "carol");

    // 离线补发带 hostname：node-a 不在线时 node-c 发消息，node-a 重连后
    // 收到补发消息，hostname 来自持久化（carol）而非在线会话。
    c.send({
      type: "msg/send",
      from: "node-c",
      to: "node-a",
      payload: { clientId: "n1", text: "在吗", ts: 5000 },
    });
    await c.waitFor((f) => f.type === "ack" && f.payload?.clientId === "n1");
    const a2 = track(new TestClient(s2.netServer.address().port));
    await a2.ready;
    // 空游标 = 全量补发（离线同步要求 cursors 存在才执行）。
    a2.send({
      type: "hello",
      from: "node-a",
      payload: { hostname: "alice", cursors: {} },
    });
    await a2.waitFor((f) => f.type === "ack" && f.payload?.ok);
    const push = await a2.waitFor((f) => f.type === "msg/push");
    assert.equal(push.payload.msg.hostname, "carol");
  } finally {
    // 无论断言成败都要关服务/客户端，否则子进程事件循环不退出导致挂死。
    for (const c of clients) c.close();
    if (s2) s2.stop();
    if (s1) s1.stop();
    for (const suffix of ["", "-wal", "-shm"]) {
      fs.rmSync(dbPath + suffix, { force: true });
    }
  }
});

test("转发：forwardedFrom 落库并在实时推送与历史中回传", async () => {
  const { a, b } = await helloPair();
  a.send({
    type: "msg/send",
    from: "node-a",
    to: "node-b",
    payload: {
      clientId: "f1",
      text: "转给你",
      ts: 6000,
      forwardedFrom: "carol",
    },
  });
  await a.waitFor((f) => f.type === "ack" && f.payload?.clientId === "f1");
  const push = await b.waitFor((f) => f.type === "msg/push");
  assert.equal(push.payload.msg.forwardedFrom, "carol");
  assert.equal(push.payload.msg.recalled, false);

  // 历史中也带 forwardedFrom。
  a.send({
    type: "msg/history",
    from: "node-a",
    to: "node-b",
    payload: { beforeSeq: 10, limit: 10 },
  });
  const hist = await a.waitFor((f) => f.type === "msg/history_result");
  const f1 = hist.payload.messages.find((m) => m.clientId === "f1");
  assert.equal(f1.forwardedFrom, "carol");
  a.close();
  b.close();
});

test("撤回：仅本人可撤，收件人收到广播，重连后历史带 recalled", async () => {
  const { a, b } = await helloPair();
  // b 发一条 → a 收到。
  b.send({
    type: "msg/send",
    from: "node-b",
    to: "node-a",
    payload: { clientId: "r1", text: "发错了", ts: 7000 },
  });
  await b.waitFor((f) => f.type === "ack" && f.payload?.clientId === "r1");
  const push = await a.waitFor((f) => f.type === "msg/push");
  const serverId = push.payload.msg.serverId;
  const id = Number(serverId);

  // 非本人（node-a）撤回 → 拒绝。
  a.send({ type: "msg/recall", from: "node-a", payload: { id } });
  const denied = await a.waitFor(
    (f) => f.type === "ack" && f.payload?.id === id && f.payload?.ok === false,
  );
  assert.ok(denied);

  // 本人（node-b）撤回 → ack ok + a 收到 msg/recalled。
  b.send({ type: "msg/recall", from: "node-b", payload: { id } });
  const ok = await b.waitFor(
    (f) => f.type === "ack" && f.payload?.id === id && f.payload?.ok === true,
  );
  assert.ok(ok);
  const recalled = await a.waitFor(
    (f) => f.type === "msg/recalled" && f.payload?.id === id,
  );
  assert.equal(recalled.from, "node-b");

  // 离线补发/历史：recalled=true。
  b.send({
    type: "msg/history",
    from: "node-b",
    to: "node-a",
    payload: { beforeSeq: 100, limit: 10 },
  });
  const hist = await b.waitFor((f) => f.type === "msg/history_result");
  const r1 = hist.payload.messages.find((m) => m.clientId === "r1");
  assert.equal(r1.recalled, true);
  a.close();
  b.close();
});

test("心跳：ping 有 pong 应答，连接保持", async () => {
  const c = new TestClient();
  await c.ready;
  c.send({ type: "hello", from: "node-ping", payload: { hostname: "ping" } });
  await c.waitFor((f) => f.type === "ack" && f.payload?.ok);
  c.send({ type: "ping" });
  const pong = await c.waitFor((f) => f.type === "pong");
  assert.ok(pong);
  // 服务端也会主动 ping，客户端应答后 socket 应存活。
  await new Promise((r) => setTimeout(r, 300));
  assert.equal(c.socket.destroyed, false);
  c.close();
});

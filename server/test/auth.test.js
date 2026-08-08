// 安全修复回归测试（node --test）。
//
// 覆盖两个此前存在的漏洞的修复效果：
//   1. hello 身份伪造 / 会话劫持——非 dev 模式下必须配对码/令牌校验通过。
//   2. conversationsOf 的 SQL LIKE 通配符未转义——伪造 nodeId 为 "%" 时
//      不应越权拉到别人的会话。

"use strict";

const { test, beforeEach, afterEach } = require("node:test");
const assert = require("node:assert/strict");
const net = require("net");

const { Server } = require("../src/server");
const { Store } = require("../src/store");
const { encodeFrame, FrameDecoder } = require("../src/protocol");

const PAIR_SECRET = "test-pair-secret";

let server;
let port;

beforeEach(async () => {
  server = new Server({
    port: 0,
    host: "127.0.0.1",
    dbPath: ":memory:",
    dev: false,
    pairSecret: PAIR_SECRET,
  });
  server.start();
  await new Promise((resolve) => server.netServer.once("listening", resolve));
  port = server.netServer.address().port;
});

afterEach(() => {
  server.stop();
});

class TestClient {
  constructor(portOverride) {
    this.socket = net.connect({ port: portOverride ?? port, host: "127.0.0.1" });
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
    this.closed = new Promise((r) => this.socket.once("close", r));
  }

  send(frame) {
    this.socket.write(encodeFrame(frame));
  }

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

test("非 dev 模式：hello 不带配对码 → 被拒绝", async () => {
  const c = new TestClient();
  await c.ready;
  c.send({ type: "hello", from: "node-x", payload: { hostname: "x" } });
  const ack = await c.waitFor((f) => f.type === "ack");
  assert.equal(ack.payload.ok, false);
  c.close();
});

test("非 dev 模式：配对码正确 → 注册成功并签发长期令牌", async () => {
  const c = new TestClient();
  await c.ready;
  c.send({
    type: "hello",
    from: "node-a",
    payload: { hostname: "alice", pairSecret: PAIR_SECRET },
  });
  const ack = await c.waitFor((f) => f.type === "ack");
  assert.equal(ack.payload.ok, true);
  assert.equal(typeof ack.payload.token, "string");
  assert.ok(ack.payload.token.length > 0);
  c.close();
});

test("配对后用正确令牌重连 → 成功；用错误令牌 → 被拒绝且不会顶替在线连接", async () => {
  // 1) 首次配对拿到令牌。
  const first = new TestClient();
  await first.ready;
  first.send({
    type: "hello",
    from: "node-a",
    payload: { hostname: "alice", pairSecret: PAIR_SECRET },
  });
  const ack1 = await first.waitFor((f) => f.type === "ack");
  const token = ack1.payload.token;
  assert.ok(token);

  // 2) 用正确令牌重连（不带 pairSecret）应当成功。
  const legit = new TestClient();
  await legit.ready;
  legit.send({
    type: "hello",
    from: "node-a",
    payload: { hostname: "alice", token },
  });
  const ack2 = await legit.waitFor((f) => f.type === "ack");
  assert.equal(ack2.payload.ok, true);

  // 3) 攻击者自报同一个 nodeId，但没有正确令牌（也没有/带错误配对码）
  //    —— 修复前这里会直接顶替 legit 连接、接管身份；修复后应当被拒绝。
  const attacker = new TestClient();
  await attacker.ready;
  attacker.send({
    type: "hello",
    from: "node-a",
    payload: { hostname: "attacker", token: "wrong-token" },
  });
  const ackAttack = await attacker.waitFor((f) => f.type === "ack");
  assert.equal(ackAttack.payload.ok, false);

  // legit 连接应当仍然在线、未被顶替。
  await new Promise((r) => setTimeout(r, 50));
  assert.equal(legit.socket.destroyed, false);

  first.close();
  legit.close();
  attacker.close();
});

test("Store.conversationsOf：nodeId 含 % 通配符不应越权匹配到无关会话", () => {
  const store = new Store(":memory:");
  store.append({
    convId: Store.convIdFor("alice", "bob"),
    sender: "alice",
    clientId: "c1",
    text: "hi bob",
    ts: 1,
  });
  store.append({
    convId: Store.convIdFor("carol", "dave"),
    sender: "carol",
    clientId: "c2",
    text: "hi dave",
    ts: 2,
  });

  // 攻击者把自己的 nodeId 伪造成 "%"：修复前会匹配任意 conv_id
  // （因为 LIKE 模式变成了 "%:%"），从而拿到 alice/bob、carol/dave
  // 两个不相关会话；修复后应当一个都匹配不到。
  const leaked = store.conversationsOf("%");
  assert.deepEqual(leaked, []);

  // 正常 nodeId 的查询不受影响。
  const aliceConvs = store.conversationsOf("alice");
  assert.deepEqual(aliceConvs, [Store.convIdFor("alice", "bob")]);

  store.close();
});

// ─── 长度限制 / 限流（dev 模式下也生效，与身份校验无关）──────────────

async function devHelloPair(a, b) {
  a.send({ type: "hello", from: "node-a", payload: { hostname: "alice" } });
  b.send({ type: "hello", from: "node-b", payload: { hostname: "bob" } });
  await Promise.all([
    a.waitFor((f) => f.type === "ack" && f.payload?.ok),
    b.waitFor((f) => f.type === "ack" && f.payload?.ok),
  ]);
}

test("超长消息被拒绝", async () => {
  const devServer = new Server({
    port: 0,
    host: "127.0.0.1",
    dbPath: ":memory:",
    dev: true,
  });
  devServer.start();
  await new Promise((r) => devServer.netServer.once("listening", r));
  const devPort = devServer.netServer.address().port;

  const a = new net.Socket();
  await new Promise((r) => a.connect(devPort, "127.0.0.1", r));
  const decoder = new FrameDecoder();
  const frames = [];
  a.on("data", (chunk) => {
    for (const f of decoder.push(chunk)) frames.push(f);
  });
  a.write(
    encodeFrame({ type: "hello", from: "node-a", payload: { hostname: "a" } }),
  );
  await new Promise((r) => setTimeout(r, 50));

  const tooLong = "x".repeat(8001);
  a.write(
    encodeFrame({
      type: "msg/send",
      from: "node-a",
      to: "node-b",
      payload: { clientId: "c1", text: tooLong, ts: 1 },
    }),
  );
  await new Promise((r) => setTimeout(r, 100));
  const ack = frames.find(
    (f) => f.type === "ack" && f.payload?.clientId === "c1",
  );
  assert.ok(ack, "应当收到 ack");
  assert.equal(ack.payload.ok, false);

  a.destroy();
  devServer.stop();
});

test("超过限流阈值的消息被拒绝", async () => {
  const devServer = new Server({
    port: 0,
    host: "127.0.0.1",
    dbPath: ":memory:",
    dev: true,
  });
  devServer.start();
  await new Promise((r) => devServer.netServer.once("listening", r));
  const devPort = devServer.netServer.address().port;

  const a = new TestClient(devPort);
  const b = new TestClient(devPort);
  await Promise.all([a.ready, b.ready]);
  await devHelloPair(a, b);

  for (let i = 0; i < 25; i++) {
    a.send({
      type: "msg/send",
      from: "node-a",
      to: "node-b",
      payload: { clientId: `c${i}`, text: "hi", ts: i },
    });
  }
  await new Promise((r) => setTimeout(r, 200));
  const acks = a.frames.filter(
    (f) => f.type === "ack" && f.payload?.clientId?.startsWith("c"),
  );
  const rejected = acks.filter((f) => f.payload.ok === false);
  assert.ok(
    rejected.length > 0,
    "超出限流阈值后应当有消息被拒绝（ok:false）",
  );

  a.close();
  b.close();
  devServer.stop();
});

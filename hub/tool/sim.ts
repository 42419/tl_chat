// Two-client simulation over plain TCP (auth off) to validate the hub without
// a real tailnet / tailscaled: registration, 1:1 delivery, offline queueing +
// flush on reconnect, presence broadcast, and group chat routing.
//
// Run: npm run sim

import { randomUUID } from 'node:crypto';
import { unlinkSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { connect, type Socket } from 'node:net';

import { FrameDecoder, encodeFrame, type ChatFrame } from '../src/protocol.js';
import { Hub } from '../src/server.js';

class SimClient {
  readonly nodeId: string;
  readonly hostname: string;
  private readonly socket: Socket;
  private readonly decoder = new FrameDecoder();
  /** Public so test scenarios can assert "no duplicate arrived". */
  inbox: ChatFrame[] = [];
  private waiters: {
    predicate: (f: ChatFrame) => boolean;
    resolve: (f: ChatFrame) => void;
    reject: (e: Error) => void;
  }[] = [];
  private closed = false;

  constructor(port: number, nodeId: string, hostname: string) {
    this.nodeId = nodeId;
    this.hostname = hostname;
    this.socket = connect({ host: '127.0.0.1', port });
    this.socket.on('data', (chunk) => {
      for (const frame of this.decoder.push(chunk)) {
        const hit = this.waiters.findIndex((w) => w.predicate(frame));
        if (hit >= 0) {
          const [w] = this.waiters.splice(hit, 1);
          if (w) w.resolve(frame);
        } else {
          this.inbox.push(frame);
        }
      }
    });
    this.socket.on('error', (err) => {
      for (const w of this.waiters.splice(0)) w.reject(err);
    });
    this.socket.on('close', () => {
      this.closed = true;
      for (const w of this.waiters.splice(0)) w.reject(new Error('socket closed'));
    });
  }

  send(frame: ChatFrame): void {
    this.socket.write(encodeFrame(frame));
  }

  async hello(): Promise<ChatFrame> {
    this.send({
      type: 'hello',
      from: this.nodeId,
      payload: { hostname: this.hostname },
    });
    return this.waitFor((f) => f.type === 'ack' && f.payload?.['ok'] === true);
  }

  waitFor(predicate: (f: ChatFrame) => boolean, timeoutMs = 5000): Promise<ChatFrame> {
    const found = this.inbox.find(predicate);
    if (found) return Promise.resolve(found);
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        const i = this.waiters.findIndex((w) => w.resolve === resolve);
        if (i >= 0) this.waiters.splice(i, 1);
        reject(new Error('timeout waiting for frame'));
      }, timeoutMs);
      this.waiters.push({
        predicate,
        resolve: (f) => {
          clearTimeout(timer);
          resolve(f);
        },
        reject: (e) => {
          clearTimeout(timer);
          reject(e);
        },
      });
    });
  }

  close(): void {
    if (!this.closed) this.socket.end();
  }
}

function assert(cond: boolean, label: string): void {
  if (!cond) throw new Error(`FAIL: ${label}`);
  console.log(`  ✓ ${label}`);
}

function sleep(ms: number): Promise<void> {
  return new Promise((r) => setTimeout(r, ms));
}

async function main(): Promise<void> {
  const dbPath = join(tmpdir(), `hub-sim-${randomUUID()}.db`);
  const hub = new Hub({ host: '127.0.0.1', port: 0, dbPath, auth: false });
  await hub.start();
  const port = hub.port;

  try {
    console.log('=== sim: two clients over plain TCP (auth off) ===');

    const a = new SimClient(port, 'node-a', 'alice-phone');
    const b = new SimClient(port, 'node-b', 'bob-pc');
    await a.hello();
    await b.hello();
    console.log('  ✓ both registered (hello -> ack ok)');

    // 1:1 online delivery
    a.send({
      type: 'msg',
      from: 'node-a',
      to: 'node-b',
      ts: Date.now(),
      payload: { text: '你好，Bob' },
    });
    const recv = await b.waitFor((f) => f.type === 'msg' && f.from === 'node-a');
    assert(recv.payload?.['text'] === '你好，Bob', 'B received A direct message');
    await a.waitFor((f) => f.type === 'ack' && f.payload?.['ok'] === true);
    console.log('  ✓ direct delivery acked');

    // offline queue: B disconnects, A sends, hub stores
    b.close();
    await sleep(150); // let the hub notice the disconnect
    a.send({
      type: 'msg',
      from: 'node-a',
      to: 'node-b',
      ts: Date.now(),
      payload: { text: '离线消息' },
    });
    await a.waitFor((f) => f.type === 'ack' && f.payload?.['ok'] === true);

    // B reconnects -> hub flushes queued message
    const b2 = new SimClient(port, 'node-b', 'bob-pc');
    await b2.hello();
    const flushed = await b2.waitFor(
      (f) => f.type === 'msg' && f.payload?.['queued'] === true,
    );
    assert(flushed.payload?.['text'] === '离线消息', 'B got queued msg after reconnect');
    console.log('  ✓ offline queue flushed on reconnect');

    // presence: hub now sends [{ id, hostname }] so clients can show names
    const presence = await b2.waitFor((f) => f.type === 'presence');
    const online =
      (presence.payload?.['online'] as { id: string; hostname: string }[] | undefined) ?? [];
    const ids = online.map((n) => n.id);
    assert(ids.includes('node-a') && ids.includes('node-b'), 'presence lists both');
    assert(
      online.some((n) => n.id === 'node-b' && n.hostname === 'bob-pc'),
      'presence carries hostnames',
    );

    // group chat: create -> join -> room/msg
    a.send({ type: 'room/create', from: 'node-a', payload: { name: '家庭群' } });
    const created = await a.waitFor(
      (f) => f.type === 'ack' && f.payload?.['ok'] === true && f.payload?.['roomId'] !== undefined,
    );
    const roomId = created.payload?.['roomId'] as string;
    b2.send({ type: 'room/join', from: 'node-b', roomId });
    await b2.waitFor(
      (f) =>
        f.type === 'ack' &&
        f.payload?.['ok'] === true &&
        f.payload?.['roomId'] === roomId,
    );
    a.send({ type: 'room/msg', from: 'node-a', roomId, payload: { text: '群消息测试' } });
    const roomMsg = await b2.waitFor(
      (f) => f.type === 'room/msg' && f.roomId === roomId,
    );
    assert(roomMsg.payload?.['text'] === '群消息测试', 'B received room message');
    console.log('  ✓ group chat routed');

    // P3: room/list + room/members — browse & view members
    a.send({ type: 'room/list', from: 'node-a' });
    const roomList = await a.waitFor((f) => f.type === 'room/list');
    const rooms = (roomList.payload?.['rooms'] as {
      id: string;
      name: string;
      memberCount: number;
      isMember: boolean;
    }[] | undefined) ?? [];
    const listed = rooms.find((r) => r.id === roomId);
    assert(listed !== undefined, 'room/list lists created room');
    assert(
      listed?.name === '家庭群' && listed?.memberCount === 2 && listed?.isMember === true,
      'room/list carries name/memberCount/isMember',
    );
    b2.send({ type: 'room/members', from: 'node-b', roomId });
    const membersResp = await b2.waitFor(
      (f) => f.type === 'room/members' && f.roomId === roomId,
    );
    const members = (membersResp.payload?.['members'] as {
      id: string;
      online: boolean;
    }[] | undefined) ?? [];
    const memberIds = members.map((m) => m.id);
    assert(
      memberIds.includes('node-a') && memberIds.includes('node-b'),
      'room/members lists both members',
    );
    assert(
      membersResp.payload?.['name'] === '家庭群',
      'room/members carries room name',
    );
    console.log('  ✓ room/list + room/members');

    // multi-device: node-b opens a SECOND simultaneous session (phone + PC).
    // Both sessions must stay registered and BOTH receive a message.
    const bPhone = new SimClient(port, 'node-b', 'bob-phone');
    await bPhone.hello();
    await b2.waitFor((f) => f.type === 'presence');
    console.log('  ✓ second device of node-b registered (hello -> ack ok)');

    // presence stays deduped: node-b appears once despite two sessions.
    const presence2 = await bPhone.waitFor((f) => f.type === 'presence');
    const online2 =
      (presence2.payload?.['online'] as { id: string; hostname: string }[] | undefined) ?? [];
    const nodeBEntries = online2.filter((n) => n.id === 'node-b');
    assert(nodeBEntries.length === 1, 'presence dedupes a node with two devices');

    // 1:1 delivery reaches EVERY session of the recipient.
    a.send({
      type: 'msg',
      from: 'node-a',
      to: 'node-b',
      ts: Date.now(),
      payload: { text: '多设备同步' },
    });
    const onPc = await b2.waitFor(
      (f) => f.type === 'msg' && f.payload?.['text'] === '多设备同步',
    );
    const onPhone = await bPhone.waitFor(
      (f) => f.type === 'msg' && f.payload?.['text'] === '多设备同步',
    );
    assert(onPc.payload?.['text'] === '多设备同步', 'PC session got the message');
    assert(onPhone.payload?.['text'] === '多设备同步', 'phone session got the message');
    assert(
      onPc.payload?.['id'] !== undefined && onPc.payload?.['id'] === onPhone.payload?.['id'],
      'both sessions see the same hub id (client dedup key)',
    );
    console.log('  ✓ 1:1 message pushed to every session of the recipient');

    // The SENDER's own other session also sees the message live.
    // node-a: a (sending) + a2 (second device).
    const a2 = new SimClient(port, 'node-a', 'alice-pc');
    await a2.hello();
    a.send({
      type: 'msg',
      from: 'node-a',
      to: 'node-b',
      ts: Date.now(),
      payload: { text: '自己多端' },
    });
    const onA2 = await a2.waitFor(
      (f) => f.type === 'msg' && f.payload?.['text'] === '自己多端',
    );
    assert(onA2.payload?.['text'] === '自己多端', "sender's other device got its own message live");
    console.log('  ✓ sender\'s other device received the message in real-time');

    // Phase 1.2: per-conversation seq + incremental sync. Fresh pair with no
    // room membership so the increment only contains their 1:1 thread.
    const c = new SimClient(port, 'node-c', 'carol-pc');
    const d = new SimClient(port, 'node-d', 'dave-phone');
    await c.hello();
    await d.hello();
    for (const text of ['s1', 's2', 's3']) {
      c.send({ type: 'msg', from: 'node-c', to: 'node-d', ts: Date.now(), payload: { text } });
      await c.waitFor((f) => f.type === 'ack' && f.payload?.['ok'] === true);
    }
    const d1 = await d.waitFor((f) => f.type === 'msg' && f.payload?.['text'] === 's1');
    const d3 = await d.waitFor((f) => f.type === 'msg' && f.payload?.['text'] === 's3');
    const cursor = d3.payload?.['seq'] as number;
    assert(
      d1.payload?.['seq'] === 1 && cursor === 3,
      '1:1 messages carry a monotonic per-conversation seq',
    );

    // At the current cursor there is nothing newer -> empty increment.
    d.send({ type: 'offline', from: 'node-d', payload: { limit: 200, after: { 'node-c': cursor } } });
    const inc1 = await d.waitFor((f) => f.type === 'offline');
    const inc1msgs = (inc1.payload?.['messages'] as Record<string, unknown>[] | undefined) ?? [];
    assert(inc1msgs.length === 0, `incremental pull at cursor returns nothing (got ${inc1msgs.length})`);

    // One new message -> increment returns exactly it, with seq = cursor + 1.
    c.send({ type: 'msg', from: 'node-c', to: 'node-d', ts: Date.now(), payload: { text: 's4' } });
    await c.waitFor((f) => f.type === 'ack' && f.payload?.['ok'] === true);
    d.send({ type: 'offline', from: 'node-d', payload: { limit: 200, after: { 'node-c': cursor } } });
    const inc2 = await d.waitFor((f) => f.type === 'offline');
    const inc2msgs = (inc2.payload?.['messages'] as Record<string, unknown>[] | undefined) ?? [];
    const inc2text = (inc2msgs[0]?.payload as Record<string, unknown> | undefined)?.['text'];
    assert(
      inc2msgs.length === 1 && inc2text === 's4' && inc2msgs[0]?.['seq'] === cursor + 1,
      'incremental returns exactly the one newer message',
    );
    console.log('  ✓ incremental sync (after=seq) returns only newer messages');

    // Phase 1.3: clientMessageId ack echo + resend idempotency. The hub must
    // (1) echo clientMessageId back in its ack so the client can match the
    // ack to the exact message (not a ts-based broadcast), and (2) dedup a
    // resend with the same (sender, clientMessageId) — returning the original
    // id/seq and NOT re-inserting or re-fan-out, so the recipient never sees
    // a duplicate.
    const e = new SimClient(port, 'node-e', 'erin-pc');
    const f = new SimClient(port, 'node-f', 'frank-pc');
    await e.hello();
    await f.hello();
    const cmid = 'c-test-1735'; // deterministic for the assertion below
    e.send({
      type: 'msg',
      from: 'node-e',
      to: 'node-f',
      ts: 1735000000000,
      payload: { text: 'idempotency-1', clientMessageId: cmid },
    });
    const ack1 = await e.waitFor(
      (fr) => fr.type === 'ack' && fr.payload?.['ok'] === true && fr.payload?.['clientMessageId'] === cmid,
    );
    const firstId = ack1.payload?.['id'];
    const firstSeq = ack1.payload?.['seq'];
    assert(
      typeof firstId === 'number' && typeof firstSeq === 'number',
      'ack echoes clientMessageId + id + seq',
    );
    const recv1 = await f.waitFor(
      (fr) => fr.type === 'msg' && fr.payload?.['text'] === 'idempotency-1',
    );
    assert(recv1.payload?.['id'] === firstId, 'recipient got the message with matching id');
    console.log('  ✓ ack echoes clientMessageId for precise matching');

    // Resend the same (sender, clientMessageId): hub must return deduped:true
    // with the ORIGINAL id/seq, and must NOT re-deliver to the recipient.
    e.send({
      type: 'msg',
      from: 'node-e',
      to: 'node-f',
      ts: 1735000000000,
      payload: { text: 'idempotency-1', clientMessageId: cmid },
    });
    const ack2 = await e.waitFor(
      (fr) =>
        fr.type === 'ack' &&
        fr.payload?.['ok'] === true &&
        fr.payload?.['clientMessageId'] === cmid,
    );
    assert(ack2.payload?.['deduped'] === true, 'resend is marked deduped');
    assert(
      ack2.payload?.['id'] === firstId && ack2.payload?.['seq'] === firstSeq,
      'resend returns the original id/seq (no duplicate insert)',
    );
    // Give the hub a moment — if it had fanned-out, f would receive a second
    // copy. Wait briefly and assert the inbox has no new idempotency-1 msg.
    await sleep(150);
    const dupCount = f.inbox.filter(
      (fr) => fr.type === 'msg' && fr.payload?.['text'] === 'idempotency-1',
    ).length;
    assert(dupCount === 1, `resend did NOT re-deliver to recipient (got ${dupCount})`);
    console.log('  ✓ resend with same clientMessageId is deduped (no duplicate)');

    // A DIFFERENT clientMessageId must be treated as a brand-new message.
    e.send({
      type: 'msg',
      from: 'node-e',
      to: 'node-f',
      ts: 1735000000001,
      payload: { text: 'idempotency-2', clientMessageId: 'c-test-1736' },
    });
    const ack3 = await e.waitFor(
      (fr) =>
        fr.type === 'ack' &&
        fr.payload?.['ok'] === true &&
        fr.payload?.['clientMessageId'] === 'c-test-1736',
    );
    assert(
      ack3.payload?.['id'] !== firstId && ack3.payload?.['deduped'] !== true,
      'different clientMessageId inserts a new message',
    );
    console.log('  ✓ distinct clientMessageId creates a new message');

    // Legacy clients (no clientMessageId) still work — the ack simply omits
    // the field, and the client falls back to ts matching.
    e.send({
      type: 'msg',
      from: 'node-e',
      to: 'node-f',
      ts: 1735000000002,
      payload: { text: 'legacy-no-cmid' },
    });
    const ack4 = await e.waitFor(
      (fr) => fr.type === 'ack' && fr.payload?.['ok'] === true && fr.payload?.['ts'] === 1735000000002,
    );
    assert(
      typeof ack4.payload?.['clientMessageId'] !== 'string',
      'legacy ack has no clientMessageId',
    );
    console.log('  ✓ legacy client (no clientMessageId) still works');

    e.close();
    f.close();
    a.close();
    a2.close();
    b2.close();
    bPhone.close();
    c.close();
    d.close();
    console.log('\nALL SIM CHECKS PASSED ✓');
  } finally {
    await hub.stop();
    try {
      unlinkSync(dbPath);
    } catch {
      /* already gone */
    }
    try {
      unlinkSync(`${dbPath}-wal`);
    } catch {
      /* WAL not created */
    }
    try {
      unlinkSync(`${dbPath}-shm`);
    } catch {
      /* SHM not created */
    }
  }
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});

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
  private inbox: ChatFrame[] = [];
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

    a.close();
    b2.close();
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

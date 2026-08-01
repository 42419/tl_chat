// TL Chat wire protocol — JSON line framing, shared with the Flutter client
// (Dart) and desktop clients. Frame = [4-byte big-endian length][UTF-8 JSON].
//
// Frame shape: { type, from, to, roomId, ts, payload }
//   type: hello | ping | pong | bye | msg | offline | read | ack |
//         room/create | room/join | room/leave | room/msg | presence

export interface ChatFrame {
  type: string;
  from?: string;
  to?: string;
  roomId?: string;
  ts?: number;
  payload?: Record<string, unknown>;
}

export const MAX_FRAME_BYTES = 4 * 1024 * 1024; // 4 MiB guard against abuse

/** Encodes one frame into a length-prefixed buffer. */
export function encodeFrame(frame: ChatFrame): Buffer {
  const body = Buffer.from(JSON.stringify(frame), 'utf8');
  if (body.length > MAX_FRAME_BYTES) {
    throw new Error(`frame too large: ${body.length} bytes`);
  }
  const header = Buffer.allocUnsafe(4);
  header.writeUInt32BE(body.length, 0);
  return Buffer.concat([header, body]);
}

/** Accumulates raw socket chunks and emits complete frames (handles split packets). */
export class FrameDecoder {
  // Explicit `Buffer` (ArrayBufferLike) so chunk/Buffer.concat results assign.
  private buf: Buffer = Buffer.alloc(0);

  /** Feed a chunk; returns all complete frames it contains. Throws on malformed input. */
  push(chunk: Buffer): ChatFrame[] {
    this.buf = this.buf.length === 0 ? chunk : Buffer.concat([this.buf, chunk]);
    const frames: ChatFrame[] = [];
    while (this.buf.length >= 4) {
      const len = this.buf.readUInt32BE(0);
      if (len > MAX_FRAME_BYTES) {
        throw new Error(`frame too large: ${len} bytes`);
      }
      if (this.buf.length < 4 + len) break; // incomplete frame, wait for more data
      const body = this.buf.subarray(4, 4 + len);
      frames.push(JSON.parse(body.toString('utf8')) as ChatFrame);
      // Copy the leftover instead of keeping a view into the original chunk's
      // (potentially large) backing buffer, so it can be GC'd.
      this.buf = Buffer.from(this.buf.subarray(4 + len));
    }
    return frames;
  }
}

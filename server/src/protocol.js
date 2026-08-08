// 线协议帧编解码（服务端）。
//
// 与客户端 lib/core/network/frame_codec.dart 保持同一规范：
//   帧 = [4 字节大端长度][UTF-8 JSON]
//   帧结构：{ type, from?, to?, conv?, ts?, payload? }
// 详见 PROTOCOL.md。

'use strict';

const MAX_FRAME_BYTES = 4 * 1024 * 1024;

/** 编码一帧为长度前缀 Buffer。 */
function encodeFrame(frame) {
  const body = Buffer.from(JSON.stringify(frame), 'utf8');
  if (body.length > MAX_FRAME_BYTES) {
    throw new Error(`frame too large: ${body.length} bytes`);
  }
  const header = Buffer.allocUnsafe(4);
  header.writeUInt32BE(body.length, 0);
  return Buffer.concat([header, body]);
}

/** 累积块并吐出完整帧（处理粘包/半包）。 */
class FrameDecoder {
  constructor() {
    this.buf = Buffer.alloc(0);
  }

  push(chunk) {
    this.buf = this.buf.length === 0 ? chunk : Buffer.concat([this.buf, chunk]);
    const frames = [];
    while (this.buf.length >= 4) {
      const len = this.buf.readUInt32BE(0);
      if (len > MAX_FRAME_BYTES) {
        throw new Error(`frame too large: ${len} bytes`);
      }
      if (this.buf.length < 4 + len) break;
      const body = this.buf.subarray(4, 4 + len);
      frames.push(JSON.parse(body.toString('utf8')));
      this.buf = Buffer.from(this.buf.subarray(4 + len));
    }
    return frames;
  }
}

module.exports = { encodeFrame, FrameDecoder, MAX_FRAME_BYTES };

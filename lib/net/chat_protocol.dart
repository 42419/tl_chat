// TL Chat wire protocol — JSON line framing, mirrors tl_chat/hub/src/protocol.ts.
// Frame = [4-byte big-endian length][UTF-8 JSON].
//
// Frame shape: { type, from, to, roomId, ts, payload }
//   type: hello | ping | pong | bye | msg | offline | read | ack |
//         room/create | room/join | room/leave | room/msg | presence

import 'dart:convert';
import 'dart:typed_data';

/// One wire frame. [payload] is a free-form map (text, metadata, etc.).
class ChatFrame {
  const ChatFrame({
    required this.type,
    this.from,
    this.to,
    this.roomId,
    this.ts,
    this.payload,
  });

  final String type;
  final String? from;
  final String? to;
  final String? roomId;
  final int? ts;
  final Map<String, dynamic>? payload;

  Map<String, dynamic> toJson() => {
    'type': type,
    if (from != null) 'from': from,
    if (to != null) 'to': to,
    if (roomId != null) 'roomId': roomId,
    if (ts != null) 'ts': ts,
    if (payload != null) 'payload': payload,
  };

  factory ChatFrame.fromJson(Map<String, dynamic> json) => ChatFrame(
    type: json['type'] as String,
    from: json['from'] as String?,
    to: json['to'] as String?,
    roomId: json['roomId'] as String?,
    ts: json['ts'] as int?,
    payload: (json['payload'] as Map<String, dynamic>?)?.cast<String, dynamic>(),
  );
}

const int maxFrameBytes = 4 * 1024 * 1024; // must match hub MAX_FRAME_BYTES

/// Encodes one frame into a length-prefixed byte buffer.
Uint8List encodeFrame(ChatFrame frame) {
  final body = utf8.encode(jsonEncode(frame.toJson()));
  if (body.length > maxFrameBytes) {
    throw ArgumentError.value(body.length, 'frame', 'frame too large');
  }
  final out = Uint8List(4 + body.length);
  final len = ByteData.sublistView(out, 0, 4);
  len.setUint32(0, body.length, Endian.big);
  out.setRange(4, out.length, body);
  return out;
}

/// Accumulates raw socket chunks and emits complete frames (handles split packets).
class FrameDecoder {
  final BytesBuilder _pending = BytesBuilder(copy: false);

  /// Feeds a chunk; returns complete frames. Throws [FormatException] on
  /// malformed input (oversized or invalid JSON).
  List<ChatFrame> push(List<int> chunk) {
    _pending.add(chunk);
    final bytes = _pending.takeBytes();
    final frames = <ChatFrame>[];

    var offset = 0;
    while (bytes.length - offset >= 4) {
      final len = ByteData.sublistView(bytes, offset, offset + 4).getUint32(
        0,
        Endian.big,
      );
      if (len > maxFrameBytes) {
        throw const FormatException('frame too large');
      }
      if (bytes.length - offset < 4 + len) break; // incomplete, wait for more
      final body = utf8.decode(bytes.sublist(offset + 4, offset + 4 + len));
      frames.add(
        ChatFrame.fromJson(jsonDecode(body) as Map<String, dynamic>),
      );
      offset += 4 + len;
    }

    // Keep any partial trailing frame for the next push.
    if (offset < bytes.length) {
      _pending.add(bytes.sublist(offset));
    }
    return frames;
  }
}

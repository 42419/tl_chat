/// 线协议帧编解码。
///
/// 帧格式：[4 字节大端长度][UTF-8 JSON]，与服务端 server/src/protocol.js
/// 保持一致（同一份规范，两端各自实现）。
///
/// 帧结构：{ type, from?, to?, conv?, ts?, payload? }
///   type: hello | ack | ping | pong | bye | msg/send | msg/push |
///         msg/history | msg/history_result | read | typing | presence
library;

import 'dart:convert';
import 'dart:typed_data';

/// 一帧消息。[payload] 为自由格式 map。
class ChatFrame {
  const ChatFrame({
    required this.type,
    this.from,
    this.to,
    this.conv,
    this.ts,
    this.payload,
  });

  final String type;
  final String? from;
  final String? to;

  /// 会话 ID（1:1 为双方 nodeId 排序拼接）。可空。
  final String? conv;
  final int? ts;
  final Map<String, dynamic>? payload;

  Map<String, dynamic> toJson() => {
    'type': type,
    if (from != null) 'from': from,
    if (to != null) 'to': to,
    if (conv != null) 'conv': conv,
    if (ts != null) 'ts': ts,
    if (payload != null) 'payload': payload,
  };

  factory ChatFrame.fromJson(Map<String, dynamic> json) => ChatFrame(
    type: json['type'] as String,
    from: json['from'] as String?,
    to: json['to'] as String?,
    conv: json['conv'] as String?,
    ts: json['ts'] as int?,
    payload: (json['payload'] as Map<String, dynamic>?)?.cast<String, dynamic>(),
  );
}

/// 帧大小上限（与服务端一致），防止恶意超大帧。
const int maxFrameBytes = 4 * 1024 * 1024;

/// 编码一帧为长度前缀字节流。
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

/// 累积字节块并吐完整帧（处理分包/粘包）。
class FrameDecoder {
  final BytesBuilder _pending = BytesBuilder(copy: false);

  /// 喂入一块数据，返回其中完整的帧。畸形输入抛 [FormatException]。
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
      if (bytes.length - offset < 4 + len) break;
      final body = utf8.decode(bytes.sublist(offset + 4, offset + 4 + len));
      frames.add(
        ChatFrame.fromJson(jsonDecode(body) as Map<String, dynamic>),
      );
      offset += 4 + len;
    }
    if (offset < bytes.length) {
      _pending.add(bytes.sublist(offset));
    }
    return frames;
  }
}

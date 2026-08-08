/// 核心数据模型：用户、消息、会话、连接状态。
///
/// 模型同时服务 UI 与本地 sqflite 存储，字段与数据库表一一对应。
library;

/// 消息发送状态机：sending → sent → delivered → read；失败可重发。
enum MessageStatus {
  sending,
  sent,
  delivered,
  read,
  failed;

  static MessageStatus parse(String? s) => MessageStatus.values.firstWhere(
    (v) => v.name == s,
    orElse: () => MessageStatus.sent,
  );
}

/// 连接状态（供 UI 展示连接横幅 / 重连提示）。
enum ConnectionStatus {
  disconnected,
  connecting,
  connected,
  reconnecting,
  failed;

  bool get isConnected => this == ConnectionStatus.connected;

  bool get isActive =>
      this == ConnectionStatus.connecting || this == ConnectionStatus.connected;
}

/// 一条聊天消息。
class ChatMessage {
  const ChatMessage({
    required this.clientId,
    required this.conversationId,
    required this.senderId,
    required this.text,
    required this.createdAt,
    this.serverId,
    this.seq,
    this.status = MessageStatus.sending,
    this.recalled = false,
    this.forwardedFrom,
  });

  /// 客户端生成的幂等 ID（发送前即存在，服务端按 (sender, clientId) 去重）。
  final String clientId;

  /// 会话 ID（1:1 为双方 nodeId 排序拼接；群聊为服务端生成的 id）。
  final String conversationId;

  /// 发送者 nodeId。
  final String senderId;

  final String text;
  final int createdAt;

  /// 服务端分配的消息 ID（ack 后回填）。
  final String? serverId;

  /// 每会话单调递增序号（顺序与增量同步游标）。
  final int? seq;

  final MessageStatus status;

  /// 发送者是否撤回过（历史渲染为系统提示行）。
  final bool recalled;

  /// 转发来源显示名（非本会话发送者时标注 "[转发]" 前缀）。
  final String? forwardedFrom;

  ChatMessage copyWith({
    String? serverId,
    int? seq,
    MessageStatus? status,
    bool? recalled,
    String? forwardedFrom,
  }) => ChatMessage(
    clientId: clientId,
    conversationId: conversationId,
    senderId: senderId,
    text: text,
    createdAt: createdAt,
    serverId: serverId ?? this.serverId,
    seq: seq ?? this.seq,
    status: status ?? this.status,
    recalled: recalled ?? this.recalled,
    forwardedFrom: forwardedFrom ?? this.forwardedFrom,
  );

  Map<String, dynamic> toMap() => {
    'client_id': clientId,
    'server_id': serverId,
    'conv_id': conversationId,
    'sender': senderId,
    'text': text,
    'ts': createdAt,
    'seq': seq,
    'status': status.name,
    'recalled': recalled ? 1 : 0,
    'forwarded_from': forwardedFrom,
  };

  factory ChatMessage.fromMap(Map<String, dynamic> map) => ChatMessage(
    clientId: map['client_id'] as String,
    conversationId: map['conv_id'] as String,
    senderId: map['sender'] as String,
    text: map['text'] as String,
    createdAt: (map['ts'] as num).toInt(),
    serverId: map['server_id'] as String?,
    seq: (map['seq'] as num?)?.toInt(),
    status: MessageStatus.parse(map['status'] as String?),
    recalled: (map['recalled'] as int? ?? 0) == 1,
    forwardedFrom: map['forwarded_from'] as String?,
  );
}

/// 一个会话（1:1 私聊或群聊）。
class Conversation {
  Conversation({
    required this.id,
    required this.title,
    this.isGroup = false,
    this.unread = 0,
    this.lastSeq = 0,
    this.lastMessage,
  });

  final String id;

  /// 会话标题（随 presence / 消息发送者实时刷新）。
  String title;

  final bool isGroup;

  /// 内存中的消息列表（旧→新）。本地 DB 是持久化副本。
  final List<ChatMessage> messages = [];

  /// 未读计数（会话未打开时递增）。
  int unread;

  /// 本会话已见到的最大 seq（增量同步游标）。
  int lastSeq;

  /// 会话摘要（列表预览）。
  ChatMessage? lastMessage;

  String get lastPreview => lastMessage?.text ?? '';
  int get lastTs => lastMessage?.createdAt ?? 0;

  Map<String, dynamic> toMap() => {
    'id': id,
    'title': title,
    'is_group': isGroup ? 1 : 0,
    'last_seq': lastSeq,
    'unread': unread,
    'last_ts': lastTs,
    'last_preview': lastPreview,
  };

  factory Conversation.fromMap(Map<String, dynamic> map) => Conversation(
    id: map['id'] as String,
    title: map['title'] as String,
    isGroup: (map['is_group'] as int? ?? 0) == 1,
    unread: (map['unread'] as int? ?? 0),
    lastSeq: (map['last_seq'] as num?)?.toInt() ?? 0,
  );
}

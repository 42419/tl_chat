/// ChatClient — 客户端网络与应用状态核心（Riverpod ChangeNotifier）。
///
/// 职责：
///   - 通过 Tailscale TCP 连接中心服务，心跳保活 + 指数退避重连
///   - hello 注册、消息发送（乐观 UI + 幂等 clientId）、接收、历史分页
///   - 已读回执、打字指示、presence（在线名单）
///   - 与本地 sqflite 双向同步（缓存 + 离线队列）
///
/// 协议：见 lib/core/network/frame_codec.dart 与 server/src/protocol.js。
library;

import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:tailscale/tailscale.dart';

import '../db/chat_db.dart';
import '../models/models.dart';
import 'frame_codec.dart';
import 'tailscale_service.dart';

/// 历史分页结果。
class HistoryPage {
  const HistoryPage({required this.messages, required this.hasMore});

  final List<ChatMessage> messages;
  final bool hasMore;
}

/// 抛给 UI 的连接/协议错误。
class ChatException implements Exception {
  const ChatException(this.message);
  final String message;

  @override
  String toString() => message;
}

class ChatClient extends ChangeNotifier {
  ChatClient({required this.tailscale});

  final TailscaleService tailscale;

  ChatDb? _db;

  // ─── 连接状态 ──────────────────────────────────────────────────────
  TailscaleConnection? _conn;
  StreamSubscription<Uint8List>? _inputSub;
  final FrameDecoder _decoder = FrameDecoder();
  Timer? _heartbeat;
  Timer? _pongTimeout;

  ConnectionStatus _status = ConnectionStatus.disconnected;
  String _statusText = '未连接';
  String? _lastError;
  String? _myNodeId;
  String? _myHostname;

  /// 配对成功后服务端签发的长期身份令牌（首次注册才会下发一次）。
  /// 调用方在 [connect] 成功返回后应检查此字段，非空则写回本地持久化
  /// 的 [AppSettings]，下次连接时通过 [connect] 的 deviceToken 参数带上。
  String? issuedDeviceToken;

  /// nodeId → 显示名（presence / 消息发送者学习；本地持久化，重启恢复）。
  final Map<String, String> _names = {};

  /// 学习并持久化一个节点的显示名，随后刷新受影响会话标题。
  void _learnName(String nodeId, String name) {
    if (name.isEmpty || name == nodeId) return;
    if (_names[nodeId] == name) return;
    _names[nodeId] = name;
    unawaited(_db?.upsertName(nodeId, name));
    _applyNamesToTitles();
  }

  /// 用已学习的名字刷新 1:1 会话标题。
  /// 注意：会话按 convId（"a:b"）索引，不能拿 nodeId 直接查会话表。
  void _applyNamesToTitles() {
    if (_myNodeId == null) return;
    var changed = false;
    for (final conv in _conversations.values) {
      if (conv.isGroup) continue;
      final name = _names[_peerOf(conv.id)];
      if (name != null && name.isNotEmpty && conv.title != name) {
        conv.title = name;
        changed = true;
      }
    }
    if (changed) notifyListeners();
  }

  /// 在线节点 id 集合。
  final Set<String> _onlineNodes = {};

  final Map<String, Conversation> _conversations = {};

  /// 当前打开的会话（UI 设置，用于未读计数与自动已读）。
  String? activeConversationId;

  /// 入站新消息流（非本人消息），供通知/角标等 UI 外部消费。
  final StreamController<ChatMessage> _incoming =
      StreamController<ChatMessage>.broadcast();
  Stream<ChatMessage> get incomingMessages => _incoming.stream;

  // ─── 自动重连 ──────────────────────────────────────────────────────
  String? _hubHost;
  int? _hubPort;
  Timer? _reconnectTimer;
  int _reconnectAttempt = 0;
  bool _autoReconnect = false;
  static const _maxReconnectSeconds = 30;

  // ─── 发送状态机 ────────────────────────────────────────────────────
  final Map<String, _PendingSend> _pending = {};
  static const _ackTimeout = Duration(seconds: 15);

  Completer<void>? _helloAck;

  // ─── 历史分页 ──────────────────────────────────────────────────────
  Completer<HistoryPage>? _historyCompleter;
  String? _historyConvId;
  final Set<String> _noMoreHistory = {};

  // ─── 打字指示（入站）───────────────────────────────────────────────
  final Map<String, Set<String>> _typingSenders = {};
  final Map<String, Map<String, Timer>> _typingTtls = {};
  static const _typingTtl = Duration(seconds: 5);

  // ─── 对外暴露 ──────────────────────────────────────────────────────
  ConnectionStatus get status => _status;
  String get statusText => _statusText;
  String? get lastError => _lastError;
  String? get myNodeId => _myNodeId;
  String? get myHostname => _myHostname;
  List<String> get onlineNodes => List.unmodifiable(_onlineNodes);
  Iterable<Conversation> get conversations => _conversations.values;

  String displayName(String nodeId) => _names[nodeId] ?? nodeId;

  Conversation? conversationById(String id) => _conversations[id];

  /// 当前用户视角下消息是否为“我发的”。
  bool isMine(ChatMessage msg) => msg.senderId == _myNodeId;

  /// 供 UI 构建“发起聊天 / 转发目标”候选列表：在线节点 + 最近聊过的人。
  List<({String id, String name, bool online})> contactCandidates() {
    final out = <({String id, String name, bool online})>{};
    for (final id in _onlineNodes) {
      out.add((id: id, name: displayName(id), online: true));
    }
    if (_myNodeId != null) {
      for (final conv in _conversations.values) {
        if (conv.isGroup) continue;
        final peer = _peerOf(conv.id);
        if (peer.isEmpty || peer == _myNodeId) continue;
        out.add((id: peer, name: displayName(peer), online: false));
      }
    }
    return out.toList();
  }

  /// 转发一条消息到 [targetId]（复用发送链路，附上原发送者显示名）。
  void forwardMessage(String targetId, ChatMessage msg) {
    if (msg.recalled || msg.text.isEmpty) return;
    final originalSender = msg.senderId == _myNodeId
        ? null
        : displayName(msg.senderId);
    sendText(targetId, msg.text, forwardedFrom: originalSender);
  }

  /// 撤回自己发过的一条消息（按服务端 serverId）。
  void recallMessage(String serverId) {
    if (_status != ConnectionStatus.connected || _myNodeId == null) return;
    final id = int.tryParse(serverId);
    if (id == null) return;
    _sendFrame(
      ChatFrame(type: 'msg/recall', from: _myNodeId, payload: {'id': id}),
    );
  }

  /// 从本机删除一条消息（仅本地，不影响服务端记录）。
  void deleteMessageLocally(String convId, String clientId) {
    final conv = _conversations[convId];
    if (conv == null) return;
    conv.messages.removeWhere((m) => m.clientId == clientId);
    conv.lastMessage = conv.messages.isEmpty ? null : conv.messages.last;
    unawaited(_db?.deleteMessage(clientId));
    _persistConversation(conv);
    notifyListeners();
  }

  /// 清空本地缓存（会话 + 消息），下次连接从服务端重新同步。
  Future<void> clearLocalCache() async {
    _conversations.clear();
    _noMoreHistory.clear();
    notifyListeners();
    await _db?.clearAll();
  }

  /// 将 [convId] 标记为已读并清零未读计数。
  void markRead(String convId) {
    final conv = _conversations[convId];
    if (conv == null || conv.unread == 0) return;
    conv.unread = 0;
    unawaited(_db?.clearUnread(convId));
    notifyListeners();
  }

  /// 与 [peerId] 的 1:1 会话 id（双方各自计算一致）。
  String convIdForPeer(String peerId) => _convIdFor(_myNodeId ?? '', peerId);

  /// 从 1:1 会话 id（"a:b"）解析出对方 nodeId；输入本身不是会话 id 则原样返回。
  /// 防御用途：历史上出现过把会话 id 当 peer 递归拼接成 "a:a:b" 的脏数据，
  /// 这里把任意层嵌套归一化回真正的对方节点。
  String peerOfConvId(String id) {
    if (_myNodeId == null || !id.contains(':')) return id;
    return _peerOf(id);
  }

  /// 获取（不存在则创建）与 [peerId] 的会话。
  Conversation conversationWith(String peerId) {
    final nodeId = _myNodeId;
    if (nodeId == null) {
      throw const ChatException('未连接');
    }
    // 防御：容忍调用方误传会话 id（如 "a:b"），归一化为真正的对方节点。
    final peer = peerOfConvId(peerId);
    final convId = _convIdFor(nodeId, peer);
    return _conversations.putIfAbsent(
      convId,
      () => Conversation(id: convId, title: displayName(peer)),
    );
  }

  // ─── 初始化：打开本地库并加载缓存 ─────────────────────────────────
  Future<void> init() async {
    try {
      _db = await ChatDb.open();
      // 恢复本地持久化的节点显示名（重启后无需等新消息就能显示正确昵称）。
      try {
        _names.addAll(await _db!.loadNames());
      } catch (_) {
        // 老库迁移失败时忽略，名字会在下次连接时重新学到。
      }
      final convs = await _db!.listConversations();
      for (final conv in convs) {
        // 历史脏数据清理：合法 1:1 会话 id 恰好由两个节点 id 组成。
        // 旧版 bug 会把会话 id 当 peer 递归拼接（"a:a:b"），这里直接丢弃。
        final parts = conv.id.split(':');
        final validId =
            parts.length == 2 && parts[0].isNotEmpty && parts[1].isNotEmpty;
        if (!validId) {
          await _db!.deleteConversation(conv.id);
          continue;
        }
        final messages = await _db!.listMessages(conv.id, limit: 200);
        conv.messages.addAll(messages);
        if (messages.isNotEmpty) conv.lastMessage = messages.last;
        for (final m in messages) {
          final s = m.seq;
          if (s != null && s > conv.lastSeq) conv.lastSeq = s;
        }
        _conversations[conv.id] = conv;
      }
      notifyListeners();
    } catch (_) {
      // 平台目录不可用（如测试）：降级为纯内存运行。
    }
  }

  // ─── 连接管理 ──────────────────────────────────────────────────────

  /// 本次连接使用的配对令牌 / 配对码（供断线重连时复用）。
  String? _deviceToken;
  String? _pairSecret;

  /// 连接中心服务。要求 Tailscale 已 [up]。连接成功后自动进入自动重连模式。
  ///
  /// [deviceToken]：已配对设备本地持久化的长期令牌，用于向服务端证明
  /// 身份（服务端会校验其哈希是否与首次配对时绑定的一致）。
  /// [pairSecret]：仅首次配对（服务端从未见过本机 nodeId）时需要，
  /// 校验通过后服务端会通过 ack 下发一个新的 [issuedDeviceToken]，
  /// 之后应改用 deviceToken 连接。
  Future<void> connect({
    required String hubHost,
    required int hubPort,
    required String hostname,
    String? deviceToken,
    String? pairSecret,
  }) async {
    if (_status == ConnectionStatus.connected) return;
    _hubHost = hubHost;
    _hubPort = hubPort;
    _myHostname = hostname;
    _deviceToken = deviceToken;
    _pairSecret = pairSecret;
    issuedDeviceToken = null;
    _reconnectTimer?.cancel();
    _setStatus(ConnectionStatus.connecting, '连接中…');

    try {
      final conn = await tailscale.dial(
        hubHost,
        hubPort,
        timeout: const Duration(seconds: 15),
      );
      _conn = conn;
      _inputSub = conn.input.listen(
        _onData,
        onError: (Object e) => _fail('连接异常: $e'),
        onDone: _onDisconnected,
        cancelOnError: true,
      );

      // 本地稳定节点 ID（hello 注册身份）。
      final status = await tailscale.status();
      _myNodeId = status.stableNodeId;
      if (_myNodeId == null || _myNodeId!.isEmpty) {
        throw const ChatException('无法获取本机节点 ID（请先上线）');
      }
      // 拿到本机节点 ID 后，用本地已恢复的名字刷新 1:1 会话标题。
      _applyNamesToTitles();

      // hello 注册：携带每会话同步游标，服务端据此增量下发离线消息。
      final waiter = Completer<void>();
      _helloAck = waiter;
      final cursors = <String, int>{
        for (final c in _conversations.values)
          if (c.lastSeq > 0) c.id: c.lastSeq,
      };
      _sendFrame(
        ChatFrame(
          type: 'hello',
          from: _myNodeId,
          payload: {
            'hostname': hostname,
            'cursors': cursors,
            if (_deviceToken != null) 'token': _deviceToken,
            if (_deviceToken == null && _pairSecret != null)
              'pairSecret': _pairSecret,
          },
        ),
      );
      await waiter.future.timeout(
        const Duration(seconds: 20),
        onTimeout: () {
          _helloAck = null;
          throw const ChatException('注册超时：服务端无响应');
        },
      );

      _status = ConnectionStatus.connected;
      _statusText = '已连接';
      _autoReconnect = true;
      _reconnectAttempt = 0;
      _flushPending();
      _startHeartbeat();
      notifyListeners();
    } catch (e) {
      if (e is ChatException) {
        _fail(e.message);
      } else {
        _fail('连接失败: $e');
      }
      rethrow;
    }
  }

  Future<void> disconnect() async {
    _autoReconnect = false;
    _reconnectTimer?.cancel();
    _sendFrame(const ChatFrame(type: 'bye'));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    _teardown();
    _setStatus(ConnectionStatus.disconnected, '未连接');
  }

  void _onData(Uint8List chunk) {
    try {
      for (final frame in _decoder.push(chunk)) {
        _onFrame(frame);
      }
    } on FormatException catch (e) {
      _fail('协议错误: ${e.message}');
    }
  }

  void _onFrame(ChatFrame frame) {
    switch (frame.type) {
      case 'ack':
        _onAck(frame);
        break;
      case 'ping':
        _sendFrame(const ChatFrame(type: 'pong'));
        break;
      case 'pong':
        _pongTimeout?.cancel();
        _pongTimeout = null;
        break;
      case 'msg/push':
        _onPush(frame);
        break;
      case 'msg/history_result':
        _onHistoryResult(frame);
        break;
      case 'msg/recalled':
        _onRecalled(frame);
        break;
      case 'read':
        _onReadReceipt(frame);
        break;
      case 'typing':
        _onTyping(frame);
        break;
      case 'presence':
        _onPresence(frame);
        break;
      case 'bye':
        _onDisconnected();
        break;
      default:
        break;
    }
  }

  void _onAck(ChatFrame frame) {
    final ok = frame.payload?['ok'] == true;

    // hello ack：完成 connect() 等待；服务端同时下发全量已知节点显示名。
    final hello = _helloAck;
    if (hello != null) {
      _helloAck = null;
      if (ok) {
        final names = frame.payload?['names'];
        if (names is Map) {
          names.forEach((k, v) {
            if (k is String && v is String) _learnName(k, v);
          });
        }
        final token = frame.payload?['token'] as String?;
        if (token != null && token.isNotEmpty) {
          // 首次配对签发的长期令牌：记住它，后续自动重连改用它而不是
          // 一次性配对码（配对码可能已被调用方清空）。issuedDeviceToken
          // 供外部持久化到 AppSettings。
          issuedDeviceToken = token;
          _deviceToken = token;
          _pairSecret = null;
        }
        hello.complete();
      } else {
        final error = frame.payload?['error'] ?? 'unknown';
        hello.completeError(ChatException('注册被拒绝: $error'));
        _autoReconnect = false; // 认证失败不自动重连
      }
      return;
    }

    // msg ack：匹配 clientId 回填 serverId/seq 并置为 sent。
    final clientId = frame.payload?['clientId'] as String?;
    if (clientId == null) return;
    final pending = _pending.remove(clientId);
    pending?.timer?.cancel();
    if (!ok) {
      // 服务端拒绝（如校验失败）：标记 failed，用户可长按重发。
      for (final conv in _conversations.values) {
        for (var i = 0; i < conv.messages.length; i++) {
          if (conv.messages[i].clientId != clientId) continue;
          conv.messages[i] = conv.messages[i].copyWith(
            status: MessageStatus.failed,
          );
          break;
        }
      }
      unawaited(_db?.updateMessage(clientId, status: MessageStatus.failed));
      notifyListeners();
      return;
    }
    final serverId = frame.payload?['serverId'] as String?;
    final seq = (frame.payload?['seq'] as num?)?.toInt();
    final convId = frame.payload?['conv'] as String?;

    final conv = convId != null ? _conversations[convId] : null;
    if (conv != null) {
      for (var i = 0; i < conv.messages.length; i++) {
        final m = conv.messages[i];
        if (m.clientId != clientId) continue;
        var updated = m.copyWith(status: MessageStatus.sent);
        if (serverId != null) updated = updated.copyWith(serverId: serverId);
        if (seq != null) updated = updated.copyWith(seq: seq);
        conv.messages[i] = updated;
        if (seq != null && seq > conv.lastSeq) conv.lastSeq = seq;
        break;
      }
      _persistConversation(conv);
      if (serverId != null || seq != null) {
        unawaited(
          _db?.updateMessage(
            clientId,
            serverId: serverId,
            seq: seq,
            status: MessageStatus.sent,
          ),
        );
      }
      notifyListeners();
    }
  }

  // ─── 发送 ──────────────────────────────────────────────────────────

  /// 单条消息文本长度上限（字符数），需与服务端 MAX_TEXT_LENGTH 保持一致；
  /// 提前在本地拦截，避免用户输完一大段文字才被服务端拒绝。
  static const maxTextLength = 8000;

  /// 乐观发送一条文本消息。离线时消息先落本地，重连后自动冲刷。
  /// [forwardedFrom] 非空表示这是转发的消息（标注原发送者显示名）。
  ChatMessage sendText(String to, String text, {String? forwardedFrom}) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      throw const ChatException('空消息');
    }
    if (trimmed.length > maxTextLength) {
      throw const ChatException('消息过长，请分段发送');
    }
    final nodeId = _myNodeId;
    if (nodeId == null) {
      throw const ChatException('未连接');
    }
    // 防御：容忍误传会话 id，归一化为真正的对方节点。
    to = peerOfConvId(to);
    final clientId = _newClientId();
    final convId = _convIdFor(nodeId, to);
    final now = DateTime.now().millisecondsSinceEpoch;
    final msg = ChatMessage(
      clientId: clientId,
      conversationId: convId,
      senderId: nodeId,
      text: trimmed,
      createdAt: now,
      status: MessageStatus.sending,
      forwardedFrom: forwardedFrom,
    );

    final conv = _conversations.putIfAbsent(
      convId,
      () => Conversation(id: convId, title: displayName(to)),
    );
    conv.messages.add(msg);
    conv.lastMessage = msg;
    _persistMessage(msg);
    _persistConversation(conv);
    notifyListeners();

    _trackPending(
      convId: convId,
      to: to,
      clientId: clientId,
      forwardedFrom: forwardedFrom,
      wireSent: _status == ConnectionStatus.connected,
    );
    if (_status == ConnectionStatus.connected) {
      _sendMsg(
        to: to,
        clientId: clientId,
        text: trimmed,
        ts: now,
        forwardedFrom: forwardedFrom,
      );
    }
    return msg;
  }

  void _sendMsg({
    required String to,
    required String clientId,
    required String text,
    required int ts,
    String? forwardedFrom,
  }) {
    _sendFrame(
      ChatFrame(
        type: 'msg/send',
        from: _myNodeId,
        to: to,
        payload: {
          'clientId': clientId,
          'text': text,
          'ts': ts,
          'forwardedFrom': ?forwardedFrom,
        },
      ),
    );
  }

  /// 注册 pending。仅 [wireSent]（已真正写入连接）时武装 15s ack 超时；
  /// 离线入队的消息不带定时器，等重连 [_flushPending] 补发成功后再武装。
  void _trackPending({
    required String convId,
    required String to,
    required String clientId,
    String? forwardedFrom,
    bool wireSent = false,
  }) {
    _pending[clientId]?.timer?.cancel();
    _pending[clientId] = _PendingSend(
      convId: convId,
      to: to,
      clientId: clientId,
      forwardedFrom: forwardedFrom,
      wireSent: wireSent,
      timer: wireSent
          ? Timer(_ackTimeout, () {
              _pending.remove(clientId);
              final conv = _conversations[convId];
              if (conv == null) return;
              for (var i = 0; i < conv.messages.length; i++) {
                final m = conv.messages[i];
                if (m.clientId == clientId) {
                  conv.messages[i] = m.copyWith(status: MessageStatus.failed);
                  break;
                }
              }
              unawaited(
                _db?.updateMessage(clientId, status: MessageStatus.failed),
              );
              notifyListeners();
            })
          : null,
    );
  }

  /// 重发一条失败消息（复用原 clientId，服务端幂等去重）。
  void resend(String clientId) {
    for (final conv in _conversations.values) {
      for (var i = 0; i < conv.messages.length; i++) {
        final m = conv.messages[i];
        if (m.clientId != clientId) continue;
        final updated = m.copyWith(status: MessageStatus.sending);
        conv.messages[i] = updated;
        _trackPending(
          convId: conv.id,
          to: _peerOf(conv.id),
          clientId: clientId,
          forwardedFrom: m.forwardedFrom,
          wireSent: _status == ConnectionStatus.connected,
        );
        if (_status == ConnectionStatus.connected) {
          _sendMsg(
            to: _peerOf(conv.id),
            clientId: clientId,
            text: m.text,
            ts: m.createdAt,
            forwardedFrom: m.forwardedFrom,
          );
        }
        notifyListeners();
        return;
      }
    }
  }

  // ─── 接收 ──────────────────────────────────────────────────────────

  void _onPush(ChatFrame frame) {
    final raw = frame.payload?['msg'];
    if (raw is! Map) return;
    final map = Map<String, dynamic>.from(raw);
    final convId = map['conv'] as String;
    final sender = map['sender'] as String;
    final text = map['text'] as String? ?? '';
    final ts = (map['ts'] as num?)?.toInt() ?? 0;
    final clientId = map['clientId'] as String? ?? 's$ts-$convId';
    final serverId = map['serverId'] as String?;
    final seq = (map['seq'] as num?)?.toInt();
    final isMine = sender == _myNodeId;
    final recalled = map['recalled'] == true;
    final forwardedFrom = map['forwardedFrom'] as String?;

    final hostname = map['hostname'] as String?;
    if (hostname != null && hostname.isNotEmpty) {
      _learnName(sender, hostname);
    }

    final conv = _conversations.putIfAbsent(
      convId,
      () => Conversation(
        id: convId,
        title: isMine ? displayName(_peerOf(convId)) : displayName(sender),
      ),
    );
    if (!conv.isGroup) {
      conv.title = isMine ? displayName(_peerOf(convId)) : displayName(sender);
    }

    // 去重：同一 serverId 或 clientId 已存在则忽略；但离线补发带回的
    // 撤回标记（此前错过了广播）要同步到本地副本。
    final existing = conv.messages.where(
      (m) =>
          (serverId != null && m.serverId == serverId) ||
          m.clientId == clientId,
    );
    if (existing.isNotEmpty) {
      if (recalled) {
        for (final m in existing) {
          if (m.recalled) continue;
          final i = conv.messages.indexOf(m);
          conv.messages[i] = m.copyWith(recalled: true);
          if (conv.lastMessage?.serverId == serverId ||
              conv.lastMessage?.clientId == clientId) {
            conv.lastMessage = conv.messages[i];
          }
          unawaited(_db?.updateMessage(m.clientId, recalled: true));
        }
        _persistConversation(conv);
        notifyListeners();
      }
      return;
    }

    final msg = ChatMessage(
      clientId: clientId,
      conversationId: convId,
      senderId: sender,
      text: text,
      createdAt: ts,
      serverId: serverId,
      seq: seq,
      status: isMine ? MessageStatus.sent : MessageStatus.delivered,
      recalled: recalled,
      forwardedFrom: forwardedFrom,
    );
    conv.messages.add(msg);
    conv.lastMessage = msg;
    if (seq != null && seq > conv.lastSeq) conv.lastSeq = seq;

    if (isMine) {
      // 服务端回推自己的消息（其他设备场景）——不计未读。
    } else if (convId == activeConversationId) {
      conv.unread = 0;
      unawaited(_db?.clearUnread(convId));
      sendReadReceipt(convId);
    } else {
      conv.unread++;
      unawaited(_db?.incrementUnread(convId));
    }

    if (!isMine) _incoming.add(msg);
    _persistMessage(msg);
    _persistConversation(conv);
    notifyListeners();
  }

  /// 拉取一页更早的历史。返回前消息已按序 PREPEND 到会话列表。
  Future<HistoryPage> fetchHistory(
    String convId, {
    required int beforeSeq,
    int limit = 30,
  }) {
    if (_status != ConnectionStatus.connected || _myNodeId == null) {
      return Future.value(const HistoryPage(messages: [], hasMore: false));
    }
    if (_noMoreHistory.contains(convId)) {
      return Future.value(const HistoryPage(messages: [], hasMore: false));
    }
    final completer = Completer<HistoryPage>();
    _historyCompleter = completer;
    _historyConvId = convId;
    _sendFrame(
      ChatFrame(
        type: 'msg/history',
        from: _myNodeId,
        to: _peerOf(convId),
        payload: {'beforeSeq': beforeSeq, 'limit': limit},
      ),
    );
    return completer.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () {
        if (_historyCompleter == completer) {
          _historyCompleter = null;
          _historyConvId = null;
        }
        return const HistoryPage(messages: [], hasMore: false);
      },
    );
  }

  bool hasNoMoreHistory(String convId) => _noMoreHistory.contains(convId);

  void resetHistoryPaging(String convId) {
    _noMoreHistory.remove(convId);
  }

  void _onHistoryResult(ChatFrame frame) {
    final completer = _historyCompleter;
    final convId = _historyConvId;
    _historyCompleter = null;
    _historyConvId = null;

    final hasMore = frame.payload?['hasMore'] == true;
    final raw = (frame.payload?['messages'] as List?) ?? const [];
    final loaded = <ChatMessage>[];
    final conv = convId != null ? _conversations[convId] : null;
    if (conv != null) {
      for (final entry in raw) {
        if (entry is! Map) continue;
        final map = Map<String, dynamic>.from(entry);
        final msg = ChatMessage(
          clientId: (map['clientId'] as String?) ?? 's${map['ts']}-$convId',
          conversationId: convId!,
          senderId: map['sender'] as String? ?? '?',
          text: map['text'] as String? ?? '',
          createdAt: (map['ts'] as num?)?.toInt() ?? 0,
          serverId: map['serverId'] as String?,
          seq: (map['seq'] as num?)?.toInt(),
          status: MessageStatus.sent,
          recalled: map['recalled'] == true,
          forwardedFrom: map['forwardedFrom'] as String?,
        );
        final hostname = map['hostname'] as String?;
        if (hostname != null && hostname.isNotEmpty) {
          _learnName(msg.senderId, hostname);
        }
        // 去重；若历史页带回撤回标记且本地副本未标记，则同步标记。
        final existing = conv.messages.where(
          (m) =>
              (msg.serverId != null && m.serverId == msg.serverId) ||
              m.clientId == msg.clientId,
        );
        if (existing.isNotEmpty) {
          if (msg.recalled) {
            var changed = false;
            for (final m in existing) {
              if (m.recalled) continue;
              final i = conv.messages.indexOf(m);
              conv.messages[i] = m.copyWith(recalled: true);
              unawaited(_db?.updateMessage(m.clientId, recalled: true));
              changed = true;
            }
            if (changed) {
              _persistConversation(conv);
              notifyListeners();
            }
          }
          continue;
        }
        loaded.add(msg);
      }
      if (loaded.isNotEmpty) {
        // 新页是旧→新；PREPEND 时逆序插入。
        for (var i = loaded.length - 1; i >= 0; i--) {
          conv.messages.insert(0, loaded[i]);
        }
        for (final m in loaded) {
          unawaited(_db?.insertMessage(m));
        }
        _persistConversation(conv);
        notifyListeners();
      }
      if (!hasMore) _noMoreHistory.add(convId!);
    }
    if (completer != null && !completer.isCompleted) {
      completer.complete(HistoryPage(messages: loaded, hasMore: hasMore));
    }
  }

  /// msg/recalled：他人（或本机其他会话）撤回了消息——按 serverId 把本地
  /// 消息标记为已撤回，渲染为系统提示行。
  void _onRecalled(ChatFrame frame) {
    final id = frame.payload?['id'];
    if (id == null) return;
    final idStr = '$id';
    for (final conv in _conversations.values) {
      for (var i = 0; i < conv.messages.length; i++) {
        final m = conv.messages[i];
        if (m.serverId != idStr) continue;
        conv.messages[i] = m.copyWith(recalled: true);
        if (conv.lastMessage?.serverId == idStr) {
          conv.lastMessage = conv.messages[i];
        }
        unawaited(_db?.updateMessage(m.clientId, recalled: true));
        _persistConversation(conv);
        notifyListeners();
        return;
      }
    }
  }

  // ─── 已读回执 ──────────────────────────────────────────────────────

  /// 通知对方本会话已读到最新（打开会话 / 收到新消息时调用）。
  void sendReadReceipt(String convId) {
    final conv = _conversations[convId];
    if (conv == null || conv.messages.isEmpty) return;
    if (_status != ConnectionStatus.connected) return;
    final latestTs = conv.messages.last.createdAt;
    _sendFrame(
      ChatFrame(
        type: 'read',
        from: _myNodeId,
        to: _peerOf(convId),
        payload: {'upToTs': latestTs},
      ),
    );
  }

  void _onReadReceipt(ChatFrame frame) {
    final from = frame.from;
    if (from == null || from == _myNodeId) return;
    final upToTs = (frame.payload?['upToTs'] as num?)?.toInt();
    if (upToTs == null) return;
    final convId = _convIdFor(_myNodeId!, from);
    final conv = _conversations[convId];
    if (conv == null) return;
    var changed = false;
    for (var i = 0; i < conv.messages.length; i++) {
      final m = conv.messages[i];
      if (!isMine(m)) continue;
      if (m.createdAt > upToTs) continue;
      if (m.status != MessageStatus.read) {
        conv.messages[i] = m.copyWith(status: MessageStatus.read);
        changed = true;
      }
    }
    if (changed) {
      _persistConversation(conv);
      notifyListeners();
    }
  }

  // ─── 打字指示 ──────────────────────────────────────────────────────

  void sendTyping(String convId, {required bool on}) {
    if (_status != ConnectionStatus.connected) return;
    _sendFrame(
      ChatFrame(
        type: 'typing',
        from: _myNodeId,
        to: _peerOf(convId),
        payload: {'on': on},
      ),
    );
  }

  void _onTyping(ChatFrame frame) {
    final from = frame.from;
    if (from == null || from == _myNodeId) return;
    final convId = _convIdFor(_myNodeId!, from);
    final on = frame.payload?['on'] == true;
    final ttls = _typingTtls.putIfAbsent(convId, () => {});
    if (!on) {
      ttls.remove(from)?.cancel();
      _typingSenders[convId]?.remove(from);
    } else {
      _typingSenders.putIfAbsent(convId, () => {}).add(from);
      ttls[from]?.cancel();
      ttls[from] = Timer(_typingTtl, () {
        ttls.remove(from);
        _typingSenders[convId]?.remove(from);
        notifyListeners();
      });
    }
    notifyListeners();
  }

  bool isTyping(String convId) => _typingSenders[convId]?.isNotEmpty ?? false;

  // ─── 在线名单 ──────────────────────────────────────────────────────

  void _onPresence(ChatFrame frame) {
    final raw = frame.payload?['online'];
    if (raw is! List) return;
    _onlineNodes.clear();
    for (final item in raw) {
      if (item is Map) {
        final id = item['id'] as String?;
        final name = item['name'] as String?;
        if (id == null || id == _myNodeId) continue;
        _onlineNodes.add(id);
        if (name != null && name.isNotEmpty) _learnName(id, name);
      }
    }
    // 刷新 1:1 会话标题（按 peer 反查，覆盖离线也学到的名字）。
    _applyNamesToTitles();
    notifyListeners();
  }

  // ─── 工具 ──────────────────────────────────────────────────────────

  static String _convIdFor(String a, String b) {
    final ids = [a, b]..sort();
    return '${ids[0]}:${ids[1]}';
  }

  /// 从 1:1 会话 id 中解析出对方 nodeId。
  String _peerOf(String convId) {
    final parts = convId.split(':');
    for (final p in parts) {
      if (p != _myNodeId) return p;
    }
    return parts.last;
  }

  static String _newClientId() {
    final rand = Random().nextInt(1 << 32).toRadixString(36);
    return 'c${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}-$rand';
  }

  void _sendFrame(ChatFrame frame) {
    _conn?.output.write(encodeFrame(frame)).catchError((Object e) {
      _fail('发送失败: $e');
    });
  }

  void _persistMessage(ChatMessage msg) {
    unawaited(_db?.insertMessage(msg));
  }

  void _persistConversation(Conversation conv) {
    unawaited(_db?.upsertConversation(conv));
  }

  // ─── 心跳 / 断线 ───────────────────────────────────────────────────

  void _startHeartbeat() {
    _heartbeat?.cancel();
    _heartbeat = Timer.periodic(const Duration(seconds: 30), (_) {
      _sendFrame(const ChatFrame(type: 'ping'));
      _pongTimeout?.cancel();
      _pongTimeout = Timer(const Duration(seconds: 15), () {
        _fail('心跳超时');
      });
    });
  }

  /// 重连成功后把仍处于 sending 状态的消息重新发出（幂等）。
  /// 离线入队的消息此前无 ack 定时器，补发成功后重新武装。
  void _flushPending() {
    for (final p in List<_PendingSend>.of(_pending.values)) {
      final conv = _conversations[p.convId];
      if (conv == null) continue;
      for (final m in conv.messages) {
        if (m.clientId != p.clientId) continue;
        if (m.status != MessageStatus.sending) break;
        _sendMsg(
          to: p.to,
          clientId: p.clientId,
          text: m.text,
          ts: m.createdAt,
          forwardedFrom: m.forwardedFrom,
        );
        if (!p.wireSent) {
          _trackPending(
            convId: p.convId,
            to: p.to,
            clientId: p.clientId,
            forwardedFrom: m.forwardedFrom,
            wireSent: true,
          );
        }
        break;
      }
    }
  }

  void _onDisconnected() {
    _teardown();
    _setStatus(ConnectionStatus.disconnected, '已断开');
    _maybeScheduleReconnect();
  }

  void _fail(String message) {
    _teardown();
    _lastError = message;
    _setStatus(ConnectionStatus.failed, '连接失败');
    _maybeScheduleReconnect();
  }

  void _setStatus(ConnectionStatus s, String text) {
    _status = s;
    _statusText = text;
    notifyListeners();
  }

  /// 指数退避 + 抖动重连（1s→30s 封顶）。
  void _maybeScheduleReconnect() {
    if (!_autoReconnect || _status == ConnectionStatus.connected) return;
    _reconnectTimer?.cancel();
    _reconnectAttempt++;
    final exp = (_reconnectAttempt - 1).clamp(0, 5);
    final baseMs = min((1 << exp) * 1000, _maxReconnectSeconds * 1000);
    final jitterMs = Random().nextInt(baseMs ~/ 5 + 1);
    _setStatus(ConnectionStatus.reconnecting, '重连中…');
    _reconnectTimer = Timer(Duration(milliseconds: baseMs + jitterMs), () {
      final host = _hubHost;
      final port = _hubPort;
      if (host == null || port == null) return;
      unawaited(
        connect(
          hubHost: host,
          hubPort: port,
          hostname: _myHostname ?? '',
          deviceToken: _deviceToken,
        ).catchError((_) {}),
      );
    });
  }

  void _teardown() {
    _heartbeat?.cancel();
    _heartbeat = null;
    _pongTimeout?.cancel();
    _pongTimeout = null;
    _inputSub?.cancel();
    _inputSub = null;
    _conn?.close();
    _conn = null;
    _helloAck = null;
    _onlineNodes.clear();
    for (final ttls in _typingTtls.values) {
      for (final t in ttls.values) {
        t.cancel();
      }
    }
    _typingTtls.clear();
    _typingSenders.clear();
  }

  @override
  void dispose() {
    _autoReconnect = false;
    _reconnectTimer?.cancel();
    for (final p in _pending.values) {
      p.timer?.cancel();
    }
    _pending.clear();
    _teardown();
    unawaited(_incoming.close());
    super.dispose();
  }
}

class _PendingSend {
  _PendingSend({
    required this.convId,
    required this.to,
    required this.clientId,
    this.forwardedFrom,
    required this.wireSent,
    this.timer,
  });

  final String convId;
  final String to;
  final String clientId;
  final String? forwardedFrom;

  /// 是否已真正写入连接（true = 已武装 ack 超时；false = 离线入队）。
  final bool wireSent;
  final Timer? timer;
}

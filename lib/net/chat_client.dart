// Chat client for the TL Chat hub — manages the tailnet TCP connection,
// hello registration, message send/receive, offline-flush handling, presence
// tracking, heartbeat ping/pong, and local chat-history caching.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:tailscale/tailscale.dart';

import 'chat_cache.dart';
import 'chat_protocol.dart';

enum MessageStatus { sending, sent, delivered, read }

/// A chat message as shown in the UI.
@immutable
class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.from,
    required this.text,
    required this.ts,
    required this.isMine,
    this.roomId,
    this.queued = false,
    this.status = MessageStatus.sent,
    this.hubId,
  });

  final String id;
  final String from;
  final String? roomId;
  final String text;
  final int ts;
  final bool isMine;

  /// True when this message was delivered from the hub's offline queue.
  final bool queued;

  final MessageStatus status;

  /// The hub's SQLite row id (when known) — used to dedup history pulls.
  final String? hubId;

  ChatMessage copyWith({MessageStatus? status}) => ChatMessage(
    id: id,
    from: from,
    roomId: roomId,
    text: text,
    ts: ts,
    isMine: isMine,
    queued: queued,
    status: status ?? this.status,
    hubId: hubId,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'from': from,
    if (roomId != null) 'roomId': roomId,
    'text': text,
    'ts': ts,
    'isMine': isMine,
    'queued': queued,
    'status': status.name,
    if (hubId != null) 'hubId': hubId,
  };

  factory ChatMessage.fromJson(Map<String, dynamic> json) => ChatMessage(
    id: json['id'] as String? ?? '',
    from: json['from'] as String? ?? '?',
    roomId: json['roomId'] as String?,
    text: json['text'] as String? ?? '',
    ts: (json['ts'] as num?)?.toInt() ?? 0,
    isMine: json['isMine'] as bool? ?? false,
    queued: json['queued'] as bool? ?? false,
    status: MessageStatus.values.firstWhere(
      (s) => s.name == json['status'],
      orElse: () => MessageStatus.sent,
    ),
    hubId: json['hubId'] as String?,
  );
}

/// A conversation thread: either 1:1 with a node or a group room.
class Conversation {
  Conversation({required this.id, required this.title, this.isRoom = false});

  final String id;
  String title;
  final bool isRoom;

  final List<ChatMessage> messages = [];
  ChatMessage? lastMessage;

  /// Count of unread incoming messages while this conversation is not open.
  /// Not persisted (transient per-session state).
  int unread = 0;

  String get lastPreview => lastMessage?.text ?? '';
  int get lastTs => lastMessage?.ts ?? 0;

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'isRoom': isRoom,
    'messages': messages.map((m) => m.toJson()).toList(),
  };

  factory Conversation.fromJson(Map<String, dynamic> json) {
    final conv = Conversation(
      id: json['id'] as String,
      title: json['title'] as String? ?? '',
      isRoom: json['isRoom'] as bool? ?? false,
    );
    for (final raw in (json['messages'] as List? ?? const [])) {
      if (raw is! Map) continue;
      final msg = ChatMessage.fromJson(Map<String, dynamic>.from(raw));
      conv.messages.add(msg);
      conv.lastMessage = msg;
    }
    return conv;
  }
}

/// A group room listing entry returned by `room/list` (P3 browse/join).
class RoomSummary {
  const RoomSummary({
    required this.id,
    required this.name,
    required this.memberCount,
    required this.isMember,
  });

  final String id;
  final String name;
  final int memberCount;
  final bool isMember;
}

/// A member of a group room returned by `room/members`.
class RoomMember {
  const RoomMember({required this.id, this.hostname, required this.online});

  final String id;
  final String? hostname;
  final bool online;
}

/// Group room details returned by `room/members`.
class RoomInfo {
  const RoomInfo({required this.roomId, required this.name, required this.members});

  final String roomId;
  final String name;
  final List<RoomMember> members;
}

/// Thrown for protocol/connection errors surfaced to the UI.
class HubException implements Exception {
  const HubException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Modes the app runs in for the connection panel.
enum ConnectionPhase { unconnected, connecting, connected, failed }

class ChatClient extends ChangeNotifier {
  ChatClient({Tailscale? tailscale}) : _tailscale = tailscale ?? Tailscale.instance;

  final Tailscale _tailscale;
  TailscaleConnection? _conn;
  StreamSubscription<Uint8List>? _inputSub;
  final FrameDecoder _decoder = FrameDecoder();
  Timer? _heartbeatTimer;
  Timer? _pongTimeout;

  String? _myNodeId;
  bool _connected = false;
  String? _lastError;
  String _statusText = '未连接';
  String? _hostname;
  ConnectionPhase _phase = ConnectionPhase.unconnected;

  Completer<void>? _helloAckCompleter;
  Completer<String>? _roomCreateCompleter;
  Completer<bool>? _roomJoinCompleter;
  Completer<List<RoomSummary>>? _roomListCompleter;
  Completer<RoomInfo>? _roomMembersCompleter;

  /// nodeId -> hostname map, learned from presence + message senders.
  final Map<String, String> _names = {};
  final List<String> _onlineNodes = [];
  final Map<String, Conversation> _conversations = {};

  /// Conversation currently open in the UI; incoming messages into it do not
  /// bump its unread counter. Set by the chat page, cleared on close.
  String? activeConversationId;

  bool get connected => _connected;

  ConnectionPhase get phase => _phase;

  String get statusText => _statusText;
  String? get lastError => _lastError;
  String? get myNodeId => _myNodeId;
  String? get hostname => _hostname;
  List<String> get onlineNodes => List.unmodifiable(_onlineNodes);

  /// Prefers a known hostname, falls back to the node id.
  String displayName(String nodeId) => _names[nodeId] ?? nodeId;

  Iterable<Conversation> get conversations => _conversations.values;

  Conversation? conversationById(String id) => _conversations[id];

  /// Opens (creating if needed) a 1:1 conversation with [nodeId].
  Conversation openConversation(String nodeId) {
    return _conversations.putIfAbsent(
      nodeId,
      () => Conversation(id: nodeId, title: displayName(nodeId)),
    );
  }

  /// Opens (creating if needed) a room conversation with the given title.
  Conversation ensureRoomConversation(String roomId, String title) {
    return _conversations.putIfAbsent(
      roomId,
      () => Conversation(id: roomId, title: title, isRoom: true),
    );
  }

  /// Marks [conversationId] as read and clears its unread counter.
  void markConversationRead(String conversationId) {
    final conv = _conversations[conversationId];
    if (conv == null || conv.unread == 0) return;
    conv.unread = 0;
    notifyListeners();
  }

  /// Loads locally cached conversations (offline browsing). Only fills gaps —
  /// any conversation already in memory wins (fresh data beats stale cache).
  Future<void> loadLocalCache() async {
    try {
      final cached = await ChatCache.loadAll();
      var added = false;
      for (final entry in cached.entries) {
        if (!_conversations.containsKey(entry.key)) {
          _conversations[entry.key] = entry.value;
          added = true;
        }
      }
      if (added) notifyListeners();
    } catch (_) {
      // best-effort: platform dir unavailable (e.g. tests) — start empty
    }
  }

  /// Clears all locally cached history (user-cleanable). The hub's
  /// authoritative copy is untouched; it is re-fetched on next connect.
  Future<void> clearLocalCache() async {
    _conversations.clear();
    notifyListeners();
    await ChatCache.clear();
  }

  /// Persists a conversation to the local cache (best-effort, fire-and-forget).
  void _persist(Conversation conv) {
    unawaited(ChatCache.save(conv));
  }

  /// Connects to the hub over the tailnet. Requires [Tailscale.init] + [up]
  /// to have been called first so [Tailscale.instance.tcp] is usable.
  Future<void> connect({
    required String hubHost,
    required int hubPort,
    required String hostname,
  }) async {
    if (_connected) return;
    _hostname = hostname;
    _statusText = '连接中…';
    _lastError = null;
    _phase = ConnectionPhase.connecting;
    notifyListeners();

    try {
      final conn = await _tailscale.tcp.dial(
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

      // Resolve the local stable node id for hello registration.
      _myNodeId = (await _tailscale.status()).stableNodeId;
      if (_myNodeId == null || _myNodeId!.isEmpty) {
        throw const HubException('无法获取本机节点 ID（请先 up）');
      }

      // Gate "connected" on the hub's hello ack.
      final helloAck = Completer<void>();
      _helloAckCompleter = helloAck;
      _write(
        ChatFrame(
          type: 'hello',
          from: _myNodeId,
          payload: {'hostname': hostname},
        ),
      );
      // 20s: the hub retries its own whois resolution for ~14s worst case
      // (5× status --json + whois fallback) to let a freshly registered node
      // appear in its netmap; the client must outlast that window.
      await helloAck.future.timeout(
        const Duration(seconds: 20),
        onTimeout: () {
          _helloAckCompleter = null;
          throw const HubException('注册超时：hub 无响应');
        },
      );

      // Pull recent history (the hub replies with an `offline` frame).
      _write(
        ChatFrame(type: 'offline', from: _myNodeId, payload: {'limit': 200}),
      );

      _connected = true;
      _statusText = '已连接';
      _phase = ConnectionPhase.connected;
      _startHeartbeat();
      notifyListeners();
    } catch (e) {
      if (e is HubException) {
        _fail(e.message);
      } else {
        _fail('连接失败: $e');
      }
      rethrow;
    }
  }

  void _onData(Uint8List chunk) {
    try {
      for (final frame in _decoder.push(chunk)) {
        _handleFrame(frame);
      }
    } on FormatException catch (e) {
      _fail('协议错误: ${e.message}');
    }
  }

  void _handleFrame(ChatFrame frame) {
    switch (frame.type) {
      case 'ack':
        _handleAck(frame);
        break;
      case 'ping':
        _write(const ChatFrame(type: 'pong'));
        break;
      case 'pong':
        _pongTimeout?.cancel();
        _pongTimeout = null;
        break;
      case 'msg':
        _onIncomingMessage(frame, roomId: null);
        break;
      case 'room/msg':
        _onIncomingMessage(frame, roomId: frame.roomId);
        break;
      case 'room/list':
        _onRoomList(frame);
        break;
      case 'room/members':
        _onRoomMembers(frame);
        break;
      case 'presence':
        _onPresence(frame);
        break;
      case 'offline':
        _onOfflineHistory(frame);
        break;
      case 'read':
        _onReadReceipt(frame);
        break;
      case 'bye':
        _onDisconnected();
        break;
      default:
        break; // ignore unknown types
    }
  }

  void _handleAck(ChatFrame frame) {
    final ok = frame.payload?['ok'] == true;
    final roomId = frame.payload?['roomId'] as String?;

    // Room acks (create/join/msg) all carry roomId. The `joined` marker
    // distinguishes room/join — and must be handled BEFORE the generic !ok
    // rejection below, otherwise a failed join (ok:false) would be swallowed
    // by the connection-failure path and the joinRoom() waiter would hang.
    if (roomId != null && frame.payload?['joined'] is bool) {
      // room/join ack — surface the result to the joinRoom() waiter.
      final joined = frame.payload?['joined'] == true;
      final waiter = _roomJoinCompleter;
      _roomJoinCompleter = null;
      if (waiter != null && !waiter.isCompleted) {
        if (joined) {
          _conversations.putIfAbsent(
            roomId,
            () => Conversation(
              id: roomId,
              title: (frame.payload?['name'] as String?) ?? roomId,
              isRoom: true,
            ),
          );
          waiter.complete(true);
        } else {
          waiter.completeError(const HubException('群不存在或无法加入'));
        }
      }
      return;
    }

    if (!ok) {
      final error = frame.payload?['error'] ?? 'unknown';
      _statusText = '被拒绝: $error';
      _phase = ConnectionPhase.failed;
      // Complete a pending hello waiter with the real rejection instead of
      // letting connect() hang until its 10s timeout with a misleading error.
      final hello = _helloAckCompleter;
      if (hello != null && !hello.isCompleted) {
        _helloAckCompleter = null;
        hello.completeError(HubException('注册被拒绝: $error'));
      }
      notifyListeners();
      return;
    }

    if (roomId != null) {
      // room/create or room/msg ack (both carry roomId, neither has `joined`).
      final createWaiter = _roomCreateCompleter;
      if (createWaiter != null && !createWaiter.isCompleted) {
        _roomCreateCompleter = null;
        createWaiter.complete(roomId);
      }
      _conversations.putIfAbsent(
        roomId,
        () => Conversation(
          id: roomId,
          title: (frame.payload?['name'] as String?) ?? roomId,
          isRoom: true,
        ),
      );
    } else if (_helloAckCompleter != null && !_helloAckCompleter!.isCompleted) {
      _helloAckCompleter!.complete();
      _helloAckCompleter = null;
    } else {
      // msg ack — mark optimistic messages as sent.
      var changed = false;
      for (final conv in _conversations.values) {
        for (var i = 0; i < conv.messages.length; i++) {
          if (conv.messages[i].status == MessageStatus.sending) {
            conv.messages[i] = conv.messages[i].copyWith(
              status: MessageStatus.sent,
            );
            changed = true;
            _persist(conv);
          }
        }
      }
      if (changed) notifyListeners();
    }
  }

  void _onIncomingMessage(ChatFrame frame, {String? roomId}) {
    final from = frame.from ?? '?';
    final senderHostname = frame.payload?['hostname'] as String?;
    if (senderHostname != null && senderHostname.isNotEmpty) {
      _names[from] = senderHostname;
    }
    final text = (frame.payload?['text'] as String?) ?? '';
    final isQueued = frame.payload?['queued'] == true;
    final rawId = frame.payload?['id'];
    final hubId = rawId is num ? rawId.toString() : rawId as String?;
    final threadId = roomId ?? from;
    final conv = _conversations.putIfAbsent(
      threadId,
      () => Conversation(
        id: threadId,
        title: roomId != null ? threadId : displayName(from),
        isRoom: roomId != null,
      ),
    );
    if (roomId == null) conv.title = displayName(from);
    // Dedup: this message may have already arrived via the history pull.
    if (hubId != null && conv.messages.any((m) => m.hubId == hubId)) {
      return;
    }
    final msg = ChatMessage(
      id: hubId ?? '${frame.ts}-$threadId-${conv.messages.length}',
      from: from,
      roomId: roomId,
      text: text,
      ts: frame.ts ?? DateTime.now().millisecondsSinceEpoch,
      isMine: from == _myNodeId,
      queued: isQueued,
      hubId: hubId,
    );
    conv.messages.add(msg);
    conv.lastMessage = msg;
    if (msg.isMine || threadId == activeConversationId) {
      // Message is in the conversation currently on screen: acknowledge it
      // right away so the sender sees the blue read check while we chat.
      if (!msg.isMine) sendReadReceipt(threadId);
    } else {
      conv.unread++;
    }
    _persist(conv);
    notifyListeners();
  }

  void _onPresence(ChatFrame frame) {
    // Global presence: payload.online = [{ id, hostname }].
    // Room presence:    payload.online = [nodeId...] (kept for P3 room UI).
    final raw = frame.payload?['online'];
    if (frame.roomId != null) return; // room presence handled later
    if (raw is! List) return;
    _onlineNodes.clear();
    for (final item in raw) {
      if (item is String) {
        if (item != _myNodeId) _onlineNodes.add(item);
      } else if (item is Map) {
        final id = item['id'] as String?;
        final hostname = item['hostname'] as String?;
        if (id != null && id != _myNodeId) {
          _onlineNodes.add(id);
          if (hostname != null && hostname.isNotEmpty) _names[id] = hostname;
        }
      }
    }
    // Refresh 1:1 conversation titles now that hostnames are known.
    for (final entry in _names.entries) {
      final conv = _conversations[entry.key];
      if (conv != null && !conv.isRoom) conv.title = entry.value;
    }
    notifyListeners();
  }

  void _onOfflineHistory(ChatFrame frame) {
    // Hub responds to `offline` with stored StoredMessage rows, shaped:
    // { id, roomId, sender, recipient, payload, ts, delivered }.
    final messages = (frame.payload?['messages'] as List?) ?? const [];
    for (final raw in messages) {
      if (raw is! Map) continue;
      final map = Map<String, dynamic>.from(raw);
      final sender = map['sender'] as String?;
      final roomId = map['roomId'] as String?;
      final payload = map['payload'];
      final text = payload is Map ? (payload['text'] as String?) ?? '' : '';
      final ts = (map['ts'] as num?)?.toInt() ?? 0;
      final hubId = '${map['id'] ?? ''}';
      final from = sender ?? '?';
      final threadId = roomId ?? from;
      final conv = _conversations.putIfAbsent(
        threadId,
        () => Conversation(
          id: threadId,
          title: roomId != null ? threadId : displayName(from),
          isRoom: roomId != null,
        ),
      );
      if (roomId == null) conv.title = displayName(from);
      // Dedup against locally-cached/optimistic copies (same hub id, or the
      // same sender+ts+text for a message we sent before its ack arrived).
      if (conv.messages.any(
        (m) =>
            (m.hubId != null && m.hubId == hubId) ||
            (m.from == from && m.ts == ts && m.text == text),
      )) {
        continue;
      }
      final msg = ChatMessage(
        id: hubId.isNotEmpty ? hubId : '$ts-$threadId-${conv.messages.length}',
        from: from,
        roomId: roomId,
        text: text,
        ts: ts,
        isMine: from == _myNodeId,
        queued: map['delivered'] != true,
        hubId: hubId.isEmpty ? null : hubId,
      );
      conv.messages.add(msg);
      conv.lastMessage = msg;
      // History landing in the open conversation is read too.
      if (from != _myNodeId && threadId == activeConversationId) {
        sendReadReceipt(threadId);
      } else if (from != _myNodeId && threadId != activeConversationId) {
        conv.unread++;
      }
      _persist(conv);
    }
    notifyListeners();
  }

  void _onReadReceipt(ChatFrame frame) {
    final from = frame.from;
    if (from == null) return;
    final conv = _conversations[from];
    if (conv == null) return;
    // The peer tells us how far it has read; only flip our outgoing messages
    // at or before that watermark to the blue double-check (read).
    final lastTs = (frame.payload?['lastTs'] as num?)?.toInt();
    var changed = false;
    for (var i = conv.messages.length - 1; i >= 0; i--) {
      final m = conv.messages[i];
      if (!m.isMine) continue;
      if (lastTs != null && m.ts > lastTs) continue;
      if (m.status == MessageStatus.sent ||
          m.status == MessageStatus.delivered) {
        conv.messages[i] = m.copyWith(status: MessageStatus.read);
        changed = true;
        _persist(conv);
      }
    }
    if (changed) notifyListeners();
  }

  void _onDisconnected() {
    _teardown();
    _statusText = '已断开';
    // Keep a registration rejection visible (the hub closes the socket right
    // after a rejection ack); only downgrade on a clean disconnect.
    if (_phase != ConnectionPhase.failed) _phase = ConnectionPhase.unconnected;
    notifyListeners();
  }

  void _fail(String message) {
    _teardown();
    _lastError = message;
    _statusText = '连接失败';
    _phase = ConnectionPhase.failed;
    notifyListeners();
  }

  /// Sends a 1:1 text message. Returns the message for optimistic UI.
  ChatMessage sendMessage(String to, String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty || !_connected) {
      throw const HubException('未连接');
    }
    final ts = DateTime.now().millisecondsSinceEpoch;
    final msg = ChatMessage(
      id: 'local-$ts-${to.hashCode}',
      from: _myNodeId ?? '',
      text: trimmed,
      ts: ts,
      isMine: true,
      status: MessageStatus.sending,
    );
    final conv = _conversations.putIfAbsent(
      to,
      () => Conversation(id: to, title: displayName(to)),
    );
    conv.messages.add(msg);
    conv.lastMessage = msg;
    _persist(conv);
    _write(
      ChatFrame(
        type: 'msg',
        from: _myNodeId,
        to: to,
        ts: ts,
        payload: {'text': trimmed, 'hostname': _hostname ?? ''},
      ),
    );
    notifyListeners();
    return msg;
  }

  /// Creates a group room; the returned future completes with the hub's roomId.
  Future<String> createRoom(String name) {
    if (!_connected) return Future.error(const HubException('未连接'));
    final completer = Completer<String>();
    _roomCreateCompleter = completer;
    _write(
      ChatFrame(
        type: 'room/create',
        from: _myNodeId,
        payload: {'name': name},
      ),
    );
    return completer.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () {
        _roomCreateCompleter = null;
        throw const HubException('创建群聊超时');
      },
    );
  }

  /// Joins an existing room by id; completes with whether the join succeeded.
  Future<bool> joinRoom(String roomId) {
    if (!_connected) return Future.error(const HubException('未连接'));
    final completer = Completer<bool>();
    _roomJoinCompleter = completer;
    _write(ChatFrame(type: 'room/join', from: _myNodeId, roomId: roomId));
    return completer.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () {
        _roomJoinCompleter = null;
        throw const HubException('加入群聊超时');
      },
    );
  }

  /// Fetches the list of existing rooms (P3 browse & join).
  Future<List<RoomSummary>> listRooms() {
    if (!_connected) return Future.error(const HubException('未连接'));
    final completer = Completer<List<RoomSummary>>();
    _roomListCompleter = completer;
    _write(ChatFrame(type: 'room/list', from: _myNodeId));
    return completer.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () {
        _roomListCompleter = null;
        throw const HubException('获取群列表超时');
      },
    );
  }

  /// Fetches a room's name + members with online status (P3 member list).
  Future<RoomInfo> roomMembers(String roomId) {
    if (!_connected) return Future.error(const HubException('未连接'));
    final completer = Completer<RoomInfo>();
    _roomMembersCompleter = completer;
    _write(ChatFrame(type: 'room/members', from: _myNodeId, roomId: roomId));
    return completer.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () {
        _roomMembersCompleter = null;
        throw const HubException('获取群成员超时');
      },
    );
  }

  void sendRoomMessage(String roomId, String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty || !_connected) return;
    final ts = DateTime.now().millisecondsSinceEpoch;
    final msg = ChatMessage(
      id: 'local-$ts-$roomId',
      from: _myNodeId ?? '',
      roomId: roomId,
      text: trimmed,
      ts: ts,
      isMine: true,
      status: MessageStatus.sent,
    );
    final conv = _conversations[roomId];
    if (conv != null) {
      conv.messages.add(msg);
      conv.lastMessage = msg;
      _persist(conv);
    }
    _write(
      ChatFrame(
        type: 'room/msg',
        from: _myNodeId,
        roomId: roomId,
        ts: ts,
        payload: {'text': trimmed, 'hostname': _hostname ?? ''},
      ),
    );
    notifyListeners();
  }

  /// Sends a `read` receipt to [conversationId]'s peer, carrying the ts of the
  /// last incoming message so the peer can mark exactly those as read (blue
  /// double-check). No-op for rooms (read receipts are 1:1 for now), the
  /// self-conversation, or when there is nothing incoming to acknowledge.
  void sendReadReceipt(String conversationId) {
    if (!_connected) return;
    final conv = _conversations[conversationId];
    if (conv == null || conv.isRoom) return;
    if (conversationId == _myNodeId) return;
    int? lastIncomingTs;
    for (final m in conv.messages) {
      if (!m.isMine) lastIncomingTs = m.ts;
    }
    if (lastIncomingTs == null) return;
    _write(
      ChatFrame(
        type: 'read',
        from: _myNodeId,
        to: conversationId,
        ts: DateTime.now().millisecondsSinceEpoch,
        payload: {'lastTs': lastIncomingTs},
      ),
    );
  }

  void _onRoomList(ChatFrame frame) {
    final completer = _roomListCompleter;
    if (completer == null) return;
    _roomListCompleter = null;
    final raw = frame.payload?['rooms'];
    if (raw is! List) {
      if (!completer.isCompleted) {
        completer.completeError(const HubException('群列表数据异常'));
      }
      return;
    }
    final rooms = raw.whereType<Map>().map((m) {
      final map = Map<String, dynamic>.from(m);
      return RoomSummary(
        id: map['id'] as String? ?? '',
        name: map['name'] as String? ?? '',
        memberCount: (map['memberCount'] as num?)?.toInt() ?? 0,
        isMember: map['isMember'] as bool? ?? false,
      );
    }).toList();
    // Refresh room conversation titles when we learn their names.
    for (final r in rooms) {
      final conv = _conversations[r.id];
      if (conv != null && conv.isRoom && conv.title == r.id) conv.title = r.name;
    }
    if (!completer.isCompleted) completer.complete(rooms);
  }

  void _onRoomMembers(ChatFrame frame) {
    final completer = _roomMembersCompleter;
    if (completer == null) return;
    _roomMembersCompleter = null;
    final roomId = frame.roomId ?? '';
    final ok = frame.payload?['ok'] == true;
    if (!ok) {
      final err = (frame.payload?['error'] as String?) ?? '获取群成员失败';
      if (!completer.isCompleted) completer.completeError(HubException(err));
      return;
    }
    final name = (frame.payload?['name'] as String?) ?? roomId;
    final raw = frame.payload?['members'];
    if (raw is! List) {
      if (!completer.isCompleted) {
        completer.completeError(const HubException('群成员数据异常'));
      }
      return;
    }
    final members = raw.whereType<Map>().map((m) {
      final map = Map<String, dynamic>.from(m);
      final id = map['id'] as String? ?? '?';
      final hostname = map['hostname'] as String?;
      if (hostname != null && hostname.isNotEmpty) _names[id] = hostname;
      return RoomMember(
        id: id,
        hostname: hostname,
        online: map['online'] as bool? ?? false,
      );
    }).toList();
    final conv = _conversations[roomId];
    if (conv != null && conv.isRoom) conv.title = name;
    if (!completer.isCompleted) {
      completer.complete(RoomInfo(roomId: roomId, name: name, members: members));
    }
  }

  void _write(ChatFrame frame) {
    _conn?.output.write(encodeFrame(frame)).catchError((Object e) {
      _fail('发送失败: $e');
    });
  }

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      _write(const ChatFrame(type: 'ping'));
      _pongTimeout?.cancel();
      _pongTimeout = Timer(const Duration(seconds: 15), () {
        _fail('心跳超时');
      });
    });
  }

  void _teardown() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _pongTimeout?.cancel();
    _pongTimeout = null;
    _inputSub?.cancel();
    _inputSub = null;
    _conn?.close();
    _conn = null;
    _connected = false;
    _onlineNodes.clear();
  }

  Future<void> disconnect() async {
    _write(const ChatFrame(type: 'bye'));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    _teardown();
    _statusText = '未连接';
    _phase = ConnectionPhase.unconnected;
    notifyListeners();
  }

  @override
  void dispose() {
    _teardown();
    super.dispose();
  }
}

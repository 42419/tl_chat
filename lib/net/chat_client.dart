// Chat client for the TL Chat hub — manages the tailnet TCP connection,
// hello registration, message send/receive, offline-flush handling, presence
// tracking, heartbeat ping/pong, and local chat-history caching.

import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:tailscale/tailscale.dart';

import 'chat_cache.dart';
import 'chat_protocol.dart';
import '../services/notifications.dart';

enum MessageStatus { sending, sent, delivered, read, failed }

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
    this.seq,
    this.clientMessageId,
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

  /// Per-conversation monotonic sequence number from the hub (incremental
  /// sync cursor, Phase 1.2). Unknown until the hub acks an outgoing message.
  final int? seq;

  /// Client-generated idempotency key for outgoing messages (Phase 1.3).
  /// Sent in the wire payload so the hub can dedup a resend (after a 15s ack
  /// timeout) and the ack can be matched back to this exact message instead
  /// of by ts (which is ambiguous when several messages land in the same ms).
  final String? clientMessageId;

  ChatMessage copyWith({
    MessageStatus? status,
    int? seq,
    String? hubId,
  }) => ChatMessage(
    id: id,
    from: from,
    roomId: roomId,
    text: text,
    ts: ts,
    isMine: isMine,
    queued: queued,
    status: status ?? this.status,
    hubId: hubId ?? this.hubId,
    seq: seq ?? this.seq,
    clientMessageId: clientMessageId,
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
    if (seq != null) 'seq': seq,
    if (clientMessageId != null) 'clientMessageId': clientMessageId,
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
    seq: (json['seq'] as num?)?.toInt(),
    clientMessageId: json['clientMessageId'] as String?,
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

  /// Pinned to the top of the conversation list. Persisted locally; the hub
  /// is not involved (it is a per-device preference).
  bool pinned = false;

  /// Highest per-conversation seq seen so far (incremental sync cursor).
  /// Persisted so a reconnect after app restart can resume incrementally.
  int lastSeq = 0;

  String get lastPreview => lastMessage?.text ?? '';
  int get lastTs => lastMessage?.ts ?? 0;

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'isRoom': isRoom,
    'pinned': pinned,
    'lastSeq': lastSeq,
    'messages': messages.map((m) => m.toJson()).toList(),
  };

  factory Conversation.fromJson(Map<String, dynamic> json) {
    final conv = Conversation(
      id: json['id'] as String,
      title: json['title'] as String? ?? '',
      isRoom: json['isRoom'] as bool? ?? false,
    );
    conv.pinned = json['pinned'] as bool? ?? false;
    conv.lastSeq = (json['lastSeq'] as num?)?.toInt() ?? 0;
    for (final raw in (json['messages'] as List? ?? const [])) {
      if (raw is! Map) continue;
      final msg = ChatMessage.fromJson(Map<String, dynamic>.from(raw));
      conv.messages.add(msg);
      conv.lastMessage = msg;
      final s = msg.seq ?? 0;
      if (s > conv.lastSeq) conv.lastSeq = s;
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
  const RoomInfo({
    required this.roomId,
    required this.name,
    required this.members,
  });

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
enum ConnectionPhase {
  unconnected,
  connecting,

  /// Waiting on a backoff timer after a drop, before the next reconnect attempt.
  reconnecting,
  connected,
  failed,
}

class ChatClient extends ChangeNotifier {
  ChatClient({Tailscale? tailscale})
    : _tailscale = tailscale ?? Tailscale.instance;

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

  // ─── auto-reconnect (Phase 1.1) ────────────────────────────────────
  // Retained connection tuple so a drop can be re-dialed without asking the
  // user again (Telegram-style invisible reconnection).
  String? _hubHost;
  int? _hubPort;
  Timer? _reconnectTimer;
  int _reconnectAttempt = 0;
  bool _autoReconnect = false;
  static const int _maxReconnectSeconds = 30;

  // ─── pending-send tracking (Phase 1.3) ─────────────────────────────
  // Outgoing messages that haven't received their ack yet, keyed by
  // clientMessageId. Each entry owns a 15s timeout timer; on expiry the
  // message flips to [MessageStatus.failed] so the user can long-press to
  // resend (reusing the same clientMessageId — the hub dedupes).
  final Map<String, _PendingSend> _pending = {};
  static const Duration _ackTimeout = Duration(seconds: 15);

  Completer<void>? _helloAckCompleter;
  Completer<String>? _roomCreateCompleter;
  Completer<bool>? _roomJoinCompleter;
  Completer<List<RoomSummary>>? _roomListCompleter;
  Completer<RoomInfo>? _roomMembersCompleter;

  /// nodeId -> hostname map, learned from presence + message senders.
  final Map<String, String> _names = {};

  /// roomId -> display name, mirrored from `room/list` / `room/members` / acks
  /// and persisted to the local [RoomNames] registry. Used to render real
  /// group names immediately on re-login (even after clearing chat history)
  /// without waiting for the network round-trip.
  final Map<String, String> _roomNames = {};
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

  /// Toggles the pinned-to-top flag of a conversation (per-device preference,
  /// persisted in the local cache; the hub is not involved).
  void togglePinned(String conversationId) {
    final conv = _conversations[conversationId];
    if (conv == null) return;
    conv.pinned = !conv.pinned;
    _persist(conv);
    notifyListeners();
  }

  /// Removes a conversation locally (list + cache file) and asks the hub to
  /// clear its history so it does not resurrect on the next reconnect.
  Future<void> deleteConversation(String conversationId) async {
    final conv = _conversations.remove(conversationId);
    if (conv == null) return;
    await ChatCache.deleteOne(conversationId);
    if (_connected && _myNodeId != null) {
      _write(
        conv.isRoom
            ? ChatFrame(
                type: 'conv/clear',
                from: _myNodeId,
                roomId: conversationId,
              )
            : ChatFrame(
                type: 'conv/clear',
                from: _myNodeId,
                to: conversationId,
              ),
      );
    }
    notifyListeners();
  }

  /// Re-syncs with the hub: pulls incremental history since each conversation's
  /// last seq (dedup makes it idempotent) and refreshes the room list. Used by
  /// pull-to-refresh on the conversation list.
  Future<void> refresh() async {
    if (!_connected || _myNodeId == null) return;
    final cursors = <String, int>{
      for (final c in _conversations.values)
        if (c.lastSeq > 0) c.id: c.lastSeq,
    };
    _write(
      ChatFrame(
        type: 'offline',
        from: _myNodeId,
        payload: cursors.isEmpty
            ? {'limit': 200}
            : {'limit': 200, 'after': cursors},
      ),
    );
    await listRooms().then<void>((_) {}, onError: (_) {});
  }

  /// Loads locally cached conversations (offline browsing) + the room-name
  /// registry. Only fills gaps — any conversation already in memory wins
  /// (fresh data beats stale cache). Best-effort: failures leave empty state.
  Future<void> loadLocalCache() async {
    try {
      final cachedNames = await RoomNames.load();
      final cached = await ChatCache.loadAll();
      var added = false;
      for (final entry in cached.entries) {
        if (!_conversations.containsKey(entry.key)) {
          _conversations[entry.key] = entry.value;
          added = true;
        }
      }
      // Room-name registry: mirror into memory, and patch room conversations
      // whose title is still the raw room id (rebuilt from history or saved
      // by a pre-registry session) with the locally-cached real name.
      _roomNames.addAll(cachedNames);
      for (final name in cachedNames.entries) {
        final conv = _conversations[name.key];
        if (conv != null && conv.isRoom && conv.title == name.key) {
          conv.title = name.value;
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
    // 群名注册表不随聊天记录清除：它是元数据镜像，重登时仍能立即显示
    // 真实群名（hub 才是权威来源，下次 room/list 会自动校准）。
    notifyListeners();
    await ChatCache.clear();
  }

  /// Persists a conversation to the local cache (best-effort, fire-and-forget).
  void _persist(Conversation conv) {
    unawaited(ChatCache.save(conv));
  }

  /// Persists the room-name registry (best-effort, fire-and-forget).
  void _persistRoomNames() {
    if (_roomNames.isEmpty) return;
    unawaited(RoomNames.save(Map<String, String>.from(_roomNames)));
  }

  /// Connects to the hub over the tailnet. Requires [Tailscale.init] + [up]
  /// to have been called first so [Tailscale.instance.tcp] is usable.
  Future<void> connect({
    required String hubHost,
    required int hubPort,
    required String hostname,
  }) async {
    if (_connected) return;
    // Retain the connection tuple so a drop can auto-reconnect.
    _hubHost = hubHost;
    _hubPort = hubPort;
    _hostname = hostname;
    _reconnectTimer?.cancel();
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

      // Pull history (the hub replies with an `offline` frame). Reconnects
      // send per-conversation cursors so only newer messages come back
      // (Phase 1.2 incremental sync); a fresh connect pulls the full window.
      final cursors = _autoReconnect
          ? <String, int>{
              for (final c in _conversations.values)
                if (c.lastSeq > 0) c.id: c.lastSeq,
            }
          : null;
      _write(
        ChatFrame(
          type: 'offline',
          from: _myNodeId,
          payload: cursors == null || cursors.isEmpty
              ? {'limit': 200}
              : {'limit': 200, 'after': cursors},
        ),
      );

      _connected = true;
      // A connection was established — from here on a drop auto-reconnects.
      _autoReconnect = true;
      _reconnectAttempt = 0;
      // 群名不随历史消息下发：连接后主动拉一次群列表，让 _onRoomList 把
      // 重建会话的标题从 roomId 修正为真实群名（清缓存重登后群名不再丢失）。
      unawaited(listRooms().then<void>((_) {}, onError: (_) {}));
      // Phase 1.4: flush any messages that were queued while offline or
      // left in-flight when the previous connection dropped. Re-uses each
      // message's original clientMessageId so the hub dedupes — safe even
      // if a previous write actually landed but its ack was lost.
      _flushPending();
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
    // conv/clear ack — history deletion confirmed; nothing else to do (the
    // generic path below would otherwise flip every `sending` message to sent).
    if (frame.payload?['cleared'] != null) return;
    final roomId =
        frame.payload?['roomId']
            as String?; // Room acks (create/join/msg) all carry roomId. The `joined` marker
    // distinguishes room/join — and must be handled BEFORE the generic !ok
    // rejection below, otherwise a failed join (ok:false) would be swallowed
    // by the connection-failure path and the joinRoom() waiter would hang.
    if (roomId != null && frame.payload?['joined'] is bool) {
      // room/join ack — surface the result to the joinRoom() waiter.
      final joined = frame.payload?['joined'] == true;
      final name = (frame.payload?['name'] as String?) ?? roomId;
      if (name != roomId) {
        _roomNames[roomId] = name;
        _persistRoomNames();
      }
      final waiter = _roomJoinCompleter;
      _roomJoinCompleter = null;
      if (waiter != null && !waiter.isCompleted) {
        if (joined) {
          _conversations.putIfAbsent(
            roomId,
            () => Conversation(id: roomId, title: name, isRoom: true),
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
      // Auth rejection: don't auto-reconnect — a bad credential must not loop.
      _autoReconnect = false;
      _reconnectTimer?.cancel();
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
      // Mirror the authoritative room name into the registry + conversations
      // so it survives cache clears and shows instantly on re-login.
      final name = (frame.payload?['name'] as String?) ?? roomId;
      if (name != roomId) {
        _roomNames[roomId] = name;
        _persistRoomNames();
      }
      final createWaiter = _roomCreateCompleter;
      if (createWaiter != null && !createWaiter.isCompleted) {
        _roomCreateCompleter = null;
        createWaiter.complete(roomId);
      }
      _conversations.putIfAbsent(
        roomId,
        () => Conversation(id: roomId, title: name, isRoom: true),
      );
    } else if (_helloAckCompleter != null && !_helloAckCompleter!.isCompleted) {
      _helloAckCompleter!.complete();
      _helloAckCompleter = null;
    } else {
      // msg / room/msg ack — Phase 1.3: match by clientMessageId when present
      // (the hub echoes it back) so the ack lands on the exact message that
      // was sent, instead of the old "flip every sending message to sent"
      // broadcast. Falls back to ts matching for legacy hubs that don't echo
      // clientMessageId.
      final ackClientMessageId =
          frame.payload?['clientMessageId'] as String?;
      final ackSeq = (frame.payload?['seq'] as num?)?.toInt();
      final ackHubId = frame.payload?['id'];
      final ackHubIdStr =
          ackHubId is num ? ackHubId.toString() : ackHubId as String?;
      final ackTs = frame.ts;

      if (ackClientMessageId != null) {
        final pending = _pending.remove(ackClientMessageId);
        pending?.timer?.cancel();
        final conv = pending != null
            ? _conversations[pending.convId]
            : null;
        if (conv != null) {
          var changed = false;
          for (var i = 0; i < conv.messages.length; i++) {
            final m = conv.messages[i];
            if (m.clientMessageId != ackClientMessageId) continue;
            // Don't downgrade an already-read message back to sent (a
            // delayed ack could arrive after the read receipt propagated).
            if (m.status == MessageStatus.read) break;
            var updated = m.copyWith(status: MessageStatus.sent);
            if (ackSeq != null) updated = updated.copyWith(seq: ackSeq);
            if (ackHubIdStr != null) {
              updated = updated.copyWith(hubId: ackHubIdStr);
            }
            conv.messages[i] = updated;
            if (ackSeq != null && ackSeq > conv.lastSeq) {
              conv.lastSeq = ackSeq;
            }
            changed = true;
            break;
          }
          if (changed) {
            _persist(conv);
            notifyListeners();
          }
        }
        // If pending was null (e.g. ack arrived after the 15s timeout fired
        // and the message is already failed): re-flip to sent anyway — the
        // hub confirmed it. Find by clientMessageId across conversations.
        if (pending == null) {
          _applyLateAck(ackClientMessageId, ackSeq, ackHubIdStr);
        }
      } else {
        // Legacy path (hub didn't echo clientMessageId): match by ts. Pick
        // the FIRST sending message at that ts instead of broadcasting, to
        // avoid one ack flipping a whole batch of unrelated sends to sent.
        final ackTsValue = ackTs;
        var changed = false;
        Conversation? matchedConv;
        outer:
        for (final conv in _conversations.values) {
          for (var i = 0; i < conv.messages.length; i++) {
            final m = conv.messages[i];
            if (m.status != MessageStatus.sending) continue;
            if (ackTsValue != null && m.ts != ackTsValue) continue;
            var updated = m.copyWith(status: MessageStatus.sent);
            if (ackSeq != null) updated = updated.copyWith(seq: ackSeq);
            if (ackHubIdStr != null) {
              updated = updated.copyWith(hubId: ackHubIdStr);
            }
            conv.messages[i] = updated;
            if (ackSeq != null && ackSeq > conv.lastSeq) {
              conv.lastSeq = ackSeq;
            }
            matchedConv = conv;
            changed = true;
            break outer;
          }
        }
        if (changed && matchedConv != null) {
          _persist(matchedConv);
          notifyListeners();
        }
      }
    }
  }

  /// Handles an ack that arrives AFTER its 15s timeout already fired — the
  /// message is currently `failed` in the UI, but the hub confirms it was
  /// actually persisted. Flip it to `sent` (with the hub's id/seq) so the
  /// user doesn't see a phantom failure.
  void _applyLateAck(String clientMessageId, int? seq, String? hubId) {
    for (final conv in _conversations.values) {
      for (var i = 0; i < conv.messages.length; i++) {
        final m = conv.messages[i];
        if (m.clientMessageId != clientMessageId) continue;
        if (m.status != MessageStatus.failed) return;
        var updated = m.copyWith(status: MessageStatus.sent);
        if (seq != null) updated = updated.copyWith(seq: seq);
        if (hubId != null) updated = updated.copyWith(hubId: hubId);
        conv.messages[i] = updated;
        if (seq != null && seq > conv.lastSeq) conv.lastSeq = seq;
        _persist(conv);
        notifyListeners();
        return;
      }
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
    final seq = (frame.payload?['seq'] as num?)?.toInt();
    final threadId = roomId ?? from;
    final conv = _conversations.putIfAbsent(
      threadId,
      () => Conversation(
        id: threadId,
        title: roomId != null
            ? (_roomNames[roomId] ?? threadId)
            : displayName(from),
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
      seq: seq,
    );
    conv.messages.add(msg);
    conv.lastMessage = msg;
    if (seq != null && seq > conv.lastSeq) conv.lastSeq = seq;
    if (msg.isMine || threadId == activeConversationId) {
      // Message is in the conversation currently on screen: acknowledge it
      // right away so the sender sees the blue read check while we chat.
      if (!msg.isMine) sendReadReceipt(threadId);
    } else {
      conv.unread++;
      // Android 推送：非活跃会话收到新消息时弹通知（后台/其他会话页）。
      unawaited(
        NotificationService.instance.showMessageNotification(
          conversationId: threadId,
          title: displayName(from),
          body: text.isEmpty ? '（新消息）' : text,
          isRoom: roomId != null,
        ),
      );
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
    // `initial: true` marks the connect-time backlog — don't spam
    // notifications for old messages (only live/queued-flush notify).
    final isInitialPull = frame.payload?['initial'] == true;
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
      final seq = (map['seq'] as num?)?.toInt();
      final from = sender ?? '?';
      final threadId = roomId ?? from;
      final conv = _conversations.putIfAbsent(
        threadId,
        () => Conversation(
          id: threadId,
          title: roomId != null
              ? (_roomNames[roomId] ?? threadId)
              : displayName(from),
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
        seq: seq,
      );
      conv.messages.add(msg);
      conv.lastMessage = msg;
      if (seq != null && seq > conv.lastSeq) conv.lastSeq = seq;
      // History landing in the open conversation is read too.
      if (from != _myNodeId && threadId == activeConversationId) {
        sendReadReceipt(threadId);
      } else if (from != _myNodeId && threadId != activeConversationId) {
        conv.unread++;
        // 连接后离线补发的消息弹通知；连接时的初始历史拉取不弹（避免刷屏）。
        if (!isInitialPull) {
          unawaited(
            NotificationService.instance.showMessageNotification(
              conversationId: threadId,
              title: displayName(from),
              body: text.isEmpty ? '（新消息）' : text,
              isRoom: roomId != null,
            ),
          );
        }
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
    _maybeScheduleReconnect();
  }

  void _fail(String message) {
    _teardown();
    _lastError = message;
    _statusText = '连接失败';
    _phase = ConnectionPhase.failed;
    notifyListeners();
    _maybeScheduleReconnect();
  }

  /// Starts the auto-reconnect backoff timer. Only runs after the client has
  /// connected at least once (first-launch failures just show the connect
  /// panel); auth rejections disable it so a bad credential never loops.
  void _maybeScheduleReconnect() {
    if (!_autoReconnect || _connected) return;
    _reconnectTimer?.cancel();
    _reconnectAttempt++;
    final exp = (_reconnectAttempt - 1).clamp(0, 5); // 1s,2s,4s,8s,16s,30s…
    var baseMs = (1 << exp) * 1000;
    if (baseMs > _maxReconnectSeconds * 1000) {
      baseMs = _maxReconnectSeconds * 1000;
    }
    // ±20% random jitter: without it, all devices reconnect in lockstep.
    final jitterMs = Random().nextInt(baseMs ~/ 5 + 1);
    _phase = ConnectionPhase.reconnecting;
    _statusText = '重连中…';
    notifyListeners();
    _reconnectTimer = Timer(Duration(milliseconds: baseMs + jitterMs), () {
      unawaited(_reconnect());
    });
  }

  Future<void> _reconnect() async {
    _reconnectTimer?.cancel();
    final hubHost = _hubHost;
    final hubPort = _hubPort;
    if (!_autoReconnect || _connected || hubHost == null || hubPort == null) {
      return;
    }
    try {
      // connect() sets phase=connecting internally and, on failure, _fail()
      // re-schedules the backoff (if auto-reconnect is still enabled).
      await connect(hubHost: hubHost, hubPort: hubPort, hostname: _hostname ?? '');
    } catch (_) {
      // _fail already handled state + re-scheduling.
    }
  }

  /// Sends a 1:1 text message. Returns the message for optimistic UI.
  ///
  /// Phase 1.4: works offline too — the message is added locally as `sending`
  /// and queued (no ack timeout armed); the next successful reconnect
  /// flushes it. The hub's `(sender, clientMessageId)` idempotency map makes
  /// a re-send after a dropped-ack safe (no duplicate row / fan-out).
  ChatMessage sendMessage(String to, String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      throw const HubException('空消息');
    }
    final ts = DateTime.now().millisecondsSinceEpoch;
    final clientMessageId = _newClientMessageId(ts);
    final msg = ChatMessage(
      id: 'local-$ts-${to.hashCode}',
      from: _myNodeId ?? '',
      text: trimmed,
      ts: ts,
      isMine: true,
      status: MessageStatus.sending,
      clientMessageId: clientMessageId,
    );
    final conv = _conversations.putIfAbsent(
      to,
      () => Conversation(id: to, title: displayName(to)),
    );
    conv.messages.add(msg);
    conv.lastMessage = msg;
    _persist(conv);
    if (_connected && _myNodeId != null) {
      _trackPending(
        convId: to,
        isRoom: false,
        targetId: to,
        clientMessageId: clientMessageId,
        ts: ts,
        wireSent: true,
      );
      _write(
        ChatFrame(
          type: 'msg',
          from: _myNodeId,
          to: to,
          ts: ts,
          payload: {
            'text': trimmed,
            'hostname': _hostname ?? '',
            'clientMessageId': clientMessageId,
          },
        ),
      );
    } else {
      // Offline: queue locally without arming the ack timeout. The next
      // successful reconnect's _flushPending will write it to the wire and
      // arm the timeout then.
      _trackPending(
        convId: to,
        isRoom: false,
        targetId: to,
        clientMessageId: clientMessageId,
        ts: ts,
        wireSent: false,
      );
    }
    notifyListeners();
    return msg;
  }

  /// Creates a group room; the returned future completes with the hub's roomId.
  Future<String> createRoom(String name) {
    if (!_connected) return Future.error(const HubException('未连接'));
    final completer = Completer<String>();
    _roomCreateCompleter = completer;
    _write(
      ChatFrame(type: 'room/create', from: _myNodeId, payload: {'name': name}),
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
    if (trimmed.isEmpty) return;
    final ts = DateTime.now().millisecondsSinceEpoch;
    final clientMessageId = _newClientMessageId(ts);
    final msg = ChatMessage(
      id: 'local-$ts-$roomId',
      from: _myNodeId ?? '',
      roomId: roomId,
      text: trimmed,
      ts: ts,
      isMine: true,
      status: MessageStatus.sending,
      clientMessageId: clientMessageId,
    );
    final conv = _conversations[roomId];
    if (conv != null) {
      conv.messages.add(msg);
      conv.lastMessage = msg;
      _persist(conv);
    }
    if (_connected && _myNodeId != null) {
      _trackPending(
        convId: roomId,
        isRoom: true,
        targetId: roomId,
        clientMessageId: clientMessageId,
        ts: ts,
        wireSent: true,
      );
      _write(
        ChatFrame(
          type: 'room/msg',
          from: _myNodeId,
          roomId: roomId,
          ts: ts,
          payload: {
            'text': trimmed,
            'hostname': _hostname ?? '',
            'clientMessageId': clientMessageId,
          },
        ),
      );
    } else {
      // Offline: queue locally, flush on the next reconnect (Phase 1.4).
      _trackPending(
        convId: roomId,
        isRoom: true,
        targetId: roomId,
        clientMessageId: clientMessageId,
        ts: ts,
        wireSent: false,
      );
    }
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
    // Mirror authoritative names into the registry + refresh conversation
    // titles. Only overwrite titles that still carry the raw room id (a real
    // user-facing name set locally wins until the hub says otherwise).
    for (final r in rooms) {
      if (r.name.isNotEmpty) {
        _roomNames[r.id] = r.name;
      }
      final conv = _conversations[r.id];
      if (conv != null && conv.isRoom && conv.title == r.id) {
        conv.title = r.name;
      }
    }
    _persistRoomNames();
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
    // Mirror the authoritative room name (hub truth) into the registry.
    if (name.isNotEmpty && name != roomId) {
      _roomNames[roomId] = name;
      _persistRoomNames();
    }
    final conv = _conversations[roomId];
    if (conv != null && conv.isRoom) conv.title = name;
    if (!completer.isCompleted) {
      completer.complete(
        RoomInfo(roomId: roomId, name: name, members: members),
      );
    }
  }

  void _write(ChatFrame frame) {
    _conn?.output.write(encodeFrame(frame)).catchError((Object e) {
      _fail('发送失败: $e');
    });
  }

  // ─── Phase 1.3 pending-send tracking ────────────────────────────────

  /// Generates a per-message idempotency key. `ts` alone can collide when
  /// several messages land in the same millisecond, so it is mixed with a
  /// random component. Format is opaque to the hub — it only ever compares
  /// for equality.
  String _newClientMessageId(int ts) {
    final rand = Random().nextInt(1 << 32).toRadixString(36);
    return 'c${ts.toRadixString(36)}-$rand';
  }

  /// Registers an outgoing message as awaiting ack and arms its 15s timeout.
  ///
  /// [wireSent] (Phase 1.4): true when the frame has just been written to the
  /// socket (the normal online path) — arms the 15s ack timeout. false when
  /// the message is being queued offline (no socket yet) OR was sent on a
  /// connection that has since dropped — in that case no timeout is armed;
  /// the next successful reconnect flushes it via [_flushPending].
  void _trackPending({
    required String convId,
    required bool isRoom,
    required String targetId,
    required String clientMessageId,
    required int ts,
    required bool wireSent,
  }) {
    // Cancel any stale entry for the same key first (defensive — should not
    // happen because clientMessageId is unique per send).
    _pending[clientMessageId]?.timer?.cancel();
    _pending[clientMessageId] = _PendingSend(
      convId: convId,
      isRoom: isRoom,
      targetId: targetId,
      clientMessageId: clientMessageId,
      ts: ts,
      timer: wireSent
          ? Timer(_ackTimeout, () => _onAckTimeout(clientMessageId))
          : null,
      wireSent: wireSent,
    );
  }

  /// 15s elapsed with no ack — flip the message to failed so the user can
  /// long-press to resend. The hub is unreachable or wedged; we do NOT
  /// auto-resend because that could create duplicates if the ack is merely
  /// delayed (the user-initiated resend reuses clientMessageId → hub dedupes).
  void _onAckTimeout(String clientMessageId) {
    final pending = _pending.remove(clientMessageId);
    if (pending == null) return;
    final conv = _conversations[pending.convId];
    if (conv == null) return;
    var changed = false;
    for (var i = 0; i < conv.messages.length; i++) {
      final m = conv.messages[i];
      if (m.clientMessageId != clientMessageId) continue;
      if (m.status == MessageStatus.sending) {
        conv.messages[i] = m.copyWith(status: MessageStatus.failed);
        changed = true;
      }
    }
    if (changed) {
      _persist(conv);
      notifyListeners();
    }
  }

  /// Disconnect/teardown hook (Phase 1.4): cancels every armed ack-timeout
  /// and marks all in-flight sends as `wireSent=false` so the next
  /// successful reconnect flushes them. Messages stay `sending` in the UI
  /// (no false "failed"), and timers are cancelled so they don't fire
  /// post-teardown and wrongly flip a message to failed.
  ///
  /// The hub's `(sender, clientMessageId)` idempotency map makes the
  /// re-send on reconnect safe even if the original write actually reached
  /// the hub but the ack was lost in the drop.
  void _markPendingUnsent() {
    for (final p in _pending.values) {
      p.timer?.cancel();
      p.timer = null;
      p.wireSent = false;
    }
  }

  /// Phase 1.4: re-sends every queued (wireSent=false) pending message
  /// after a successful reconnect, arming their 15s ack timeouts. Called
  /// once at the tail of [connect]. Order is preserved by iterating the
  /// insertion-order map.
  void _flushPending() {
    if (_pending.isEmpty) return;
    for (final p in _pending.values) {
      if (p.wireSent) continue;
      final payload = <String, dynamic>{
        'text': _textForPending(p),
        'hostname': _hostname ?? '',
        'clientMessageId': p.clientMessageId,
      };
      if (p.isRoom) {
        _write(
          ChatFrame(
            type: 'room/msg',
            from: _myNodeId,
            roomId: p.targetId,
            ts: p.ts,
            payload: payload,
          ),
        );
      } else {
        _write(
          ChatFrame(
            type: 'msg',
            from: _myNodeId,
            to: p.targetId,
            ts: p.ts,
            payload: payload,
          ),
        );
      }
      p.wireSent = true;
      p.timer = Timer(_ackTimeout, () => _onAckTimeout(p.clientMessageId));
    }
  }

  /// Looks up the message text for a pending send (best-effort: the message
  /// may have been removed from the conversation, in which case we skip it).
  String _textForPending(_PendingSend p) {
    final conv = _conversations[p.convId];
    if (conv == null) return '';
    for (final m in conv.messages) {
      if (m.clientMessageId == p.clientMessageId) return m.text;
    }
    return '';
  }

  /// Long-press「重发」entry point: re-sends a failed message using its
  /// original clientMessageId so the hub can dedup it (no duplicate row, no
  /// duplicate fan-out). Returns true if a resend was actually issued.
  bool resendMessage(String conversationId, String clientMessageId) {
    if (!_connected || _myNodeId == null) return false;
    final conv = _conversations[conversationId];
    if (conv == null) return false;
    ChatMessage? target;
    for (final m in conv.messages) {
      if (m.clientMessageId == clientMessageId) {
        target = m;
        break;
      }
    }
    if (target == null) return false;
    if (target.status != MessageStatus.failed) return false;
    // Flip back to sending and re-track the ack timeout.
    final idx = conv.messages.indexOf(target);
    conv.messages[idx] = target.copyWith(status: MessageStatus.sending);
    _trackPending(
      convId: conversationId,
      isRoom: target.roomId != null,
      targetId: target.roomId ?? conversationId,
      clientMessageId: clientMessageId,
      ts: target.ts,
      wireSent: true,
    );
    final payload = <String, dynamic>{
      'text': target.text,
      'hostname': _hostname ?? '',
      'clientMessageId': clientMessageId,
    };
    if (target.roomId != null) {
      _write(
        ChatFrame(
          type: 'room/msg',
          from: _myNodeId,
          roomId: target.roomId,
          ts: target.ts,
          payload: payload,
        ),
      );
    } else {
      _write(
        ChatFrame(
          type: 'msg',
          from: _myNodeId,
          to: conversationId,
          ts: target.ts,
          payload: payload,
        ),
      );
    }
    _persist(conv);
    notifyListeners();
    return true;
  }

  /// Locally removes a single message (used by the long-press menu on a
  /// failed send). The hub is never contacted — if the message had reached
  /// the hub it would not be `failed`. Also cancels its ack-timeout if it is
  /// somehow still pending (defensive).
  void removeMessage(String conversationId, String messageId) {
    final conv = _conversations[conversationId];
    if (conv == null) return;
    final idx = conv.messages.indexWhere((m) => m.id == messageId);
    if (idx < 0) return;
    final removed = conv.messages.removeAt(idx);
    final cmid = removed.clientMessageId;
    if (cmid != null) {
      final pending = _pending.remove(cmid);
      pending?.timer?.cancel();
    }
    // Patch lastMessage if we just removed the tail.
    if (conv.lastMessage?.id == messageId) {
      conv.lastMessage =
          conv.messages.isEmpty ? null : conv.messages.last;
    }
    _persist(conv);
    notifyListeners();
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
    _markPendingUnsent();
    _inputSub?.cancel();
    _inputSub = null;
    _conn?.close();
    _conn = null;
    _connected = false;
    _onlineNodes.clear();
  }

  Future<void> disconnect() async {
    // Manual disconnect: stop auto-reconnect so it doesn't come back on its own.
    _autoReconnect = false;
    _reconnectTimer?.cancel();
    _write(const ChatFrame(type: 'bye'));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    _teardown();
    _statusText = '未连接';
    _phase = ConnectionPhase.unconnected;
    notifyListeners();
  }

  @override
  void dispose() {
    _autoReconnect = false;
    _reconnectTimer?.cancel();
    _teardown();
    super.dispose();
  }
}

/// Tracks one outgoing message awaiting its ack (Phase 1.3).
///
/// Owns the ack-timeout timer so a drop/teardown can cancel it cleanly. The
/// hub echoes `clientMessageId` back in its ack, which is how the client
/// matches the ack to this exact pending send (replacing the old "flip every
/// sending message to sent" broadcast).
///
/// Phase 1.4 added [wireSent]: false while the message has NOT yet been put
/// on the wire (sent while offline, or a drop happened before the ack). Such
/// entries have NO timeout armed — they wait for the next successful
/// reconnect, at which point [_ChatClient._flushPending] re-sends them and
/// flips `wireSent` to true (arming the timeout then). The hub's
/// `(sender, clientMessageId)` idempotency map makes a re-send safe even if
/// the original write actually reached the hub but the ack was lost.
class _PendingSend {
  _PendingSend({
    required this.convId,
    required this.isRoom,
    required this.targetId,
    required this.clientMessageId,
    required this.ts,
    required this.timer,
    required this.wireSent,
  });

  /// Conversation the message lives in (1:1 nodeId or room id).
  final String convId;

  /// True for `room/msg`, false for 1:1 `msg`.
  final bool isRoom;

  /// `to` for 1:1, `roomId` for rooms — where the message is addressed.
  final String targetId;

  /// Idempotency key shared with the hub.
  final String clientMessageId;

  /// Original wire ts (the hub echoes it back in its ack).
  final int ts;

  /// 15s ack-timeout timer. On fire, the message flips to failed.
  /// `null` while [wireSent] is false (waiting for reconnect flush).
  Timer? timer;

  /// False until the frame has actually been written to the socket. Pending
  /// entries with `wireSent == false` are re-sent on the next successful
  /// reconnect (Phase 1.4 offline queueing + flush).
  bool wireSent;
}

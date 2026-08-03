# TL Chat — Code Wiki

## 目录

1. [项目概述](#1-项目概述)
2. [整体架构](#2-整体架构)
3. [目录结构](#3-目录结构)
4. [核心模块说明](#4-核心模块说明)
   - [4.1 Flutter 客户端](#41-flutter-客户端)
   - [4.2 Hub 服务端](#42-hub-服务端)
5. [通信协议](#5-通信协议)
6. [关键类与函数](#6-关键类与函数)
7. [数据流分析](#7-数据流分析)
8. [依赖关系](#8-依赖关系)
9. [项目运行方式](#9-项目运行方式)

---

## 1. 项目概述

**TL Chat** 是一个基于 **Tailscale 内网穿透**的即时聊天应用，包含 Flutter 移动端客户端和 Node.js 中继服务端（Hub）。项目利用 Tailscale 的 Mesh VPN 网络实现设备间安全通信，无需公网 IP 或端口转发。

| 属性 | 说明 |
|------|------|
| 项目名称 | tl_chat |
| 客户端技术栈 | Flutter 3.44+ (Dart 3.12+) |
| 服务端技术栈 | Node.js 24+ (TypeScript 5) |
| 网络层 | Tailscale Mesh VPN (tailscale_dart) |
| 数据持久化 | SQLite (服务端权威存储), JSON 文件 (客户端本地缓存) |
| 通信协议 | 自定义 JSON 帧协议 (长度前缀) |
| 目标平台 | Android (主), iOS, Web, Desktop |

---

## 2. 整体架构

```
┌─────────────────────────────────────────────────────┐
│                    Tailscale Mesh VPN                │
│  (tailnet — 加密 Mesh 网络，设备间直连 / DERP 中继)   │
└─────────────────────────────────────────────────────┘
          ▲                        ▲
          │ TCP (tailnet)          │ TCP (tailnet)
          ▼                        ▼
┌──────────────────┐    ┌──────────────────────────────┐
│  Flutter 客户端    │    │    Hub 服务端 (Node.js)       │
│  (Android/Phone)  │◄──►│    (VPS / Armbian 常驻节点)   │
│                   │    │                              │
│  ┌─────────────┐  │    │  ┌──────────┐  ┌─────────┐  │
│  │ ChatClient  │──┼───►│  │  Hub     │─►│ Store   │  │
│  │ (ChangeNoti)│  │    │  │(Session) │  │ (SQLite)│  │
│  └──────┬──────┘  │    │  └────┬─────┘  └─────────┘  │
│         │         │    │       │                      │
│  ┌──────┴──────┐  │    │  ┌────┴─────┐               │
│  │ChatCache    │  │    │  │ChatRouter│               │
│  │(本地JSON缓存)│  │    │  │(路由状态) │               │
│  └─────────────┘  │    │  └──────────┘               │
│                   │    │                              │
│  ┌─────────────┐  │    │  ┌──────────┐               │
│  │ChatSettings │  │    │  │  whois   │               │
│  │(持久化配置)  │  │    │  │(身份认证) │               │
│  └─────────────┘  │    │  └──────────┘               │
│                   │    │                              │
│  ┌─────────────┐  │    │  ┌──────────┐               │
│  │Notification │  │    │  │Protocol  │               │
│  │Service      │  │    │  │(编解码)   │               │
│  └─────────────┘  │    │  └──────────┘               │
└──────────────────┘    └──────────────────────────────┘
```

### 架构要点

- **C/S 架构**：Hub 作为中心节点，客户端通过 Tailscale 内网直连 Hub
- **Tailscale 网络层**：客户端通过 `tailscale_dart` 接入 tailnet，Hub 通过 OS 级 `tailscaled` 接入
- **多设备支持**：同一节点可同时多设备登录，Hub 会向所有设备推送消息
- **离线消息**：Hub 的 SQLite 持久化存储消息，设备上线后自动推送
- **本地缓存**：客户端 JSON 文件缓存，支持离线浏览

---

## 3. 目录结构

```
tl_chat/
├── lib/                          # Flutter 客户端核心代码
│   ├── main.dart                 # 应用入口
│   ├── app.dart                  # MaterialApp 配置 (主题、路由)
│   ├── network/
│   │   ├── chat_client.dart      # 聊天客户端核心逻辑 (ChatClient)
│   │   ├── chat_protocol.dart    # 通信协议 (编解码)
│   │   ├── chat_cache.dart       # 本地聊天缓存 (JSON 文件)
│   │   └── chat_settings.dart    # 持久化连接配置
│   ├── pages/
│   │   ├── home_page.dart        # 主页 (会话列表 + 连接面板)
│   │   └── chat_page.dart        # 聊天页 (消息气泡 + 输入框)
│   ├── widgets/
│   │   ├── connect_panel.dart    # 连接配置面板
│   │   ├── conversation_tile.dart # 会话列表项
│   │   ├── animated_bubble.dart  # 消息气泡入场动画
│   │   ├── skeleton_conversation_list.dart  # 骨架屏加载
│   │   └── typing_subtitle.dart  # 正在输入指示器
│   ├── services/
│   │   └── notifications.dart    # Android 推送通知 + 前台服务保活
│   └── theme/
│       └── telegram_theme.dart   # Telegram 风格主题系统
│
├── hub/                          # Node.js 服务端
│   ├── package.json              # 依赖 & 脚本
│   ├── tsconfig.json             # TypeScript 配置
│   ├── tsconfig.build.json       # 构建配置
│   ├── src/
│   │   ├── server.ts             # Hub 服务主入口 (Hub class)
│   │   ├── protocol.ts           # 通信协议 (ChatFrame, FrameDecoder)
│   │   ├── router.ts             # 路由状态 (在线/离线, 房间成员)
│   │   ├── store.ts              # SQLite 数据持久化
│   │   └── whois.ts              # Tailscale 身份认证
│   └── tool/
│       └── sim.ts                # 模拟客户端测试工具
│
├── test/                         # 测试
│   ├── widget_test.dart          # Widget 测试
│   └── tailscale_smoke_test.dart # Tailscale 冒烟测试
│
├── android/                      # Android 原生配置
├── .github/workflows/
│   └── release.yml               # CI/CD: 构建 APK + GitHub Release
├── pubspec.yaml                  # Flutter 依赖配置
└── README.md                     # 项目说明
```

---

## 4. 核心模块说明

### 4.1 Flutter 客户端

#### 4.1.1 `lib/main.dart` — 应用入口

```dart
Future<void> main() async {
  await NotificationService.instance.init();  // 初始化推送通知
  runApp(const ChatApp());                    // 启动应用
}
```

- 调用 `NotificationService.init()` 初始化 Android 本地通知和前台服务
- 启动 `ChatApp` Widget

#### 4.1.2 `lib/app.dart` — 应用根组件

- **`ChatApp`**: `StatefulWidget`，管理应用主题切换（亮/暗）
- 使用 `telegramLightTheme()` / `telegramDarkTheme()` 提供 Telegram 风格主题
- 主页为 `HomePage`，传递主题切换回调

#### 4.1.3 `lib/network/chat_client.dart` — 核心聊天客户端

这是客户端最核心的模块，包含：

**数据模型**:

| 类 | 说明 |
|----|------|
| `ChatMessage` | 单条消息（id, from, text, ts, isMine, status, hubId, seq, clientMessageId） |
| `Conversation` | 会话线程（id, title, messages, unread, pinned, lastSeq） |
| `RoomSummary` | 群聊摘要（id, name, memberCount, isMember） |
| `RoomMember` | 群成员（id, hostname, online） |
| `RoomInfo` | 群聊详情（roomId, name, members） |
| `HubException` | 协议/连接异常 |
| `ConnectionPhase` | 连接阶段枚举（unconnected, connecting, reconnecting, connected, failed） |
| `MessageStatus` | 消息状态枚举（sending, sent, delivered, read, failed） |

**`ChatClient` 核心类** (extends `ChangeNotifier`):

| 属性/方法 | 说明 |
|----------|------|
| `connect()` | 连接 Hub：Tailscale TCP 拨号 → hello 注册 → 拉取历史 → 启动心跳 |
| `disconnect()` | 断开连接，停止自动重连 |
| `sendMessage(to, text)` | 发送 1:1 消息（支持离线排队） |
| `sendRoomMessage(roomId, text)` | 发送群消息 |
| `createRoom(name)` | 创建群聊 |
| `joinRoom(roomId)` | 加入群聊 |
| `listRooms()` | 获取群列表 |
| `roomMembers(roomId)` | 获取群成员 |
| `sendReadReceipt(convId)` | 发送已读回执 |
| `resendMessage(convId, clientMsgId)` | 重发失败消息（幂等） |
| `removeMessage(convId, msgId)` | 本地删除消息 |
| `deleteConversation(convId)` | 删除会话（本地 + Hub） |
| `refresh()` | 增量同步 + 刷新群列表 |
| `onTypingKeystroke()` | 输入状态通知（3秒防抖） |
| `stopTyping()` | 停止输入状态 |
| `togglePinned()` | 切换置顶状态 |
| `loadLocalCache()` | 加载本地缓存 |
| `clearLocalCache()` | 清除本地缓存 |
| `_handleFrame()` | 帧分发器：ack/ping/pong/msg/room/msg/presence/offline/read/typing |
| `_onAckTimeout()` | 15秒 ack 超时处理 |
| `_flushPending()` | 重连后刷新待发送队列 |
| `_trackPending()` | 跟踪待确认消息 |
| `_startHeartbeat()` | 30秒心跳间隔 |

**自动重连机制**:
- 指数退避 + 随机抖动: 1s, 2s, 4s, 8s, 16s, 30s (max)
- 认证拒绝不自动重连
- 断开后自动重连

**消息幂等性 (Phase 1.3)**:
- 每条消息生成唯一 `clientMessageId`
- Hub 缓存 24 小时，重发自动去重
- 15 秒 ack 超时标记失败

**离线消息队列 (Phase 1.4)**:
- 离线时发送的消息本地排队（`wireSent=false`）
- 重连后 `_flushPending()` 自动发送
- 利用 Hub 幂等性保证安全

#### 4.1.4 `lib/network/chat_protocol.dart` — 协议编解码

- **`ChatFrame`**: 帧数据结构（type, from, to, roomId, ts, payload）
- **`encodeFrame()`**: 帧编码 → `[4字节大端长度][UTF-8 JSON]`
- **`FrameDecoder`**: 帧解码器，处理 TCP 粘包/拆包
- `maxFrameBytes = 4MB` 保护

#### 4.1.5 `lib/network/chat_cache.dart` — 本地缓存

- 每个会话一个 JSON 文件，存储在 `getApplicationSupportDirectory()/chat_cache/`
- `ChatCache.save()` / `loadAll()` / `deleteOne()` / `clear()`
- **`RoomNames`**: 群名注册表，独立存储（不随聊天记录清除）

#### 4.1.6 `lib/network/chat_settings.dart` — 持久化配置

- 存储 `hostname`, `hubHost`, `hubPort`
- 实现微信/QQ 风格自动登录

#### 4.1.7 `lib/pages/home_page.dart` — 主页

**功能**:
- 连接面板：Tailscale 初始化 + Hub 连接配置
- 会话列表：Telegram 风格，支持置顶/已读/删除滑动操作
- 搜索过滤
- 在线节点横向滚动条
- FAB 新建会话（私聊 + 群聊）
- 离线浏览模式
- 自动登录（WeChat/QQ 风格）

**关键方法**:
| 方法 | 说明 |
|------|------|
| `_init()` | 启动序列：加载缓存 → 读取设置 → 自动登录 |
| `_connect()` | 连接流程：Tailscale.init → up → 解析Hub地址 → 连接 |
| `_maybeAutoLogin()` | 判断是否自动登录（已注册节点跳过 auth key） |
| `_resolveHubAddress()` | 通过 Tailscale 节点列表解析 Hub 地址 |
| `_openChat()` | 打开会话（自定义 Fade+Slide 过渡动画） |
| `_newChatSheet()` | 新建会话底部弹窗 |
| `_joinRoomSheet()` | 加入群聊底部弹窗 |

#### 4.1.8 `lib/pages/chat_page.dart` — 聊天页

**功能**:
- 消息气泡列表（Telegram 风格）
- 输入框 + 发送按钮
- 日期分隔线
- 已读回执
- 输入状态指示器
- 群成员列表
- 长按菜单：重发/复制/删除

**关键方法**:
| 方法 | 说明 |
|------|------|
| `_send()` | 发送消息（支持离线） |
| `_scrollToBottom()` | 平滑滚动到底部 |
| `_maybeAutoScroll()` | 智能自动滚动（距底部 120px 内触发） |
| `_showMessageMenu()` | 长按消息菜单 |
| `_showRoomMembers()` | 群成员底部弹窗 |

#### 4.1.9 `lib/services/notifications.dart` — 通知服务

**`NotificationService`** (单例):

| 方法 | 说明 |
|------|------|
| `init()` | 初始化本地通知 + 前台服务配置 + 权限请求 |
| `startKeepAlive()` | 启动前台服务保活 |
| `stopKeepAlive()` | 停止前台服务 |
| `showMessageNotification()` | 弹出新消息通知（通知栏分组防堆叠） |
| `addTapListener()` | 注册通知点击回调（打开对应会话） |

**冷启动处理**:
- 应用被杀后点击通知拉起 → 暂存会话 id → 等待监听器注册后跳转

#### 4.1.10 `lib/theme/telegram_theme.dart` — 主题系统

- **`Tg`**: 静态颜色常量（Telegram 标准色板）
- **`TgPalette`**: 主题自适应调色板（根据亮/暗模式切换）
- **`TgAvatar`**: 圆形头像组件（确定性颜色 + 首字母 + 在线绿点）
- **`telegramLightTheme()` / `telegramDarkTheme()`**: 完整主题配置

### 4.2 Hub 服务端

#### 4.2.1 `hub/src/server.ts` — Hub 服务主入口

**`Hub` 核心类**:

| 属性/方法 | 说明 |
|----------|------|
| `options` | 配置：host, port, dbPath, auth |
| `start()` | 启动 TCP 服务器 + 心跳定时器 |
| `stop()` | 停止服务，清理所有连接 |
| `onConnection()` | 处理新连接，创建 Session |
| `onFrame()` | 帧分发器（15 种帧类型） |
| `onHello()` | 处理 hello 注册：身份认证 → 加入会话 → 刷新离线消息 |
| `onDisconnect()` | 处理断开连接（多设备场景保留其他会话） |
| `onDirectMessage()` | 处理 1:1 消息：持久化 → 幂等检查 → 投递 → 队列 |
| `onRoomMessage()` | 处理群消息：同上，但投递到所有成员 |
| `onReadReceipt()` | 处理已读回执（1:1 和群聊两种路由） |
| `onTyping()` | 转发输入状态（纯中继，不持久化） |
| `onRoomCreate()` | 创建群聊 |
| `onRoomJoin()` | 加入群聊 |
| `onRoomLeave()` | 离开群聊 |
| `onRoomList()` | 返回群列表 |
| `onRoomMembers()` | 返回群成员（含在线状态） |
| `onOfflineRequest()` | 返回历史消息（支持增量同步） |
| `onConversationClear()` | 删除会话历史 |
| `broadcastPresence()` | 广播在线状态 |
| `onHeartbeat()` | 心跳检测：30s 空闲 → ping → 15s 超时断开 |

**Session 结构**:
```typescript
interface Session {
  socket: Socket;
  decoder: FrameDecoder;
  nodeId: string | null;
  hostname: string | null;
  remoteIp: string;
  lastActivity: number;
  pingOutstanding: boolean;
}
```

**多设备支持**:
- `sessions = Map<string, Set<Session>>` — 每个节点对应多个连接
- 消息向所有设备推送
- 仅当最后一个设备断开才标记离线

#### 4.2.2 `hub/src/protocol.ts` — 通信协议

与客户端完全一致的协议实现：

- **`ChatFrame`**: 帧接口定义
- **`encodeFrame()`**: 帧编码
- **`FrameDecoder`**: 帧解码器（处理 TCP 粘包）
- `MAX_FRAME_BYTES = 4MB`

#### 4.2.3 `hub/src/router.ts` — 路由状态管理

**`ChatRouter`** 纯状态类（无 I/O，可测试）：

| 方法 | 说明 |
|------|------|
| `isOnline(nodeId)` | 检查节点是否在线 |
| `markOnline/markOffline` | 标记在线/离线 |
| `createRoom()` | 创建房间（创建者自动加入） |
| `joinRoom/leaveRoom` | 加入/离开房间 |
| `roomMembers()` | 获取房间成员列表 |
| `roomsOf(nodeId)` | 节点所属的所有房间 |
| `allRooms()` | 所有房间列表 |

**Room 结构**:
```typescript
interface Room {
  id: string;
  name: string;
  owner: string;
  members: Set<string>;
}
```

#### 4.2.4 `hub/src/store.ts` — SQLite 持久化存储

使用 Node.js 内置 `node:sqlite`（零原生依赖）。

**`Store` 类**:

| 表 | 说明 |
|----|------|
| `messages` | 消息存储（id, room_id, sender, recipient, payload, ts, delivered, seq） |
| `rooms` | 房间信息（id, name, owner, members JSON） |
| `conv_seq` | 会话级单调递增序列号 |
| `room_read_seq` | 群聊已读游标 |

**关键方法**:

| 方法 | 说明 |
|------|------|
| `insert()` | 插入消息（自动分配 seq，清理旧队列） |
| `queuedFor()` | 获取未投递消息 |
| `markDelivered()` | 标记消息已投递 |
| `historyFor()` | 获取历史消息（含 1:1 双向 + 群消息） |
| `incrementalFor()` | 增量同步（基于 seq 游标） |
| `clearConversation()` | 删除会话历史 |
| `saveRoom()/loadRooms()` | 房间持久化/恢复 |
| `upsertRoomReadSeq()` | 更新群已读游标（GREATEST 防回滚） |
| `distinct1to1Peers()` | 获取所有 1:1 聊天对象 |

**设计要点**:
- WAL 模式提升并发性能
- 最大队列 1000 条/人（防无限增长）
- seq 按会话递增（1:1 双向共享序列空间）
- 消息持久化不只是离线队列，是权威历史存储

#### 4.2.5 `hub/src/whois.ts` — 身份认证

**认证流程**:
1. 主路径：`tailscale status --json` → 解析 `Peer.ID` 匹配连接 IP
2. 降级路径：`tailscale whois <ip>` → 解析文本输出
3. 重试机制：5 次尝试 + 300ms 退避（约 11.2s 最坏情况）
4. 客户端 hello-ack 窗口 20s，留足余量

**关键函数**:
| 函数 | 说明 |
|------|------|
| `runWhois(ip)` | 主入口，先 status --json 再 whois 降级 |
| `parseStatusJson()` | 解析 status --json 输出 |
| `parseWhoisOutput()` | 解析 whois 文本输出 |

#### 4.2.6 `hub/tool/sim.ts` — 模拟测试工具

- 模拟两个客户端通过纯 TCP 连接 Hub（auth off）
- 测试注册、1:1 投递、离线队列、Presence 广播、群聊路由

---

## 5. 通信协议

### 5.1 帧格式

```
┌─────────────────────────────────────────────────────┐
│  4 bytes (Big-Endian)  │     N bytes (UTF-8 JSON)   │
│  帧体长度 N             │     JSON 帧体              │
└─────────────────────────────────────────────────────┘
```

### 5.2 帧类型

| 类型 | 方向 | 说明 |
|------|------|------|
| `hello` | C→S | 注册连接（携带 nodeId, hostname） |
| `ping` | 双向 | 心跳探测 |
| `pong` | 双向 | 心跳响应 |
| `bye` | C→S | 优雅断开 |
| `msg` | 双向 | 1:1 消息 |
| `room/msg` | 双向 | 群消息 |
| `ack` | S→C | 操作确认（含 id, seq, clientMessageId） |
| `offline` | 双向 | 拉取/推送历史消息 |
| `read` | 双向 | 已读回执 |
| `presence` | S→C | 在线状态广播 |
| `typing` | 双向 | 输入状态 |
| `room/create` | C→S | 创建群聊 |
| `room/join` | C→S | 加入群聊 |
| `room/leave` | C→S | 离开群聊 |
| `room/list` | C→S | 获取群列表 |
| `room/members` | C→S | 获取群成员 |
| `conv/clear` | C→S | 清除会话历史 |

### 5.3 帧结构

```json
{
  "type": "msg",
  "from": "n1234abcd",
  "to": "n5678efgh",
  "roomId": "room_xxx",
  "ts": 1700000000000,
  "payload": {
    "text": "Hello!",
    "hostname": "my-phone",
    "clientMessageId": "cx1a2b3c-abc123",
    "id": 42,
    "seq": 7
  }
}
```

### 5.4 通信流程

```
客户端                              Hub
  │                                  │
  │─── hello (nodeId, hostname) ────→│  // 注册
  │←── ack {ok: true, hostname} ────│  // 认证成功
  │←── offline {messages: [...]} ───│  // 离线消息推送
  │←── presence {online: [...]} ────│  // 在线状态
  │                                  │
  │─── msg (to, text) ──────────────→│  // 发送消息
  │←── ack {ok, id, seq} ───────────│  // 服务端确认
  │←── msg (from, text) ────────────│  // 接收消息
  │                                  │
  │─── ping ────────────────────────→│  // 心跳
  │←── pong ────────────────────────│  // 心跳响应
  │                                  │
  │─── bye ─────────────────────────→│  // 断开
```

---

## 6. 关键类与函数

### 6.1 客户端关键类

| 类 | 文件 | 职责 |
|----|------|------|
| `ChatClient` | `chat_client.dart` | 核心客户端：连接管理、消息收发、状态管理 |
| `ChatMessage` | `chat_client.dart` | 消息模型（不可变，支持 copyWith） |
| `Conversation` | `chat_client.dart` | 会话模型（消息列表、未读计数、置顶） |
| `ChatFrame` | `chat_protocol.dart` | 通信帧模型 |
| `FrameDecoder` | `chat_protocol.dart` | TCP 帧解码器（粘包处理） |
| `ChatCache` | `chat_cache.dart` | 本地缓存管理 |
| `RoomNames` | `chat_cache.dart` | 群名注册表 |
| `ChatSettings` | `chat_settings.dart` | 连接配置持久化 |
| `NotificationService` | `notifications.dart` | 推送通知 + 前台保活 |
| `ChatApp` | `app.dart` | 应用根组件 |
| `HomePage` | `home_page.dart` | 主页 |
| `ChatPage` | `chat_page.dart` | 聊天页 |
| `ConnectPanel` | `connect_panel.dart` | 连接配置面板 |
| `ConversationTile` | `conversation_tile.dart` | 会话列表行（Slidable 滑动操作） |
| `AnimatedBubble` | `animated_bubble.dart` | 消息气泡入场动画 |
| `TypingSubtitle` | `typing_subtitle.dart` | 输入状态指示器 |
| `Tg` / `TgPalette` / `TgAvatar` | `telegram_theme.dart` | 主题系统 |

### 6.2 服务端关键类

| 类 | 文件 | 职责 |
|----|------|------|
| `Hub` | `server.ts` | 核心服务：连接管理、帧路由、状态广播 |
| `ChatRouter` | `router.ts` | 路由状态：在线/离线、房间成员关系 |
| `Store` | `store.ts` | SQLite 持久化：消息、房间、序列号 |
| `FrameDecoder` | `protocol.ts` | TCP 帧解码器 |
| `ChatFrame` | `protocol.ts` | 通信帧接口 |
| `SimClient` | `sim.ts` | 模拟客户端测试 |

### 6.3 关键函数

| 函数 | 位置 | 说明 |
|------|------|------|
| `encodeFrame()` | 双方 `protocol` | 帧编码：4字节长度前缀 + JSON |
| `FrameDecoder.push()` | 双方 `protocol` | 帧解码：处理 TCP 粘包 |
| `runWhois()` | `whois.ts` | Tailscale 身份认证 |
| `normalizeRemoteIp()` | `server.ts` | IPv6 映射地址规范化 |
| `readClientMessageId()` | `server.ts` | 提取幂等键 |
| `_newClientMessageId()` | `chat_client.dart` | 生成客户端消息幂等键 |

---

## 7. 数据流分析

### 7.1 连接建立流程

```
1. 用户填写 Hub 地址 + Auth key
2. Tailscale.init(stateDir) → 初始化 Tailscale 引擎
3. Tailscale.up(hostname, authKey) → 注册到 tailnet
4. status() 获取 stableNodeId (n1234abcd)
5. tailscale.tcp.dial(hubHost, hubPort) → TCP 连接
6. 发送 hello {from: nodeId, payload: {hostname}}
7. Hub 端: tailscale status --json 验证连接 IP 的 nodeId
8. Hub 返回 ack {ok: true} → 客户端标记 connected
9. Hub 推送离线消息 (offline 帧)
10. Hub 广播 presence (在线状态)
11. 客户端拉取群列表 (room/list)
12. 客户端刷新待发送队列 (_flushPending)
13. 启动心跳定时器 (30s)
```

### 7.2 消息发送流程 (1:1)

```
1. 用户输入文本 → sendMessage(to, text)
2. 生成 clientMessageId (幂等键)
3. 创建 ChatMessage (status: sending) → 加入本地会话
4. 持久化到本地缓存
5. 发送 msg 帧到 Hub
6. 注册 _PendingSend (15s 超时)
7. Hub 接收 → 幂等检查 → SQLite 插入 → 分配 id + seq
8. Hub 投递到接收方所有在线设备
9. Hub 投递到发送方其他设备
10. Hub 返回 ack {ok, id, seq, clientMessageId}
11. 客户端收到 ack → 匹配 clientMessageId → 更新 status: sent
12. 如接收方离线 → 消息留在 SQLite (delivered=0) → 上线后推送
```

### 7.3 增量同步流程

```
1. 重连时收集各会话 lastSeq
2. 发送 offline {after: {convId: lastSeq}}
3. Hub 查询 conv_seq 表，返回 seq > cursor 的消息
4. 客户端按 hubId 去重
5. 合并到本地会话
```

### 7.4 已读回执流程

```
1:1 场景:
  1. 接收方打开会话 → 发送 read {to: peer, payload: {lastTs}}
  2. Hub 转发到发送方所有设备
  3. 发送方翻转 ts ≤ lastTs 的消息为 read

群聊场景:
  1. 接收方发送 read {roomId, payload: {maxReadSeq}}
  2. Hub 写入 room_read_seq (GREATEST 防回滚)
  3. Hub 向其他成员广播
  4. 成员翻转 seq ≤ maxReadSeq 的已发送消息为 read
```

---

## 8. 依赖关系

### 8.1 Flutter 客户端依赖 (pubspec.yaml)

| 依赖 | 说明 |
|------|------|
| `flutter` SDK | UI 框架 |
| `cupertino_icons` | iOS 风格图标 |
| `tailscale` (路径依赖) | `../tailscale_dart` — Tailscale 网络库 (42419 fork) |
| `path_provider` | 获取平台目录路径 |
| `path` | 路径拼接 |
| `flutter_local_notifications` | Android 本地推送通知 |
| `flutter_foreground_task` | Android 前台服务保活 |
| `flutter_slidable` | 列表项滑动操作 |
| `flutter_lints` (dev) | 代码规范检查 |
| `flutter_test` (dev) | 测试框架 |

### 8.2 Hub 服务端依赖 (package.json)

| 依赖 | 说明 |
|------|------|
| `typescript` (dev) | TypeScript 编译器 |
| `tsx` (dev) | TypeScript 直接执行 |
| `@types/node` (dev) | Node.js 类型定义 |
| Node.js 内置 `node:net` | TCP 服务器 |
| Node.js 内置 `node:sqlite` | SQLite 数据库 |
| Node.js 内置 `node:child_process` | 调用 tailscale CLI |

### 8.3 外部依赖

| 依赖 | 说明 |
|------|------|
| **Tailscale** | Mesh VPN 网络层（OS 级 tailscaled + tailscale_dart 库） |
| **SQLite** | 服务端消息持久化（Node.js 内置） |
| **GitHub Actions** | CI/CD（构建 APK + Release） |

---

## 9. 项目运行方式

### 9.1 前置条件

1. **Tailscale 网络**：所有设备需加入同一个 tailnet
2. **Tailscale 节点**：Hub 服务端需运行 `tailscaled` 并登录
3. **Node.js 24+**：Hub 服务端运行环境
4. **Flutter 3.44+**：客户端构建环境
5. **tailscale_dart 依赖**：需克隆到 `../tailscale_dart`（与项目同级）

### 9.2 启动 Hub 服务端

```bash
# 进入 hub 目录
cd hub

# 安装依赖
npm install

# 开发模式运行（tsx 直接执行）
npm run dev

# 或生产模式（先编译再运行）
npm run build
npm run start:prod
```

**环境变量配置**:
| 变量 | 默认值 | 说明 |
|------|--------|------|
| `HUB_HOST` | `0.0.0.0` | 监听地址 |
| `HUB_PORT` | `8600` | 监听端口 |
| `HUB_DB` | `hub.db` | SQLite 数据库路径 |
| `HUB_AUTH` | `on` | 身份认证开关（设为 `off` 关闭） |

### 9.3 启动 Flutter 客户端

```bash
# 确保 tailscale_dart 在上级目录
cd ..
git clone https://github.com/42419/tailscale_dart.git

# 进入项目
cd tl_chat

# 获取依赖
flutter pub get

# 运行（连接设备或模拟器）
flutter run

# 构建 APK
flutter build apk --release --split-per-abi
```

### 9.4 运行模拟测试

```bash
cd hub

# 启动 Hub（auth=off）
HUB_AUTH=off npm run dev

# 另一个终端运行模拟客户端
npm run sim
```

### 9.5 客户端首次使用流程

1. 打开应用 → 显示连接配置面板
2. 填写：
   - **节点主机名**：本机在 tailnet 中的名称（如 `tl-chat-phone`）
   - **Hub 主机**：Hub 节点的 tailnet 主机名（如 `armbian`）
   - **Hub 端口**：默认 `8600`
   - **Auth key**：Tailscale 预授权密钥（首次注册必填）
3. 点击「连接」→ 自动完成 Tailscale 注册 + Hub 连接
4. 连接成功后设置自动保存，下次自动登录

### 9.6 CI/CD 构建

GitHub Actions 工作流 (`.github/workflows/release.yml`)：

- **触发方式**：推送 `v*` 标签 或 手动触发
- **构建产物**：split-per-abi APK（arm64-v8a / armeabi-v7a / x86_64）
- **流程**：
  1. 检出 tl_chat + tailscale_dart
  2. 安装 JDK 17 + Go 1.26 + Flutter 3.44.4
  3. 安装 Android NDK
  4. `flutter pub get` → `flutter analyze` → `flutter test`
  5. `flutter build apk --release --split-per-abi`
  6. 上传构建产物
  7. 标签推送时自动创建 GitHub Release

---

## 附录：设计阶段与功能演进

| 阶段 | 功能 |
|------|------|
| Phase 1.1 | 自动重连（指数退避 + 抖动） |
| Phase 1.2 | 增量同步（per-conversation seq 游标） |
| Phase 1.3 | 消息幂等性（clientMessageId 24h 去重） |
| Phase 1.4 | 离线消息队列 + 重连刷新 |
| Phase 2.1 | 输入状态指示器（3s 防抖 + 5s TTL） |
| Phase 2.2 | 群聊已读回执（max_read_seq 合并上报） |
| P3 | 群聊浏览/加入/成员列表 |
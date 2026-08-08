# TL Chat

基于 **Tailscale 内网穿透**的轻量聊天应用。应用内嵌 `tsnet`（`tailscale_dart`），
每个设备自身成为 tailnet 节点，与内网中的轻量中心服务通过加密隧道通信——
无需公网服务器、无需开放端口。

```
┌─────────────┐   Tailscale TCP 隧道    ┌──────────────────┐
│ Flutter App │ ◄──────────────────────► │  Node.js 中心服务 │
│ (内嵌 tsnet) │    自定义 JSON 帧协议     │  (node:sqlite 存储) │
└─────────────┘                          └──────────────────┘
```

## 技术栈

| 层 | 选择 |
|---|---|
| 客户端 | Flutter + **Material 3** 标准组件 |
| 状态管理 | **Riverpod**（`ChangeNotifierProvider` + `StateProvider`） |
| 本地存储 | **sqflite**（会话/消息缓存、离线队列） |
| 传输 | `tailscale`（路径依赖 `../tailscale_dart`）+ `[4 字节长度][JSON]` 帧 |
| 服务端 | **Node.js 纯 JS 零框架**，内置 `node:sqlite`（零原生依赖） |

> 服务端要求 Node ≥ 23.4（内置 SQLite）。若需在更老版本运行，可换回
> `better-sqlite3`（需原生编译环境）。

## 目录结构

```
lib/
├── main.dart / app.dart        入口与路由（未配置 → 引导页；已配置 → 主界面）
├── core/
│   ├── theme/app_theme.dart    Material 3 主题（种子色 + 深浅两套）
│   ├── settings/               连接设置持久化（Auth key 不落盘）
│   ├── models/                 ChatMessage / Conversation / 状态枚举
│   ├── db/chat_db.dart         sqflite 本地库（会话 + 消息）
│   ├── network/
│   │   ├── frame_codec.dart    帧编解码（与服务端同规范）
│   │   ├── tailscale_service.dart  tsnet 生命周期封装
│   │   └── chat_client.dart    连接/收发/心跳/重连/已读/打字/分页
│   └── providers.dart          Riverpod providers
└── features/
    ├── setup/                  首次配置引导（昵称/服务地址/Auth key）
    ├── home/                   主壳：NavigationBar + 连接 overlay/横幅
    ├── chat/                   会话列表 + 聊天页（乐观发送/历史分页）
    ├── contacts/               tailnet 在线节点通讯录
    └── settings/               外观/连接/数据管理

server/                         轻量中心服务（纯 Node.js，零依赖）
├── src/protocol.js             帧编解码（[4 字节长度][JSON]）
├── src/store.js                node:sqlite 存储（seq 分配/幂等/分页）
├── src/server.js               TCP 监听、认证、转发、离线补发、presence
├── PROTOCOL.md                 线协议完整文档
└── test/                       node:test 集成测试（6 用例）
```

## 快速开始

### 1. 服务端（跑在 tailnet 内任意常开设备上）

```bash
cd server
node src/server.js --host 0.0.0.0 --port 8600
# 可选：--db /path/to/chat.db、--dev（关闭 tailnet 地址校验，本机联调用）
```

### 2. 客户端

```bash
flutter pub get
flutter run
```

首次启动进入引导页：填写**昵称**（也是 tailnet 主机名）、**服务地址**
（服务端的主机名或 100.x 地址）、**Auth key**（首次注册必填，之后不再需要）。

## 核心设计

- **消息不丢失**：at-least-once + 客户端 `clientId` 幂等（服务端
  `(sender, client_id)` 唯一索引去重，重发安全）
- **顺序**：每会话单调递增 `seq`（服务端事务内分配），客户端按 seq 检测缺口
- **离线送达**：服务端持久化；收件人重连后 `hello` 携带每会话游标，
  服务端增量补发 `seq > 游标` 的消息
- **半开连接**：30s 心跳 ping / 15s pong 超时；指数退避 + 抖动重连（1s→30s）
- **乐观 UI**：`sending → sent → delivered → read`；15s 无 ack 转 `failed`，
  长按重发（复用原 clientId）
- **已读回执**：时间戳水位 `upToTs`，只前进不倒退
- **打字指示**：防抖发送 + 5s TTL 兜底
- **历史分页**：`beforeSeq` 游标，`ListView.builder(reverse: true)` 上滑加载

## 测试

```bash
flutter analyze        # 客户端静态分析（0 issues）
flutter test           # 客户端 widget 测试
cd server && npm test  # 服务端集成测试（node:test）
```

## 平台说明

- `tailscale_dart` 当前仅支持 POSIX（Android/Linux/macOS）；Windows 上 native
  构建会跳过，无法真实联网运行（widget 测试不受影响）。
- 服务端只接受 tailnet CGNAT 段（`100.64.0.0/10`）与回环地址的连接。

# TL Chat 线协议（v2，轻量重写）

客户端与服务端通过 Tailscale TCP 隧道通信，帧格式与帧类型定义如下。
客户端实现：`lib/core/network/frame_codec.dart`；服务端实现：`server/src/protocol.js`。

## 帧格式

```
[4 字节大端长度 N][N 字节 UTF-8 JSON]
```

帧 JSON 结构：

```json
{
  "type": "...",
  "from": "...",
  "to": "...",
  "conv": "...",
  "ts": 0,
  "payload": {}
}
```

- `type` 必填；其余字段可空。
- 单帧上限 4 MiB（防恶意超大帧）。

## 帧类型

| 方向      | type                 | 说明                                                                                                                                                                                                                |
| --------- | -------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| C→S       | `hello`              | 注册：`from` = stableNodeId，`payload.hostname` 显示名，`payload.cursors` = `{convId: lastSeq}` 增量同步游标，`payload.token` = 已配对设备的长期令牌（重连用），`payload.pairSecret` = 首次配对码（仅未注册过的 nodeId 需要，二选一，见下方“身份校验”） |
| S→C       | `ack`                | 通用应答。hello 应答：`{ok, nodeId, names, token?}`（`names` = 全量已知节点 `{nodeId: 显示名}`；`token` 仅首次配对成功时下发一次，客户端需持久化）；消息应答：`{ok, clientId, serverId, seq, conv}`；错误：`{ok: false, error}`               |
| 双向      | `ping` / `pong`      | 心跳（客户端 30s 主动 ping；服务端 15s 扫描）                                                                                                                                                                       |
| C→S       | `msg/send`           | `to` = 收件人 nodeId，`payload` = `{clientId, text, ts, forwardedFrom?}`（`forwardedFrom` = 转发来源显示名，可选；`text` 上限 8000 字符，超出/超出限流阈值会被拒绝，见下方“限流与长度限制”）                          |
| S→C       | `msg/push`           | 新消息推送（含离线补发），`payload.msg` = `{conv, sender, clientId, text, ts, serverId, seq, hostname, recalled, forwardedFrom?}`（`hostname` = 发送者显示名；`recalled` = 是否已撤回；`forwardedFrom` = 转发来源） |
| C→S       | `msg/recall`         | 撤回：`payload.id` = 要撤回消息的 `serverId`（仅本人消息可撤回）                                                                                                                                                    |
| S→C       | `msg/recalled`       | 撤回广播：发给收件人及发送者其他会话，`payload` = `{id, recalledAt}`                                                                                                                                                |
| C→S       | `msg/history`        | 历史分页：`to` = 对方 nodeId，`payload` = `{beforeSeq, limit}`（游标 = 当前最旧 seq）                                                                                                                               |
| S→C       | `msg/history_result` | `payload` = `{hasMore, messages[]}`（旧→新）                                                                                                                                                                        |
| C→S / S→C | `read`               | 已读回执：`to` = 对方，`payload.upToTs` = 读到的时间戳水位                                                                                                                                                          |
| C→S / S→C | `typing`             | 打字指示：`to` = 对方，`payload.on` = true/false                                                                                                                                                                    |
| S→C       | `presence`           | 在线名单：`payload.online` = `[{id, name}]`（连接/断开时广播）                                                                                                                                                      |
| C→S       | `bye`                | 优雅断开                                                                                                                                                                                                            |

## 消息流

1. **发送**：客户端 `msg/send` → 服务端幂等落库（`(sender, clientId)` 唯一）→ `ack` 回发送者（携带 `serverId` + `seq`）→ 收件人在线则实时 `msg/push`，离线则留待其下次 `hello` 时按游标增量补发。
2. **同步**：客户端断线重连 → `hello` 携带每会话 `lastSeq` 游标 → 服务端逐会话推送 `seq > 游标` 的离线消息。
3. **顺序**：每会话 `seq` 由服务端事务内 `MAX+1` 分配，单调递增，客户端按 seq 检测缺口。
4. **显示名**：节点 `hello` 注册时显示名**持久化落库**（`nodes` 表）——节点掉线/服务端重启后仍保留。每次 `hello` 的 `ack` 携带全量 `{nodeId: 显示名}` 映射，客户端据此在启动/重连后立刻恢复所有已知昵称；离线补发与历史分页的消息也携带发送者 `hostname`。
5. **撤回**：发送者 `msg/recall`（携带 `serverId`）→ 服务端校验归属并标记 `recalled=1` → `ack` 回发送者 + 向收件人与发送者其他设备广播 `msg/recalled`。撤回状态随消息持久化，历史/离线补发均携带 `recalled` 字段。
6. **转发**：转发消息复用 `msg/send`，`payload.forwardedFrom` 记录原发送者显示名；服务端落库并在 `msg/push` / 历史中回传。

## 身份校验（v2.1 新增，修复了严重的会话劫持漏洞）

早期版本里，`hello.from` 声明的 nodeId 服务端不做任何验证——"tailnet 链路本身加密"只保证了传输层安全，并不等于验证了应用层身份。任何能连上 tailnet 的设备都可以在 `hello` 里自报别人的 stableNodeId，接管对方会话、越权读取历史消息。现在改为配对令牌机制：

- **首次注册**（服务端从未见过这个 nodeId）：`hello.payload.pairSecret` 必须与服务端的配对码一致（启动时通过 `--pair-secret <值>` 指定，或不指定时服务端自动生成一个并打印到控制台，需要管理员告知家人/设备）。校验通过后，服务端为该 nodeId 生成一个随机长期令牌（`crypto.randomBytes(24)`），只存哈希（SHA-256）到 `node_tokens` 表，原始令牌通过 `ack.payload.token` 下发一次，客户端需要本地持久化（Flutter 客户端存在 `AppSettings.deviceToken`）。
- **后续连接**：`hello.payload.token` 必须与库里存的哈希匹配（`crypto.timingSafeEqual` 常数时间比较，防时序侧信道），否则拒绝并断开连接，**不会**顶替已在线的合法连接。
- `--dev` 模式跳过以上校验，仅用于本机联调，生产部署不要使用。
- 升级注意：这是一次破坏性变更——服务端重启后数据库里的 `nodes`/`messages` 表数据还在，但没有人有 `node_tokens` 记录，所有设备都需要重新走一次"首次注册"流程（在 App 设置里填入配对码）。

## 限流与长度限制（v2.1 新增）

- 单条消息文本上限 **8000 字符**（服务端 `MAX_TEXT_LENGTH`），客户端也会本地拦截过长文本，避免打完一大段才被拒绝。
- 每个连接每 10 秒最多 **20 条** `msg/send`（滑动窗口），超出返回 `ack {ok:false, error:'发送过于频繁，请稍后再试'}`。
- 单帧硬上限仍是 4 MiB（防恶意超大帧），与限流/长度限制是两层独立防护。

## 服务端安全

- 仅接受 tailnet CGNAT 段（`100.64.0.0/10`）与回环地址的连接；`--dev` 可关闭校验（本机联调）。这层网段校验只是纵深防御的一环，**不能单独作为身份认证**（见上方"身份校验"）；生产部署建议服务端显式绑定到本机 tailscale 100.x 地址（`--host <100.x.x.x>`）而不是 `0.0.0.0`，避免主机上其他网卡意外把端口暴露出去。
- 节点身份由配对令牌校验（见上），不再单纯信任 `hello` 自报的 stableNodeId。
- 存储：`nodes` 表持久化 `nodeId → 显示名`；`node_tokens` 表持久化 `nodeId → 令牌哈希`；`messages` 表持久化消息；`conversations` 表记录已出现的会话。
- **已知取舍（暂未实现，欢迎后续补充）**：消息在服务端和客户端本地库均为明文存储，没有做端到端加密（E2EE）——依赖 tailnet 传输层加密 + 应用层身份校验，如果服务器主机或某台设备的本地存储被拿到，聊天记录是可读的。如需加固，可在此协议之上加一层"每个 1:1 会话用双方交换的对称密钥加密 `text` 字段"。

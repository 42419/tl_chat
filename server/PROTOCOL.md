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
| C→S       | `hello`              | 注册：`from` = stableNodeId，`payload.hostname` 显示名，`payload.cursors` = `{convId: lastSeq}` 增量同步游标                                                                                                        |
| S→C       | `ack`                | 通用应答。hello 应答：`{ok, nodeId, names}`（`names` = 全量已知节点 `{nodeId: 显示名}`）；消息应答：`{ok, clientId, serverId, seq, conv}`；错误：`{ok: false, error}`                                               |
| 双向      | `ping` / `pong`      | 心跳（客户端 30s 主动 ping；服务端 15s 扫描）                                                                                                                                                                       |
| C→S       | `msg/send`           | `to` = 收件人 nodeId，`payload` = `{clientId, text, ts, forwardedFrom?}`（`forwardedFrom` = 转发来源显示名，可选）                                                                                                  |
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

## 服务端安全

- 仅接受 tailnet CGNAT 段（`100.64.0.0/10`）与回环地址的连接；`--dev` 可关闭校验（本机联调）。
- 节点身份由 hello 声明的 stableNodeId 决定（tailnet 链路本身加密，与旧版 whois 方案相比更轻）。
- 存储：`nodes` 表持久化 `nodeId → 显示名`；`messages` 表持久化消息；`conversations` 表记录已出现的会话。

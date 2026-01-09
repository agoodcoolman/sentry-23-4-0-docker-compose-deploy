# Sentry Replay（23.4.0 / 自建 Docker Compose）部署与排查指南

本指南针对你当前目录 `replay/` 下的 `docker-compose.yml`，并且以 **Sentry 23.4.0** 为基准。

你截图中的关键报错：

`Invalid value for '--consumer-type': 'replay_recordings' is not one of 'events', 'attachments', 'transactions'...`

结论：

- **Sentry 23.4.0 不支持**用 `sentry run ingest-consumer --consumer-type replay_recordings` 的方式启动 replay recordings 消费者。
- 官方 self-hosted `23.4.0` 的方式是启动一个独立服务：
  - `sentry run ingest-replay-recordings`

本仓库已将 `replay/docker-compose.yml` 修正为与官方 23.4.0 一致的启动方式。

---

## 1. 先确认：你的启动方式是否正确（与官方 23.4.0 对齐）

### 1.1 官方 23.4.0 关键服务（来自 getsentry/self-hosted 23.4.0）

- **ingest-consumer**：
  - 官方写法：`sentry run ingest-consumer --all-consumer-types`
- **ingest-replay-recordings**：
  - 官方写法：`sentry run ingest-replay-recordings`
- **snuba-replays-consumer**：
  - 官方写法：`snuba consumer --storage replays ...`

> 你当前 `replay/docker-compose.yml` 里已经包含 `snuba-consumer-replays`，并且我已把 `sentry-ingest-replay-recordings` 与 `sentry-ingest-consumer` 修正为上述写法。

### 1.2 为什么你之前的配置会起不来

你原先写的是：

- `sentry run ingest-consumer --consumer-type replay_recordings`

而在 23.4.0 里，`ingest-consumer` 的 `--consumer-type` 参数允许的值并不包含 `replay_recordings`，因此容器会直接退出。

---

## 2. 部署步骤（建议按顺序）

### 2.1 首次部署 / 迁移

如果你是首次在该目录启动（或你更换了 compose 文件），需要确保：

- `.env.custom` 存在（由 `start.sh` 初始化生成）
- 数据目录权限正确（尤其 `kafka` / `zookeeper` / `clickhouse`）

### 2.2 启动（不执行迁移）

使用 `replay/up.sh` 启动，它会加载 `.env.custom`，并在启动后按顺序重启关键服务：

- `sh up.sh`

启动完成后，重点确认以下容器状态为 `Up`：

- `sentry-web`
- `relay`
- `sentry-worker`
- `sentry-ingest-consumer`
- `sentry-ingest-replay-recordings`
- `snuba-api`
- `snuba-consumer`
- `snuba-consumer-replays`
- `kafka` / `zookeeper` / `clickhouse` / `redis` / `postgres`

---

## 3. 快速验证 Replay 链路是否工作（后端视角）

Replay 数据链路大致是：

- Browser SDK -> Relay -> Kafka topics -> ingest-replay-recordings -> 写入存储（ClickHouse/Snuba）-> UI 查询展示

### 3.1 看最关键的两个日志

1. `sentry-ingest-replay-recordings`：

- 是否还在重复报错/退出
- 是否出现消费/处理相关日志

1. `snuba-consumer-replays`：

- 是否有 `replays` storage 的消费日志

> 如果 `sentry-ingest-replay-recordings` 起不来，UI 基本不可能显示 replay。

---

## 4. 网页端不显示 Replay：按顺序排查（从最可能到最不可能）

### 4.1 先排除“后端根本没处理”

- **检查容器是否在跑**：
  - `sentry-ingest-replay-recordings` 必须是 `Up`
  - `snuba-consumer-replays` 必须是 `Up`

- **检查 kafka 是否就绪**：
  - kafka 反复重启/不可写会导致所有 consumer 假死

### 4.2 检查 Relay 是否接收到 replay envelope

Replay SDK 会向 Sentry 上报一类 envelope。

排查点：

- Relay 是否返回 200 但实际上没写入 kafka
- Relay 日志是否有明显报错（权限、认证、kafka 连接、backpressure）

### 4.3 检查 Snuba 是否能查询到 replays 数据

如果 `snuba-consumer-replays` 不消费，或者 clickhouse 写入失败，UI 会查不到。

排查点：

- `snuba-api` 健康
- clickhouse 空间/写权限正常

### 4.4 检查前端是否真的开启了 Replay（SDK 侧）

UI 不显示 replay 的常见原因不是后端，而是前端压根没录：

- 采样率为 0
- 只配置了 Sentry（errors）但没启用 replay integration

建议在前端临时设置：

- `replaysSessionSampleRate: 1.0`
- `replaysOnErrorSampleRate: 1.0`

并在页面多做几次交互后再看。

### 4.5 检查项目权限/功能入口

- 确认你是在正确的 Project 下看
- 确认左侧菜单是否显示 `Replays`
  - 如果菜单不出现，可能是版本/功能开关/权限问题

---

## 5. 必要的“最小排查命令清单”（你照着跑，贴输出我就能继续定位）

请在 `replay/` 目录执行（用你 up.sh 里检测到的 compose 命令形式）：

- 查看容器状态
  - `docker compose --env-file ./.env.custom -f docker-compose.yml ps`

- 看 replay recordings consumer 日志（重点）
  - `docker compose --env-file ./.env.custom -f docker-compose.yml logs -n 200 sentry-ingest-replay-recordings`

- 看 snuba replays consumer 日志
  - `docker compose --env-file ./.env.custom -f docker-compose.yml logs -n 200 snuba-consumer-replays`

- 看 relay 日志
  - `docker compose --env-file ./.env.custom -f docker-compose.yml logs -n 200 relay`

---

## 6. `UNKNOWN_TOPIC_OR_PART`：缺少 `ingest-replay-recordings` topic 的修复

### 6.1 现象

`sentry-ingest-replay-recordings` 报错类似：

`KafkaError{code=UNKNOWN_TOPIC_OR_PART,... str="Subscribed topic not available: ingest-replay-recordings"}`

这意味着：Kafka 里没有 `ingest-replay-recordings` 这个 topic（或 broker 还没 ready）。

### 6.2 修复（创建/补齐 topics + 触发 snuba bootstrap）

在 `replay/` 目录执行：

- `sh ensure-kafka-topics.sh`

该脚本会：

- 确保 `zookeeper` / `kafka` 已启动
- 等待 kafka ready
- 创建/补齐 replay 相关 topics（包括 `ingest-replay-recordings`）
- 执行 `snuba-api bootstrap --force`（同步创建 snuba 侧 topics + ClickHouse migrations）

### 6.3 修复后验证

- 查看 topic 是否存在：
  - `docker compose --env-file ./.env.custom -f docker-compose.yml exec -T kafka bash -lc 'kafka-topics --bootstrap-server localhost:9092 --list | grep -E "ingest-replay-recordings|ingest-replays"'`

- 重启 replay recordings consumer：
  - `docker compose --env-file ./.env.custom -f docker-compose.yml up -d --force-recreate sentry-ingest-replay-recordings`

- 观察 consumer 是否还报 UNKNOWN_TOPIC：
  - `docker compose --env-file ./.env.custom -f docker-compose.yml logs -n 200 sentry-ingest-replay-recordings`

---

## 7. relay 报错 / dropped envelope / 队列为 0：如何修复（严格对齐 self-hosted 23.4.0）

### 7.1 现象与结论

你截图里的典型错误：

- `could not send request to upstream ... /api/0/relays/register/response/ ... Connection reset by peer`
- 大量 `dropped envelope: internal error`

这类问题出现时，通常意味着：

- relay **没有成功注册**到 sentry-web（上游）
- 或 relay 处理链路不可用（如 relay 连接 redis/kafka 失败）

结果就是：

- relay 在入口处把 envelope 丢掉
- Kafka 里 replay topic 基本为 0（你看到的“队列为空”就是这个）

### 7.2 必需文件（你这套 replay 目录必须具备）

根据 self-hosted 的实现，relay 至少需要：

- `replay/relay/config.yml`
- `replay/relay/credentials.json`

你当前仓库已提供：

- `replay/relay/config.yml`
- `replay/ensure-relay-credentials.sh`（用于生成 `relay/credentials.json`）

### 7.3 生成 relay 凭据（只需要做一次）

在 `replay/` 目录执行：

- `sh ensure-relay-credentials.sh`

该脚本的原理与官方 `install/ensure-relay-credentials.sh` 一致：

- `docker compose run relay credentials generate --stdout > relay/credentials.json`

### 7.4 重建 relay 让配置生效

生成凭据后，重建 relay：

- `docker compose --env-file ./.env.custom -f docker-compose.yml up -d --force-recreate relay`

然后再看 relay 日志，确认不再出现：

- register upstream 的 connection reset
- dropped envelope

如果你 `redis` 启用了密码：

- `relay/config.yml` 里的 `processing.redis` 需要带密码
- 该项目的 `up.sh` 会把 `relay/config.yml` 中的 `${REDIS_PASSWORD}` 自动替换成 url-encode 后的值

---

## 8. 已知注意事项（23.4.0 / self-hosted）

- 官方 self-hosted 的 `23.4.0` compose 里：
  - `ingest-replay-recordings` 是独立服务 `run ingest-replay-recordings`
  - 而不是 `ingest-consumer --consumer-type replay_recordings`

如果你仍看到类似 consumer-type 不支持的报错：

- 说明容器仍在跑旧的 command（compose 未生效）
- 建议：
  - `docker compose down` 后再 `up -d`（确保重建）
  - 或 `docker compose up -d --force-recreate sentry-ingest-replay-recordings`


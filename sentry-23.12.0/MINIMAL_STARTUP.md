# Sentry Self-Hosted（最小化：Event + Tracing）启动说明

## 目标

- 仅启动 **事件（errors/event）** 与 **性能追踪（transactions/tracing）** 相关链路。
- 默认对外端口使用 **9006**（Nginx 对外）。
- 所有持久化/缓存数据尽量落在仓库根目录的 `./data/` 下。

> 说明：本仓库已包含 `docker-compose.override.yml`（主要用于 profiles 切分与资源限制）。

---

## 目录结构（需要你提前创建的宿主机目录）

在仓库根目录下创建（Windows 用资源管理器创建即可）：

- `data/`
- `data/postgres/`
- `data/redis/`
- `data/zookeeper/data/`
- `data/zookeeper/log/`
- `data/kafka/data/`
- `data/kafka/log/`
- `data/clickhouse/data/`
- `data/clickhouse/log/`
- `data/secrets/`
- `data/nginx-cache/`
- `data/sentry/`
- `data/symbolicator/`（如果你启用 `--profile full` 才需要）
- `data/vroom/`（如果你启用 `--profile full` 才需要）

以及 compose 中使用的 bind-volume 目录（已在仓库中）：

- `./sentry`（配置）
- `./nginx`（配置）
- `./relay`（配置）
- `./clickhouse`（镜像 build + config）
- `./postgres`（entrypoint 脚本）

---

## 最小启动（默认：仅 event + tracing）

在仓库根目录执行：

```bash
# 不加 --profile full，即为最小模式
# 入口对外：http://<server-ip>:9006
# （如果你设置了 SENTRY_BIND 环境变量，会覆盖默认 9006）
docker compose up -d
```

### 最小模式会启动的关键服务（大致）

- `nginx`
- `relay`
- `web`
- `worker`
- `events-consumer`
- `transactions-consumer`
- `snuba-api`
- `snuba-consumer`（errors 写入 clickhouse）
- `snuba-transactions-consumer`（transactions 写入 clickhouse）
- `snuba-replacer`
- `snuba-subscription-consumer-events`
- `snuba-subscription-consumer-transactions`
- `postgres`
- `redis`
- `memcached`
- `zookeeper`
- `kafka`
- `clickhouse`

### 被默认裁剪掉（需要时再启用）的服务

这些服务被标记为 `profiles`（例如 `full` / `metrics` / `profiling` / `issue_platform`），默认不会启动：

- `smtp`
- `cron`
- `attachments-consumer`
- `metrics-consumer` / `generic-metrics-consumer` 等 metrics 相关
- `replays/occurrence/profiling` 等相关消费者
- `vroom` / `vroom-cleanup`（profiling/occurrences 相关）
- `symbolicator` / `symbolicator-cleanup`
- `geoipupdate`

---

## 全量启动（需要更多功能时）

```bash
# 启用 full profile（例如 smtp / symbolicator / geoipupdate / cron 等）
docker compose --profile full up -d

# 启用 profiling（vroom + profiles 相关消费者）
docker compose --profile profiling up -d

# 启用 metrics（metrics 相关消费者）
docker compose --profile metrics up -d

# 启用 issue_platform（issue platform 相关消费者）
docker compose --profile issue_platform up -d
```

---

## 端口说明

- 对外入口：`nginx` 绑定 `9006`（默认）
  - compose 中为：`${SENTRY_BIND:-0.0.0.0:9006}:80`
  - 你可以通过环境变量覆盖，例如：`SENTRY_BIND=0.0.0.0:9010`

---

## 数据流动（Event / Tracing）

### 1) SDK 上报

- 你的应用（Sentry SDK）上报到：
  - `http://<server-ip>:9006/`（Nginx）
  - Nginx 反代到 `relay`

### 2) Relay 预处理

- `relay`：
  - 校验/限流/规范化
  - 将数据写入 Kafka（不同 topic 对应不同类型：errors / transactions 等）

### 3) Sentry consumers 消费 Kafka

- `events-consumer`：消费 event/error 相关 topic，写入 Sentry 的存储/索引链路（依赖 Snuba）
- `transactions-consumer`：消费 transactions（tracing）相关 topic
- `worker`：异步任务（例如后处理、发送通知、清理、聚合等，最小模式仍需要它保证基础链路完整）

### 4) Snuba 写入 ClickHouse

- `snuba-consumer`：把 errors/events 数据从 Kafka 落到 ClickHouse
- `snuba-transactions-consumer`：把 transactions 数据从 Kafka 落到 ClickHouse
- `snuba-api`：提供查询接口给 `web`（Sentry Web/API Server）

### 5) 查询展示

- 你访问 Web UI：`http://<server-ip>:9006`
- `web` 查询 PostgreSQL（项目/用户/权限等元数据）+ Snuba（事件/交易的查询）

---

## 内存限制说明（docker-compose.override.yml）

该文件使用 `mem_limit` / `cpus` 对各服务做资源限制。你如果改动这些值，建议同时关注：

- `ClickHouse`：`MAX_MEMORY_USAGE_RATIO` 与容器内存上限的关系（查询量大时需要更高内存）
- `Kafka/Zookeeper`：JVM heap（`KAFKA_HEAP_OPTS`）是否小于 `mem_limit`（避免 OOM）

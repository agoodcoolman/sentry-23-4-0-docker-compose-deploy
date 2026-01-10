# Sentry 23.12.0（Self-Hosted）部署方案（草案）

本目录用于从 0 开始搭建一个 **Sentry 23.12.0 self-hosted** 环境。

你要求：

- 以 **官方 `getsentry/self-hosted` 的 23.12.0 tag** 为基准，不“凭空编造”。
- 功能目标只需要覆盖：
  - **错误事件（Issues / Events）**
  - **页面跳转/性能（Transactions / Performance）**
  - **Session Replay（Replays）**
- **所有持久化数据都落盘到当前目录的 `./sentrydata/`**，方便整目录卸载删除。
- 启动脚本分两类：
  - `start.sh`：首次初始化（生成配置/创建数据目录/启动依赖/初始化数据库与 Snuba 等）
  - `up.sh`：日常停止后再次启动（少量顺序等待/重启，避免 race）

本 README 先给出完整的“落地方案说明”，你确认后我再开始写：

- `docker-compose.yml`（基于官方 compose 改造落盘映射与可选裁剪）
- `start.sh` / `up.sh`
- 需要的配置文件（`sentry/`、`relay/`、`nginx/` 等）

---

## 1. 上游依据（你可以核对）

以下内容来自官方仓库 `getsentry/self-hosted` 的 **`23.12.0` tag**：

- 官方 README：`getsentry/self-hosted@23.12.0/README.md`
- 官方 install 入口：`getsentry/self-hosted@23.12.0/install.sh`
- 官方 docker compose：`getsentry/self-hosted@23.12.0/docker-compose.yml`
- 官方 sentry 配置示例：`getsentry/self-hosted@23.12.0/sentry/sentry.conf.example.py`

本项目后续所有脚本/服务清单，会以这些文件为“权威来源”。

---

## 2. Windows 环境注意事项（非常关键）

官方 `install.sh` 明确提示：**Git Bash/MSYS2 不受支持，需要使用 WSL**。

因此建议：

- 在 Windows 上用 **WSL2 Ubuntu**（或 Linux 服务器）运行本目录的 `start.sh/up.sh`。
- 如果你坚持在 Windows 直接跑，很多容器内权限、文件系统语义、换行符都会导致不可控问题（尤其是 ClickHouse/Kafka 权限与性能）。

后续脚本我会保持为 **bash**，与官方 `install.sh` 的生态一致。

---

## 3. 资源需求（官方建议）

官方 README 给出的建议：

- Docker 19.03.6+
- Compose 2.0.1+
- 4 CPU Cores
- 16 GB RAM
- 20 GB Free Disk Space

你可以低配跑起来做验证，但 Kafka/ClickHouse/Snuba 对资源比较敏感，低配更容易出现：

- Snuba bootstrap / Kafka create topics 超时
- ClickHouse OOM 或查询不完整
- consumer 频繁重启

---

## 4. 目录结构（规划）

后续我会在 `sentry-23.12.0` 下组织为类似官方 self-hosted 的结构，同时加入你的脚本：

- `README.md`（本文件）
- `docker-compose.yml`（基于官方 23.12.0）
- `start.sh`（首次初始化脚本，风格参考你现有 `d:\project\sentry\start.sh`）
- `up.sh`（日常启动脚本，风格参考你现有 `d:\project\sentry\up.sh`）
- `.env`（官方默认 env；用于提供基础变量与镜像版本）
- `.env.custom`（你本机/服务器的覆盖配置；存在则官方规则为忽略 `.env`）
- `sentry/`（Sentry 配置目录，包含 `sentry.conf.py`、`config.yml` 等）
- `relay/`（Relay 配置目录，包含 `config.yml` + `credentials.json`）
- `nginx/`（nginx 配置）
- `clickhouse/`、`postgres/`、`symbolicator/`、`geoip/`、`certificates/` 等（与官方一致）
- `sentrydata/`（**本项目的唯一数据落盘根目录**）

`./sentrydata/` 会包含（初稿，后续以最终 compose 为准）：

- `./sentrydata/sentry/`（对应官方 `sentry-data:/data`）
- `./sentrydata/postgres/`
- `./sentrydata/redis/`
- `./sentrydata/zookeeper/`、`./sentrydata/zookeeper-log/`
- `./sentrydata/kafka/`、`./sentrydata/kafka-log/`
- `./sentrydata/clickhouse/`、`./sentrydata/clickhouse-log/`
- `./sentrydata/symbolicator/`
- `./sentrydata/vroom/`
- `./sentrydata/nginx-cache/`
- `./sentrydata/secrets/`
- `./sentrydata/smtp/`、`./sentrydata/smtp-log/`

你的目标是“卸载一起删”，所以后续我会避免使用 `external: true` 的 docker volume，全部改为 bind mount 到上述目录。

---

## 5. 容器/服务清单（以官方为基准整理）

> 说明：官方 compose 服务很多。你只需要错误/性能/Replay，但为了稳定起见，我建议分两阶段：
>
>- **阶段 A（建议）**：先按官方组合跑通（确保链路完整），再做裁剪。
>- **阶段 B（可选）**：在确认你确实不需要 metrics/profiling/issue-platform 后，再下线相关 consumer。

### 5.1 基础依赖（必需）

- `postgres`：主数据库（官方要求 `wal_level=logical` 等参数）
- `redis`：缓存/队列（官方默认无密码）
- `kafka` + `zookeeper`：事件流
- `clickhouse`：事件/事务/replay 等分析数据存储
- `memcached`：缓存
- `smtp`：默认提供（可保留，即使你不发邮件也不影响）

### 5.2 Snuba（必需：Errors/Transactions/Replays 都依赖）

- `snuba-api`
- `snuba-consumer`（errors 写入 ClickHouse）
- `snuba-transactions-consumer`（transactions 写入 ClickHouse）
- `snuba-replays-consumer`（replays 写入 ClickHouse）

官方还包含：

- `snuba-outcomes-consumer`
- `snuba-subscription-consumer-events`
- `snuba-subscription-consumer-transactions`
- `snuba-replacer`

这些建议先保留，后续再根据你是否用 Discover/查询订阅等功能决定裁剪。

### 5.3 Sentry 主服务（必需）

- `web`：Sentry Web/API
- `worker`：异步任务
- `cron`：定时任务（清理、聚合等）

### 5.4 Sentry Ingest Consumers（与你的目标直接相关）

- **错误事件**
  - `events-consumer`
  - `attachments-consumer`（如果你会上报 attachments，比如某些 SDK 会）
- **性能/页面跳转（Transactions）**
  - `transactions-consumer`
- **Replay**
  - `ingest-replay-recordings`

### 5.5 入口与反代（必需）

- `relay`：接收 SDK 的 envelope，上游鉴权与转发
- `nginx`：对外入口（你现有项目用 `9006`，我们会保持一致）

### 5.6 其他服务（建议先保留）

- `symbolicator` + `symbolicator-cleanup`：符号化（前端 sourcemap/原生符号等）
- `vroom` + `vroom-cleanup`：官方 compose 中 `web` 默认依赖 vroom（先保留，避免删错导致 web 起不来）
- `geoipupdate`：geoip 数据更新（可选）
- `sentry-cleanup`：事件保留清理（由 `SENTRY_EVENT_RETENTION_DAYS` 控制）

---

## 6. 你要的三条核心链路（端到端模型）

### 6.1 错误事件（Issues / Events）

浏览器/后端 SDK → `nginx` → `relay` → Kafka → `events-consumer` → Snuba → ClickHouse → Web 查询展示

关键点：

- Kafka topics 必须创建成功
- `snuba-consumer` 与 `events-consumer` 必须稳定运行

### 6.2 性能 / 页面跳转（Transactions / Performance）

SDK（tracing）→ `relay` → Kafka → `transactions-consumer` → `snuba-transactions-consumer` → ClickHouse → Performance UI

关键点：

- `transactions-consumer` 与 `snuba-transactions-consumer` 必须稳定
- 订阅 consumer（`snuba-subscription-consumer-transactions` 等）建议先保留

### 6.3 Replay

SDK（replay envelope）→ `relay` → Kafka → `ingest-replay-recordings` → `snuba-replays-consumer` → ClickHouse → Replays UI

关键点：

- Replay 相关 consumer 任意缺失都会出现“请求 200 但 UI 看不到”的现象

---

## 7. Redis 策略（先按官方，后续可加密）

你现在 `23.4.0` 的简化版是 **Redis requirepass**（并把密码写入 `.env.custom`），这是你习惯的方式。

但官方 `23.12.0` self-hosted 的 compose 默认：

- Redis **不启用密码**（`redis-cli ping` healthcheck 也是无密码）。

为了做到“严格基于官方脚本”，我建议 23.12.0 第一版先按官方默认跑通。

如果你确认要加 Redis 密码，我会再做“最小改动”：

- 修改 redis 启动参数 + healthcheck
- 确保 `sentry/sentry.conf.py` 中 redis cluster 配置同步
- 确保 Snuba 也能连接（官方 snuba env 里 `REDIS_HOST`/`REDIS_PASSWORD` 等字段需要对应）

这部分会在你确认 README 后再实施。

---

## 8. TSDB 配置差异点（先记录风险）

你现有 `23.4.0` 遇到过 TSDB 配置错误（`RedisSnubaTSDB` 不存在），因此你采用挂载 `sentry.conf.py` 固定为 `RedisTSDB`。

而官方 `23.12.0` 的 `sentry.conf.example.py` 中 TSDB 是：

- `SENTRY_TSDB = "sentry.tsdb.redissnuba.RedisSnubaTSDB"`

这属于官方配置（注意模块路径为 `redissnuba`）。

后续落地时：

- 我会 **优先保留官方配置**。
- 如果你实际启动仍出现 TSDB 报错，我们再像你 23.4.0 那样“以事实为准”做补丁（通过挂载覆盖，而不是改镜像内部文件）。

---

## 9. 启动流程设计（对齐你现在的习惯）

### 9.1 `start.sh`（首次初始化）

目标：一次性完成“从 0 到可登录”的初始化。

脚本行为（计划）：

- 生成/维护 `.env.custom`（复用你的写法：生成 secret、写入 redis 等关键参数）
- 创建 `./sentrydata/*` 全部目录
- 处理需要的权限/uid（ClickHouse/Kafka 相关目录可能需要）
- `docker compose down --remove-orphans`
- 拉起基础依赖（postgres/redis/zookeeper/kafka/clickhouse/...）
- 等待 Kafka ready，并重试创建 topic（参考你现在 `start.sh` 的 Kafka ready + CreateTopics 探针）
- 执行 Snuba bootstrap / migrations（参考官方 install：`bootstrap-snuba`、`create-kafka-topics`、`set-up-and-migrate-database`）
- 启动核心服务（web/worker/cron/consumers/relay/nginx）
- 可选：自动创建管理员（你现有脚本也支持用 env 非交互创建）

### 9.2 `up.sh`（日常启动）

目标：服务器重启或 compose down 后，**快速稳定拉起**。

计划：

- 读取 `.env.custom`
- `docker compose up -d`
- 等待一段时间后，按依赖顺序重启或探活关键 consumer（参考你现在 `up.sh` 的“按顺序重启 zookeeper/kafka/消费者”思路）

---

## 10. 端口与访问地址（规划）

保持与你现有项目一致：

- 对外：`http://<host>:9006`
- 容器内：web 使用 9006，由 nginx/relay 处理入口

---

## 11. 启动后配置流程（对齐官方 self-hosted 的使用方式）

下面流程用于“服务已启动（`start.sh` 或 `up.sh` 执行完成）”之后，把 Sentry 配置到可接入前端（错误/性能/Replay）。

### 11.1 创建管理员账号（首次）

方式 A：交互式创建（推荐）

```bash
docker compose --env-file ./.env.custom run --rm web createuser
```

方式 B：进入容器内创建

```bash
docker compose --env-file ./.env.custom exec web sentry createuser
```

创建完成后访问：

- `http://<host>:9006`

### 11.2 创建 Organization / Project

登录后：

- 创建一个 **Organization**（组织）
- 创建一个 **Project**（项目）

建议项目平台选择与你的接入一致（例如 Browser / Vue / React 等）。

### 11.3 获取 DSN

在项目页面：

- Settings -> Projects -> 你的项目 -> Client Keys (DSN)

复制 DSN（形如 `https://<publicKey>@<host>:9006/<projectId>`）。

注意：self-hosted 场景下 DSN 的 host 通常就是你的对外域名或 IP + 端口（默认 9006）。

### 11.4 前端接入（错误 + 性能 + Replay）

下面以浏览器 JS SDK 为例（框架 SDK 的核心配置一致）。

1. 安装依赖

```bash
npm i @sentry/browser @sentry/tracing @sentry/replay
```

1. 初始化（示例）

```js
import * as Sentry from "@sentry/browser";
import { BrowserTracing } from "@sentry/tracing";
import { Replay } from "@sentry/replay";

Sentry.init({
  dsn: "<你的DSN>",
  integrations: [
    new BrowserTracing(),
    new Replay(),
  ],
  tracesSampleRate: 1.0,
  replaysSessionSampleRate: 0.1,
  replaysOnErrorSampleRate: 1.0,
});
```

参数建议：

- **`tracesSampleRate`**：性能采样率，生产环境建议从 `0.01~0.2` 起。
- **`replaysSessionSampleRate`**：Replay 日常采样率。
- **`replaysOnErrorSampleRate`**：发生错误时的 Replay 采样率（通常设置更高）。

### 11.5 Replay/性能数据的后端服务检查

Replay 和性能需要对应消费者正常运行。你当前 compose 已包含：

- `ingest-replay-recordings`
- `snuba-replays-consumer`
- `snuba-transactions-consumer`
- `transactions-consumer`

快速检查：

```bash
docker compose --env-file ./.env.custom ps
docker compose --env-file ./.env.custom logs --tail=200 ingest-replay-recordings
docker compose --env-file ./.env.custom logs --tail=200 snuba-replays-consumer
docker compose --env-file ./.env.custom logs --tail=200 snuba-transactions-consumer
```

### 11.6 （可选）上传 SourceMap（前端线上可读栈）

推荐用 `getsentry/sentry-cli`（不在宿主机安装）：

```bash
docker run --rm -it \
  -e SENTRY_URL="http://<host>:9006" \
  -e SENTRY_AUTH_TOKEN="<token>" \
  -e SENTRY_ORG="<org_slug>" \
  -e SENTRY_PROJECT="<project_slug>" \
  -v "$(pwd):/work" \
  getsentry/sentry-cli:2.50.0 \
  --help
```

`SENTRY_AUTH_TOKEN` 在 Sentry UI 的 User Settings -> API Keys / Auth Tokens 中创建。

---

## 12. 精简容器（仅 Errors / Transactions / Replays）与资源限制

你当前目录下新增了 `docker-compose.override.yml`，用于在不改动主 `docker-compose.yml` 的前提下：

- 默认不启动 **Profiling** 相关服务
- 默认不启动 **Metrics** 相关服务
- 默认不启动 **Issue Platform / Occurrences** 相关服务
- 同时给核心服务加了 `mem_limit` / `cpus` 限制（适配约 200 人规模使用）

### 12.1 默认行为

`docker compose up -d` 会自动加载 `docker-compose.override.yml`，因此上述服务默认不会启动。

### 12.2 如需临时开启 Profiling / Metrics

手动带 profile 启动即可：

```bash
docker compose --env-file ./.env.custom --profile profiling --profile metrics up -d
```

仅开启某一个：

```bash
docker compose --env-file ./.env.custom --profile profiling up -d
```

```bash
docker compose --env-file ./.env.custom --profile metrics up -d
```

### 12.3 资源限制说明

资源限制写在 `docker-compose.override.yml` 里（`mem_limit` / `cpus`）。如果你机器内存较小（例如 8G 或更低），我建议你把：

- `clickhouse`、`kafka`、`web/worker` 这些服务的上限再调低一些

你把服务器的 CPU 核数和内存大小告诉我，我可以再帮你给一套更贴合的上限值。

---

## 13. 你需要我确认的点（你回复我即可）

在我开始写脚本/compose 之前，你确认以下问题，能避免后续返工：

- **Q1：是否强制 Redis 必须加密码？**
  - 如果必须，我会在“严格基于官方”前提下做最小改动；但这会涉及 Snuba/Sentry/Relay 多处对齐。
- **Q2：是否接受阶段 A 先跑“接近官方全量服务”，跑通后再裁剪？**
  - 如果你坚持一开始就裁剪，我也能做，但风险是漏一个 consumer 导致 UI 某功能缺失且排障成本更高。
- **Q3：你希望对外域名/协议是什么？（HTTP 还是 HTTPS）**
  - 如果需要 HTTPS，nginx 配置与证书目录（`./certificates`）要一起设计。

---

## 状态

- 已完成：确认 `d:\project\sentry-23.12.0` 为空目录；已读取你现有 `23.4.0` 的 `start.sh/up.sh` 结构；已获取官方 `23.12.0` 的 compose/install/README/config 示例作为基准。
- 待你确认：本 README 的方案方向与 Q1-Q3。
- 你确认后我会开始：生成 `docker-compose.yml`、`start.sh`、`up.sh`、必要的配置目录与默认配置文件，并确保全部数据映射到 `./sentrydata/`。

一个小众可以用的代理站 docker pull hub.rat.dev/tianon/exim4:latest
改名字：docker tag hub.rat.dev/tianon/exim4:latest tianon/exim4:latest

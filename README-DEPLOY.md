# Sentry 23.4.0（简化版）Docker Compose 部署说明

本仓库提供了一套用于在单机上部署 `getsentry/sentry:23.4.0` 的 `docker-compose.yml` + `start.sh`。

## 1. 前置条件

- Docker Engine（建议 20+）
- Docker Compose（`docker compose` 插件或 `docker-compose` 均可）
- 服务器至少：2C/4G（更推荐 4C/8G），磁盘按数据量预留
- 端口：对外开放 `9006`（本项目默认由 `nginx` 接管对外入口）

## 2. 目录结构与持久化数据

- `docker-compose.yml`：服务编排
- `start.sh`：初始化脚本（生成并保存 Redis 密码到 `.env.custom`，首次启动并执行 `sentry upgrade`）
- `up.sh`：后续启动脚本（读取 `.env.custom`，仅执行 `docker compose up -d`，不执行迁移）
- `README-INTEGRATION.md`：Sentry 使用与对接指南（创建项目/获取 DSN/SDK 接入/GitHub 集成要点）
- `export-images.sh`：一键把本 `docker-compose.yml` 涉及到的所有镜像 `docker save` 打包为 tar（便于离线搬运），并给出 `docker load` 恢复命令
- `sentry.conf.py`：挂载到容器 `/etc/sentry/sentry.conf.py` 的配置（用于覆盖镜像内默认配置）
- `./data/*`：各组件的持久化目录
  - `./data/postgres`
  - `./data/redis`
  - `./data/clickhouse`
  - `./data/kafka`
  - `./data/zookeeper`
  - `./data/symbolicator`

> 注意：`start.sh` 会自动创建这些目录。

## 3. 重要配置项（必须改）

### 3.1 SENTRY_SECRET_KEY

你需要把 `docker-compose.yml` 里的 `SENTRY_SECRET_KEY` 改为强随机值。

- **建议长度至少 32 位**
- **不要在公开仓库暴露**

生成示例：

```bash
openssl rand -hex 32
```

然后替换 `docker-compose.yml` 中的：

- `SENTRY_SECRET_KEY: 'please-change-me-to-a-secure-key'`

### 3.2 端口

默认：

- 宿主机：`9006`
- 容器：`nginx:80`（对外入口），`sentry-web` 仅在 docker network 内被访问

你可以按需调整 `docker-compose.yml`（nginx 的 ports）：

- `"9006:80"`

### 3.3 TSDB 配置说明（本项目的特殊点）

官方镜像内的 `/etc/sentry/sentry.conf.py` 在本版本中包含错误的 TSDB 配置：

- `SENTRY_TSDB = "sentry.tsdb.redis.RedisSnubaTSDB"`

这会导致启动报错：

- `module 'sentry.tsdb.redis' has no attribute 'RedisSnubaTSDB'`

因此本项目通过挂载 `./sentry.conf.py` 覆盖容器内的配置，并将 TSDB 固定为：

- `SENTRY_TSDB = "sentry.tsdb.redis.RedisTSDB"`

#### 3.3.1 方案B：替换镜像内错误的 sentry.conf.py（推荐）

如果你需要在服务器上“自动生成/替换”宿主机的 `./sentry.conf.py`（并用于挂载覆盖容器配置），可以按以下步骤执行。

1. 确保 `sentry-web` 容器已经创建（至少 `up -d sentry-web` 一次）
1. 从容器导出默认配置到宿主机当前目录：

```bash
docker cp sentrynew-sentry-web-1:/etc/sentry/sentry.conf.py ./sentry.conf.py
```

1. 修正错误的 TSDB 配置（把 `RedisSnubaTSDB` 替换为 `RedisTSDB`）：

```bash
sed -i 's/sentry\.tsdb\.redis\.RedisSnubaTSDB/sentry.tsdb.redis.RedisTSDB/g' ./sentry.conf.py
grep -n "SENTRY_TSDB" ./sentry.conf.py
```

1. 重建容器让挂载生效：

```bash
docker compose -f docker-compose.yml down --remove-orphans
docker compose -f docker-compose.yml up -d --force-recreate
```

1. 验证容器内最终生效配置：

```bash
docker compose -f docker-compose.yml exec -T sentry-web sh -c 'grep -n "SENTRY_TSDB" /etc/sentry/sentry.conf.py'
```

## 4. 启动与初始化

### 4.1 初始化（首次启动时执行）

在项目目录执行：

```bash
sh start.sh
```

如果你希望完全从 0 开始（危险，会清空本机数据），可以先清理：

```bash
rm -f ./.env.custom
rm -rf ./data
```

然后再执行初始化脚本：

```bash
sh start.sh
```

脚本会做这些事：

- 生成并保存关键配置到 `.env.custom`（后续启动会复用），包括：`REDIS_PASSWORD`、`SENTRY_SECRET_KEY`、`SENTRY_DB_*` 等
- `docker compose down --remove-orphans`
- 启动依赖：postgres/redis/zookeeper/kafka/clickhouse
- 启动 snuba + sentry + symbolicator
- 执行初始化迁移：`sentry upgrade --noinput`

### 4.1.1 后续启动（不执行迁移）

后续日常启动只需执行：

```bash
sh up.sh
```

### 4.1.2 修改配置如何生效（重要）

本项目把关键配置持久化在 `.env.custom` 中，`start.sh` 会在首次执行时生成/写入（后续复用）。你可以直接编辑 `.env.custom` 来修改：

- `SENTRY_SECRET_KEY`
- `SENTRY_DB_NAME` / `SENTRY_DB_USER` / `SENTRY_DB_PASSWORD`
- `SENTRY_POSTGRES_HOST`
- `SENTRY_REDIS_HOST`
- `REDIS_PASSWORD`
- `SENTRY_ADMIN_EMAIL` / `SENTRY_ADMIN_PASSWORD` / `SENTRY_ADMIN_SUPERUSER`（可选：用于自动创建管理员）

修改后让配置生效的方式：

- **仅重启（适用于只想拉起/停止容器）**：

  ```bash
  sh up.sh
  ```

  说明：`up.sh` 会加载 `.env.custom` 并执行 `docker compose up -d`。

- **重建容器（推荐，确保环境变量一定刷新）**：

  ```bash
  docker compose -f docker-compose.yml up -d --force-recreate
  ```

- **配置变更较大/需要清理依赖时**：

  ```bash
  docker compose -f docker-compose.yml down --remove-orphans
  sh up.sh
  ```

注意事项：

- **修改 `REDIS_PASSWORD`**：需要重建 `redis` 容器（并建议同时重建 sentry 相关容器），否则运行中的进程可能仍使用旧连接。
- **修改 `SENTRY_DB_PASSWORD` / `SENTRY_DB_USER` / `SENTRY_DB_NAME`**：如果你已经有历史数据（`./data/postgres`），改动可能导致无法连接或需要手工迁移/重建数据库。
- **不要随意修改 `SENTRY_SECRET_KEY`**：修改会导致现有登录会话等失效，建议只在首次部署时确定并固定。

### 4.2 创建管理员账号（首次登录必须）

Sentry 不会自动生成默认用户名密码，你需要手动创建一个管理员：

```bash
docker compose --env-file ./.env.custom -f docker-compose.yml run --rm sentry-web sentry createuser
```

按提示输入：

- email（用于登录）
- password（登录密码）
- is superuser（建议 yes）

创建完成后，用该 email/password 登录 Web。

如果你希望在服务器上“一键初始化 + 自动创建管理员（非交互）”，可以在 `.env.custom` 中提前填好：

```bash
SENTRY_ADMIN_EMAIL=admin@example.com
SENTRY_ADMIN_PASSWORD=your-strong-password
SENTRY_ADMIN_SUPERUSER=1
```

然后执行初始化脚本：

```bash
sh start.sh
```

脚本会在执行完 `sentry upgrade --noinput` 后，尝试运行：

```bash
docker compose --env-file ./.env.custom -f docker-compose.yml run --rm sentry-web sentry createuser --email admin@example.com --password your-strong-password --superuser --no-input
```

> 注意：管理员密码写入 `.env.custom` 属于明文落盘，请妥善控制权限，并确保不要提交到公开仓库。

### 4.3 忘记密码 / 重置密码

如果你忘了密码，可以在容器里重置（会进入交互）：

```bash
docker compose --env-file ./.env.custom -f docker-compose.yml run --rm sentry-web sentry changepassword <email>
```

如果你的镜像内没有该命令，退而求其次：

- 重新执行一次 `createuser` 创建新管理员

## 5. 常用运维命令

### 5.1 查看服务状态

```bash
docker compose -f docker-compose.yml ps
```

### 5.2 查看日志

```bash
docker compose -f docker-compose.yml logs -f sentry-web
```

### 5.3 停止服务

```bash
docker compose -f docker-compose.yml down
```

### 5.4 停止并删除数据（危险）

```bash
docker compose -f docker-compose.yml down -v
```

> 说明：这会删除 docker volume（如果你使用了 volume）。本项目主要使用 bind mount（`./data/*`），因此真正的数据还在 `./data/*` 目录里。

## 6. 升级与迁移

### 6.1 仅运行迁移

当你更新镜像版本或调整配置后，建议运行：

```bash
docker compose --env-file ./.env.custom -f docker-compose.yml run --rm sentry-web sentry upgrade --noinput
```

### 6.2 升级镜像（示例流程）

1. 修改 `docker-compose.yml` 中 `getsentry/sentry:23.4.0` 为目标版本
1. 拉取镜像并重建容器：

```bash
docker compose -f docker-compose.yml pull
docker compose -f docker-compose.yml up -d --force-recreate
```

1. 执行迁移：

```bash
docker compose -f docker-compose.yml run --rm sentry-web sentry upgrade --noinput
```

## 7. 数据备份（建议）

### 7.1 Postgres

```bash
docker compose -f docker-compose.yml exec -T postgres pg_dump -U sentry sentry > backup_sentry.sql
```

### 7.2 ClickHouse

ClickHouse 建议按官方方式做数据目录级别备份，至少保证：

- `./data/clickhouse` 有定期快照

## 8. 常见问题排查

### 8.1 Web 能打开但无法登录

- 需要先执行 `sentry createuser` 创建管理员

如果执行 `createuser` 时提示 `The "REDIS_PASSWORD" variable is not set`，或者报错类似：

- `AUTH <password> called without any password configured for the default user`

说明你的命令没有加载本项目生成的 `.env.custom`，导致：

- Redis 容器未启用密码（或密码为空）
- 但 Sentry 仍尝试对 Redis AUTH

按本项目方式执行：

```bash
docker compose --env-file ./.env.custom -f docker-compose.yml run --rm sentry-web sentry createuser
```

### 8.2 `sentry upgrade` 连接数据库失败（127.0.0.1）

如果日志出现类似：

- `could not connect to server: Connection refused (127.0.0.1:5432)`

说明容器内配置没有正确指向 `postgres` 服务。

本项目使用：

- `SENTRY_POSTGRES_HOST=postgres`
- `SENTRY_DB_NAME=sentry`
- `SENTRY_DB_USER=sentry`
- `SENTRY_DB_PASSWORD=sentry`

并且挂载 `./sentry.conf.py` 覆盖容器 `/etc/sentry/sentry.conf.py`。

### 8.3 Snuba / Symbolicator 一直重启

先分别看日志：

```bash
docker compose -f docker-compose.yml logs -f snuba-api
docker compose -f docker-compose.yml logs -f symbolicator
```

常见原因：

- Kafka/ClickHouse 未就绪
- 资源不足（内存/磁盘）

本项目的额外注意点（23.4.0）：

- Snuba 的 `SNUBA_SETTINGS` 需要使用 `docker`
- `snuba-api` 的 command 需要为 `api`
- `snuba-consumer` 需要指定 `--storage`（例如 `errors`）
- symbolicator 需要显式执行 `run`，否则可能只打印 help 后退出

如果你手工调整过 `docker-compose.yml`，建议与仓库保持一致，并重建：

```bash
docker compose --env-file ./.env.custom -f docker-compose.yml up -d --force-recreate snuba-api snuba-consumer symbolicator
```

### 8.4 Zookeeper / Kafka 一直重启（目录不可写）

如果日志出现：

- `dub path /var/lib/zookeeper/data writable FAILED`
- `Check if /var/lib/kafka/data is writable ... FAILED`

说明挂载的宿主机目录对容器内 `uid=1000` 不可写。先在项目目录执行：

```bash
mkdir -p ./data/zookeeper ./data/kafka
chown -R 1000:1000 ./data/zookeeper ./data/kafka
chmod -R u+rwX,g+rwX,o-rwx ./data/zookeeper ./data/kafka
```

然后重建：

```bash
docker compose --env-file ./.env.custom -f docker-compose.yml up -d --force-recreate zookeeper kafka
```

### 8.5 Kafka 报 InconsistentClusterIdException

如果 Kafka 日志出现：

- `InconsistentClusterIdException: The Cluster ID ... doesn't match stored clusterId ... in meta.properties`

表示 Zookeeper 中的 cluster.id 与 `./data/kafka/meta.properties` 中的不一致（常见于只清了一部分 data 目录）。

从 0 开始部署时（允许清数据），可以按以下方式修复：

```bash
docker compose --env-file ./.env.custom -f docker-compose.yml stop kafka zookeeper
rm -f ./data/kafka/meta.properties
docker compose --env-file ./.env.custom -f docker-compose.yml up -d zookeeper kafka
```

如果仍不行，再彻底清理（会删除 Kafka/Zookeeper 数据）：

```bash
docker compose --env-file ./.env.custom -f docker-compose.yml stop kafka zookeeper
rm -rf ./data/kafka/* ./data/zookeeper/*
docker compose --env-file ./.env.custom -f docker-compose.yml up -d zookeeper kafka
```

### 8.6 Snuba 连接 Redis 失败（127.0.0.1:6379）

典型报错：

- `redis.exceptions.ConnectionError: Error 111 connecting to 127.0.0.1:6379. Connection refused`

原因：

- Snuba 在 `SNUBA_SETTINGS=docker` 场景下，如果没有显式传 `REDIS_HOST`，会默认连容器内 `127.0.0.1`。

解决方案：

- 确保 `docker-compose.yml` 中 `snuba-api`、`snuba-consumer` 都设置：
  - `REDIS_HOST=redis`
  - `REDIS_PORT=6379`
  - `REDIS_PASSWORD=${REDIS_PASSWORD}`
  - `REDIS_DB=1`

### 8.7 Snuba bootstrap 报 `snuba.py` 不存在

典型报错：

- `FileNotFoundError: ... /usr/src/snuba/snuba/cli/snuba.py`

原因：

- `snuba-api` 镜像入口本身就是 `snuba`，如果命令写成 `... run snuba-api snuba bootstrap ...` 会变成 `snuba snuba bootstrap`。

解决方案：

- 使用下面的写法（不要重复写 `snuba`）：

```bash
docker compose --env-file ./.env.custom -f docker-compose.yml run --rm snuba-api bootstrap --force --bootstrap-server kafka:9092
```

### 8.8 Snuba consumer 报 Kafka topic 不存在（UNKNOWN_TOPIC_OR_PART）

典型报错：

- `Subscribed topic not available: events: Broker: Unknown topic or partition`

原因：

- Kafka topics 未创建（首次部署未执行 Snuba bootstrap）。

解决方案：

1. 确认 Kafka 就绪：

   ```bash
   docker compose --env-file ./.env.custom -f docker-compose.yml exec -T kafka bash -lc 'kafka-broker-api-versions --bootstrap-server localhost:9092 >/dev/null && echo OK'
   ```

1. 执行 Snuba bootstrap（创建 topics + ClickHouse migrations）：

   ```bash
   docker compose --env-file ./.env.custom -f docker-compose.yml run --rm snuba-api bootstrap --force --bootstrap-server kafka:9092
   ```

1. 验证 topic：

   ```bash
   docker compose --env-file ./.env.custom -f docker-compose.yml exec kafka bash -lc 'kafka-topics --bootstrap-server kafka:9092 --describe --topic events'
   ```

备注：

- 如果 `Creating Kafka topics...` 阶段出现 `Timed out CreateTopicsRequest in flight (after 1001ms)`，通常是 Kafka 刚启动还未完全 ready，等待 10~30 秒后重试即可。
- 本仓库的 `start.sh` 已内置 Kafka ready 检测 + bootstrap 重试。

### 8.9 Sentry Web 报 Snuba 连接失败（127.0.0.1:1218 Connection refused）

典型报错：

- `HTTPConnectionPool(host='127.0.0.1', port=1218): Failed to establish a new connection: [Errno 111] Connection refused`

原因：

- Sentry 23.4.0 默认从环境变量 `SNUBA` 读取 Snuba 地址，默认为 `http://127.0.0.1:1218`。

解决方案：

- 在 `docker-compose.yml` 中为 `sentry-web`、`sentry-worker` 显式设置：

  - `SNUBA=http://snuba-api:1218`

- 修改后重建容器让环境变量生效：

```bash
docker compose --env-file ./.env.custom -f docker-compose.yml up -d --force-recreate sentry-web sentry-worker
```

### 8.10 手工执行命令提示 `REDIS_PASSWORD variable is not set`

原因：

- 你在手工运行 `docker compose` / `docker-compose` 命令时，没有加载本项目生成的 `.env.custom`。

解决方案：

- 统一使用：

```bash
docker compose --env-file ./.env.custom -f docker-compose.yml <command>
```

### 8.11 Snuba bootstrap 报 Kafka `_TIMED_OUT`，但服务实际正常

现象：

- 执行 `snuba-api bootstrap` 时出现类似报错：
  - `cimpl.KafkaException: KafkaError{code=_TIMED_OUT,..."Failed while waiting for response from broker"}`
- 但 `docker ps` 看起来容器都在跑，Sentry Web UI 也能访问。

原因（常见）：

- 低资源/启动抖动时，Kafka 对 `CreateTopics` 请求响应变慢，Snuba 的 AdminClient 超时。
- 该超时可能发生在“创建 topics 的过程中/尾部”，并不一定代表 topics 没创建成功。

如何判断是否可以忽略：

1. Kafka topic 已存在（至少应包含 `events`/`transactions`/`snuba-commit-log` 等）：

   ```bash
   docker compose --env-file ./.env.custom -f docker-compose.yml exec -T kafka \
     bash -lc 'kafka-topics --bootstrap-server localhost:9092 --list | egrep "^(events|transactions|snuba-commit-log)$"'
   ```

2. Snuba consumer 正常消费（能看到分区分配，且不再持续刷 Kafka/UNKNOWN_TOPIC 错误）：

   ```bash
   docker compose --env-file ./.env.custom -f docker-compose.yml logs --tail=200 snuba-consumer \
     | egrep -i "assigned|unknown topic|fail|error|kafka" || true
   ```

3. Sentry Web UI 可访问（例如 `9006` 返回 302/200 均可）：

   ```bash
   curl -I http://127.0.0.1:9006/
   ```

满足以上 3 点，一般可以先继续（尤其是你已经能正常进入 Web UI、Kafka topics 也齐全的情况）。

什么时候需要补救（必须处理）：

- `snuba-consumer` 持续报：
  - `UNKNOWN_TOPIC_OR_PART` / `Subscribed topic not available` / `Name or service not known` / `Connection refused`
- Kafka `--list` 看不到关键 topics（如 `events`/`transactions`/`snuba-commit-log`）。
- Sentry 侧一直 ingest 不进来（前端报 502/relay 报错、Snuba consumer 无分区分配）。

补救方式 A：重跑 Snuba bootstrap（推荐优先尝试）

```bash
docker compose --env-file ./.env.custom -f docker-compose.yml run --rm snuba-api bootstrap --force --bootstrap-server kafka:9092
```

补救方式 B：手动创建关键 topics（bootstrap 仍不稳定时使用）

```bash
docker compose --env-file ./.env.custom -f docker-compose.yml exec -T kafka bash -lc \
  'for t in events transactions snuba-commit-log event-replacements outcomes; do \
     kafka-topics --bootstrap-server localhost:9092 --create --if-not-exists --topic "$t" --partitions 1 --replication-factor 1; \
   done'
```

然后再重跑一次 bootstrap，让其补齐剩余 topics + 执行 ClickHouse migrations：

```bash
docker compose --env-file ./.env.custom -f docker-compose.yml run --rm snuba-api bootstrap --force --bootstrap-server kafka:9092
```

补充：snuba-api 容器没有 `curl` 如何做健康检查

```bash
docker compose --env-file ./.env.custom -f docker-compose.yml exec -T snuba-api \
  python -c "import urllib.request; print(urllib.request.urlopen('http://127.0.0.1:1218/health').read().decode())"
```

## 9. 访问地址

- Web UI: `http://<server-ip>:9006`


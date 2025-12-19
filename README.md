# Sentry 23.4.0（简化版）Docker Compose 部署说明

本仓库提供了一套用于在单机上部署 `getsentry/sentry:23.4.0` 的 `docker-compose.yml` + `start.sh`。

## 1. 前置条件

- Docker Engine（建议 20+）
- Docker Compose（`docker compose` 插件或 `docker-compose` 均可）
- 服务器至少：2C/4G（更推荐 4C/8G），磁盘按数据量预留
- 端口：对外开放 `9006`（本项目默认把容器 9000 映射到宿主机 9006）

## 2. 目录结构与持久化数据

- `docker-compose.yml`：服务编排
- `start.sh`：初始化脚本（生成并保存关键配置到 `.env.custom`，首次启动并执行 `sentry upgrade`）
- `up.sh`：后续启动脚本（读取 `.env.custom`，仅执行 `docker compose up -d`，不执行迁移）
- `README-INTEGRATION.md`：Sentry 使用与对接指南（创建项目/获取 DSN/前端与后端 SDK 接入/GitHub 集成要点）
- `export-images.sh`：一键把本 `docker-compose.yml` 涉及到的所有镜像 `docker save` 打包为 tar（便于离线搬运），并给出 `docker load` 恢复命令
- `sentry.conf.py`：挂载到容器 `/etc/sentry/sentry.conf.py` 的配置（用于覆盖镜像内默认配置，并支持从 `SENTRY_REDIS_PASSWORD` 读取 Redis 密码）
- `./data/*`：各组件的持久化目录
  - `./data/postgres`
  - `./data/redis`
  - `./data/clickhouse`
  - `./data/kafka`
  - `./data/zookeeper`
  - `./data/symbolicator`

> 注意：
>
>- `start.sh` 会自动创建 `./data/*` 目录。
>- `.env.custom` 是本地保存的运行参数（包含 `REDIS_PASSWORD`、`SENTRY_SECRET_KEY`、`SENTRY_DB_*` 等；如你启用自动创建管理员，还可能包含管理员账号密码），请不要提交到公开仓库。

## 3. 重要配置项（必须改）

### 3.1 SENTRY_SECRET_KEY

本项目会在首次执行 `start.sh` 时自动生成并写入 `.env.custom` 中的 `SENTRY_SECRET_KEY`。

你也可以手动编辑 `.env.custom` 覆盖：

- **建议长度至少 32 位**
- **不要在公开仓库暴露**

生成示例：

```bash
openssl rand -hex 32
```

然后把 `.env.custom` 里的 `SENTRY_SECRET_KEY` 改成该值。

### 3.2 端口

默认：

- 宿主机：`9006`
- 容器：`9000`

你可以按需调整 `docker-compose.yml`：

- `"9006:9000"`

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
sed -i 's/sentry\\.tsdb\\.redis\\.RedisSnubaTSDB/sentry.tsdb.redis.RedisTSDB/g' ./sentry.conf.py
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

本项目把关键配置持久化在 `.env.custom` 中。你可以直接编辑 `.env.custom` 来修改：

- `SENTRY_SECRET_KEY`
- `SENTRY_DB_NAME` / `SENTRY_DB_USER` / `SENTRY_DB_PASSWORD`
- `SENTRY_POSTGRES_HOST`
- `SENTRY_REDIS_HOST`
- `REDIS_PASSWORD`
- `SENTRY_ADMIN_EMAIL` / `SENTRY_ADMIN_PASSWORD` / `SENTRY_ADMIN_SUPERUSER`（可选：用于自动创建管理员）

修改后让配置生效的方式：

- **仅启动/拉起服务**（适用于容器已存在，只是停止了）：

  ```bash
  sh up.sh
  ```

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
docker compose -f docker-compose.yml run --rm sentry-web sentry createuser
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
docker compose -f docker-compose.yml run --rm sentry-web sentry createuser --email admin@example.com --password your-strong-password --superuser --no-input
```

> 注意：管理员密码写入 `.env.custom` 属于明文落盘，请妥善控制权限，并确保不要提交到公开仓库。

### 4.3 忘记密码 / 重置密码

如果你忘了密码，可以在容器里重置（会进入交互）：

```bash
docker compose -f docker-compose.yml run --rm sentry-web sentry changepassword <email>
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
docker compose -f docker-compose.yml run --rm sentry-web sentry upgrade --noinput
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

## 9. 访问地址

- Web UI: `http://<server-ip>:9006`

# Sentry 23.4.0（简化版）补充：Relay + Nginx（9006）与 Kafka 目录权限修复

> 目标：继续使用 `9006` 对外访问 Sentry UI，同时让 SDK 的 `/api/<project_id>/envelope/` 不再落到 `sentry-web`（Django）触发 CSRF，而是通过 `nginx -> relay -> sentry-web` 的链路处理。

---

## 1. 你会看到的现象（为什么要改）

当你把 DSN 指向 `http://192.168.3.153:9006/<project_id>` 且 `9006` 直连 `sentry-web` 时，envelope 会命中 Django 路由，出现：

- `Forbidden (CSRF cookie not set.): /api/<id>/envelope/`

这是因为 **envelope ingest 不应该直接打到 sentry-web**。

---

## 2. 本次改动内容（你直接复制即可）

### 2.1 docker-compose.yml 改动点

- 新增 `relay` 服务
- 新增 `nginx` 服务，并把宿主机 `9006` 暴露到 `nginx:80`
- 移除 `sentry-web` 的对外端口暴露（仅在 docker network 内被访问）

> 你已经在 workspace 里看到对应改动，直接把更新后的 `docker-compose.yml` 复制到服务器即可。

### 2.2 新增 Nginx 配置

把下面文件放到与 `docker-compose.yml` 同级目录：

- `./nginx/nginx.conf`

关键路由：

- `^/api/[0-9]+/(envelope|store)/` -> 转发到 `relay:3000`
- 其它请求 -> 转发到 `sentry-web:9000`

### 2.3 新增 Relay 配置

把下面文件放到与 `docker-compose.yml` 同级目录：

- `./relay/config.yml`

当前使用：

- `relay.mode: managed`
- `upstream: http://sentry-web:9000/`
- `relay.credentials: /work/.relay/credentials.json`

同时需要在宿主机生成：

- `./relay/credentials.json`

---

## 3. 在 192.168.3.153 上的执行步骤（按顺序）

> 在服务器上进入存放 `docker-compose.yml` 的目录执行。

### 3.1 修复 Kafka 数据目录权限（必须先做）

Kafka 容器里常用 `uid=1000` 写入 `/var/lib/kafka/data`，而你使用了目录挂载：

- `./data/kafka:/var/lib/kafka/data`

在服务器执行：

```bash
set -e
mkdir -p ./data/kafka

# 让容器内 uid=1000 能写（如果你服务器是 root 执行，通常没问题）
chown -R 1000:1000 ./data/kafka
chmod -R u+rwX,g+rwX,o-rwx ./data/kafka

# 保险：把其它 data 目录也一起修一下（可选，但推荐）
for d in postgres redis clickhouse zookeeper symbolicator; do
  mkdir -p "./data/$d"
  chown -R 1000:1000 "./data/$d" || true
  chmod -R u+rwX,g+rwX,o-rwx "./data/$d" || true
done
```

> 如果你的宿主机不是 Linux（例如目录来自 SMB/NFS/Windows 共享盘），`chown` 可能不生效，这种情况下建议改用 docker volume（但你当前要求继续用主机映射，所以先按上面尝试）。

### 3.2 创建 relay/nginx 配置目录

```bash
mkdir -p ./nginx ./relay
```

把以下文件内容复制到对应路径：

- `./nginx/nginx.conf`
- `./relay/config.yml`

（workspace 已经生成了这两个文件，你复制过去即可。）

### 3.3 重建并启动

```bash
docker compose -f docker-compose.yml down --remove-orphans

# 启动
sh start.sh

# 如果你不想跑 start.sh（不跑迁移），则：
# sh up.sh
```

### 3.4 手动创建 relay/credentials.json（如 start.sh 未自动生成）

> 注意：不要直接用 `> ./relay/credentials.json` 重定向写入同一个文件。
> 因为 shell 会先创建/清空文件，relay 会读取到空文件并报：`could not parse json config file ... EOF`。

推荐使用临时文件再移动：

```bash
rm -f ./relay/credentials.json ./relay/credentials.json.tmp
docker compose --env-file ./.env.custom -f docker-compose.yml pull relay
docker compose --env-file ./.env.custom -f docker-compose.yml run --rm --no-deps -T relay \
  credentials generate --stdout > ./relay/credentials.json.tmp \
  && mv ./relay/credentials.json.tmp ./relay/credentials.json
```

---

## 4. 验证方式

### 4.1 验证 9006 是否由 Nginx 接管

打开：

- `http://192.168.3.153:9006/`

应该能正常看到 UI。

### 4.2 验证 envelope 不再 403

观察日志：

```bash
docker compose -f docker-compose.yml logs -f nginx
```

同时在你前端触发一次报错（或 `Sentry.captureException(new Error(...))`），你应该看到：

- nginx 对 `/api/<id>/envelope/` 的访问不再返回 `CSRF Verification Failed` 页面

并且 Sentry UI 的 **Issues** 中出现新事件。

---

## 5. 你前端/后端接入要点

- DSN 继续使用：`http://<public_key>@192.168.3.153:9006/<project_id>`
- 如果你还使用了 `tunnel`（你后端的转发接口），则：
  - `tunnel` 的 upstream 也应该指向 `http://192.168.3.153:9006`（现在是 nginx 入口）

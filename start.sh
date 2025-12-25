#!/usr/bin/env bash

if [ -z "${BASH_VERSION:-}" ]; then
  exec bash "$0" "$@"
fi

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

COMPOSE_FILE="docker-compose.yml"
ENV_FILE=".env.custom"

DEFAULT_POSTGRES_HOST="postgres"
DEFAULT_POSTGRES_DB="sentry"
DEFAULT_POSTGRES_USER="sentry"
DEFAULT_POSTGRES_PASSWORD="sentry"
DEFAULT_REDIS_HOST="redis"
DEFAULT_ADMIN_SUPERUSER="1"

generate_secret() {
  if command -v openssl &>/dev/null; then
    openssl rand -hex 24
    return 0
  fi
  if command -v python &>/dev/null; then
    python -c "import secrets; print(secrets.token_hex(24))"
    return 0
  fi
  if command -v python3 &>/dev/null; then
    python3 -c "import secrets; print(secrets.token_hex(24))"
    return 0
  fi
  date +%s
}

upsert_env_kv() {
  local k="$1"
  local v="$2"

  local tmp="${ENV_FILE}.tmp"
  local line
  line="${k}=$(printf '%q' "$v")"

  if [[ -f "$ENV_FILE" ]]; then
    grep -v -e "^${k}=" "$ENV_FILE" > "$tmp" || true
    printf '%s\n' "$line" >> "$tmp"
  else
    printf '%s\n' "$line" > "$tmp"
  fi

  mv "$tmp" "$ENV_FILE"
}

ensure_env_file() {
  if [[ -f "$ENV_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$ENV_FILE" || true
  fi

  SENTRY_POSTGRES_HOST="${SENTRY_POSTGRES_HOST:-$DEFAULT_POSTGRES_HOST}"
  SENTRY_DB_NAME="${SENTRY_DB_NAME:-$DEFAULT_POSTGRES_DB}"
  SENTRY_DB_USER="${SENTRY_DB_USER:-$DEFAULT_POSTGRES_USER}"
  SENTRY_DB_PASSWORD="${SENTRY_DB_PASSWORD:-$DEFAULT_POSTGRES_PASSWORD}"
  SENTRY_REDIS_HOST="${SENTRY_REDIS_HOST:-$DEFAULT_REDIS_HOST}"
  SENTRY_ADMIN_SUPERUSER="${SENTRY_ADMIN_SUPERUSER:-$DEFAULT_ADMIN_SUPERUSER}"

  if [[ -z "${REDIS_PASSWORD:-}" || "${REDIS_PASSWORD:-}" == "please-change-me" ]]; then
    REDIS_PASSWORD="$(generate_secret)"
  fi

  if [[ -z "${SENTRY_SECRET_KEY:-}" || "${SENTRY_SECRET_KEY:-}" == "please-change-me-to-a-secure-key" ]]; then
    SENTRY_SECRET_KEY="$(generate_secret)"
  fi

  upsert_env_kv "SENTRY_POSTGRES_HOST" "$SENTRY_POSTGRES_HOST"
  upsert_env_kv "SENTRY_DB_NAME" "$SENTRY_DB_NAME"
  upsert_env_kv "SENTRY_DB_USER" "$SENTRY_DB_USER"
  upsert_env_kv "SENTRY_DB_PASSWORD" "$SENTRY_DB_PASSWORD"
  upsert_env_kv "SENTRY_REDIS_HOST" "$SENTRY_REDIS_HOST"
  upsert_env_kv "REDIS_PASSWORD" "$REDIS_PASSWORD"
  upsert_env_kv "SENTRY_SECRET_KEY" "$SENTRY_SECRET_KEY"

  if [[ -n "${SENTRY_ADMIN_EMAIL:-}" ]]; then
    upsert_env_kv "SENTRY_ADMIN_EMAIL" "$SENTRY_ADMIN_EMAIL"
  fi
  if [[ -n "${SENTRY_ADMIN_PASSWORD:-}" ]]; then
    upsert_env_kv "SENTRY_ADMIN_PASSWORD" "$SENTRY_ADMIN_PASSWORD"
  fi
  if [[ -n "${SENTRY_ADMIN_SUPERUSER:-}" ]]; then
    upsert_env_kv "SENTRY_ADMIN_SUPERUSER" "$SENTRY_ADMIN_SUPERUSER"
  fi

  export SENTRY_POSTGRES_HOST SENTRY_DB_NAME SENTRY_DB_USER SENTRY_DB_PASSWORD SENTRY_REDIS_HOST REDIS_PASSWORD SENTRY_SECRET_KEY SENTRY_ADMIN_EMAIL SENTRY_ADMIN_PASSWORD SENTRY_ADMIN_SUPERUSER
}

if command -v docker &>/dev/null && docker compose version &>/dev/null; then
  DC="docker compose --env-file ./.env.custom"
elif command -v docker-compose &>/dev/null; then
  DC="docker-compose --env-file ./.env.custom"
else
  echo "未检测到 docker compose，请先安装 Docker Compose 或使用 Docker Desktop。"
  exit 1
fi

echo "0) 初始化环境变量..."
ensure_env_file
echo "已写入/复用 $ENV_FILE（REDIS_PASSWORD 已设置）"

echo "1) 停止并移除旧容器（包含孤儿）..."
$DC -f "${COMPOSE_FILE}" down --remove-orphans || true

echo "准备数据目录..."
mkdir -p ./data/postgres ./data/redis ./data/clickhouse ./data/kafka ./data/zookeeper ./data/symbolicator

chown -R 1000:1000 ./data/zookeeper 2>/dev/null || true
chmod -R u+rwX,g+rwX,o-rwx ./data/zookeeper || true

chown -R 1000:1000 ./data/kafka 2>/dev/null || true
chmod -R u+rwX,g+rwX,o-rwx ./data/kafka || true

echo "准备 Relay/Nginx 配置目录..."
mkdir -p ./nginx ./relay

if [[ ! -f "./nginx/nginx.conf" ]]; then
  echo "缺少 ./nginx/nginx.conf，请先创建该文件（用于 9006 入口反代）。"
  exit 1
fi

if [[ ! -f "./relay/config.yml" ]]; then
  echo "缺少 ./relay/config.yml，请先创建该文件（用于 Relay 配置）。"
  exit 1
fi

echo "2) 启动依赖服务（后台）: postgres redis zookeeper kafka clickhouse"
$DC -f "${COMPOSE_FILE}" up -d postgres redis zookeeper kafka clickhouse

echo "等待 Postgres/Redis 等服务就绪（约 10-60s）..."
sleep 20

echo "等待 Kafka 就绪（创建 topic 需要 controller ready）..."
KAFKA_READY=0
for i in $(seq 1 60); do
  if $DC -f "${COMPOSE_FILE}" exec -T kafka bash -lc 'kafka-broker-api-versions --bootstrap-server localhost:9092 >/dev/null 2>&1'; then
    KAFKA_READY=1
    break
  fi
  sleep 2
done

if [[ "$KAFKA_READY" != "1" ]]; then
  echo "Kafka 在预期时间内未就绪，请检查 kafka/zookeeper 日志。"
  exit 1
fi

echo "3) 初始化 Snuba（创建 Kafka topics + ClickHouse migrations）..."
BOOTSTRAP_OK=0
for i in $(seq 1 10); do
  if $DC -f "${COMPOSE_FILE}" run --rm snuba-api bootstrap --force --bootstrap-server kafka:9092; then
    BOOTSTRAP_OK=1
    break
  fi
  echo "Snuba bootstrap 失败，等待 10s 后重试（${i}/10）..."
  sleep 10
done

if [[ "$BOOTSTRAP_OK" != "1" ]]; then
  echo "Snuba bootstrap 多次失败：Kafka topics 可能未创建，Snuba consumer 会持续报 UNKNOWN_TOPIC_OR_PART。"
  echo "请优先检查 kafka 日志是否有权限/磁盘/clusterId 问题。"
  exit 1
fi

echo "4) 启动 Snuba 与 Sentry 服务（后台），并拉起 Relay/Nginx 入口..."
$DC -f "${COMPOSE_FILE}" up -d snuba-api snuba-consumer symbolicator sentry-web sentry-worker relay nginx

echo "等待服务稳定（10s）..."
sleep 10

echo "5) 运行 Sentry migrations (sentry upgrade)..."
# 明确覆盖 SENTRY_DB_HOST 与 SENTRY_TSDB，防止运行时被覆盖或 race
$DC -f "${COMPOSE_FILE}" run --rm \
  -e SENTRY_POSTGRES_HOST="$SENTRY_POSTGRES_HOST" \
  -e SENTRY_DB_NAME="$SENTRY_DB_NAME" \
  -e SENTRY_DB_USER="$SENTRY_DB_USER" \
  -e SENTRY_DB_PASSWORD="$SENTRY_DB_PASSWORD" \
  -e SENTRY_REDIS_HOST="$SENTRY_REDIS_HOST" \
  -e SENTRY_REDIS_PASSWORD="$REDIS_PASSWORD" \
  -e SENTRY_SECRET_KEY="$SENTRY_SECRET_KEY" \
  sentry-web sentry upgrade --noinput

if [[ -n "${SENTRY_ADMIN_EMAIL:-}" ]]; then
  echo ""
  echo "6) 尝试创建管理员账号（如已存在会跳过/提示）..."

  SUPERUSER_FLAG="--superuser"
  if [[ "${SENTRY_ADMIN_SUPERUSER:-}" != "1" && "${SENTRY_ADMIN_SUPERUSER:-}" != "true" && "${SENTRY_ADMIN_SUPERUSER:-}" != "yes" ]]; then
    SUPERUSER_FLAG="--no-superuser"
  fi

  set +e
  if [[ -n "${SENTRY_ADMIN_PASSWORD:-}" ]]; then
    $DC -f "${COMPOSE_FILE}" run --rm \
      -e SENTRY_POSTGRES_HOST="$SENTRY_POSTGRES_HOST" \
      -e SENTRY_DB_NAME="$SENTRY_DB_NAME" \
      -e SENTRY_DB_USER="$SENTRY_DB_USER" \
      -e SENTRY_DB_PASSWORD="$SENTRY_DB_PASSWORD" \
      -e SENTRY_REDIS_HOST="$SENTRY_REDIS_HOST" \
      -e SENTRY_REDIS_PASSWORD="$REDIS_PASSWORD" \
      -e SENTRY_SECRET_KEY="$SENTRY_SECRET_KEY" \
      sentry-web sentry createuser --email "$SENTRY_ADMIN_EMAIL" --password "$SENTRY_ADMIN_PASSWORD" "$SUPERUSER_FLAG" --no-input
  else
    $DC -f "${COMPOSE_FILE}" run --rm \
      -e SENTRY_POSTGRES_HOST="$SENTRY_POSTGRES_HOST" \
      -e SENTRY_DB_NAME="$SENTRY_DB_NAME" \
      -e SENTRY_DB_USER="$SENTRY_DB_USER" \
      -e SENTRY_DB_PASSWORD="$SENTRY_DB_PASSWORD" \
      -e SENTRY_REDIS_HOST="$SENTRY_REDIS_HOST" \
      -e SENTRY_REDIS_PASSWORD="$REDIS_PASSWORD" \
      -e SENTRY_SECRET_KEY="$SENTRY_SECRET_KEY" \
      sentry-web sentry createuser --email "$SENTRY_ADMIN_EMAIL" --no-password "$SUPERUSER_FLAG" --no-input
  fi
  rc=$?
  set -e
  if [[ $rc -ne 0 ]]; then
    echo "管理员创建可能已存在或创建失败（退出码：$rc）。你可以手动执行："
    echo "  $DC -f ${COMPOSE_FILE} run --rm sentry-web sentry createuser"
  fi
fi

echo
echo "若需创建管理员："
echo "  $DC -f ${COMPOSE_FILE} run --rm sentry-web sentry createuser"
echo
echo "Web UI: http://localhost:9006"
echo "查看日志： $DC -f ${COMPOSE_FILE} logs -f nginx"
echo "停止并清理数据： $DC -f ${COMPOSE_FILE} down -v"

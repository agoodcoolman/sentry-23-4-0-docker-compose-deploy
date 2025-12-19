#!/usr/bin/env bash
set -euo pipefail

COMPOSE_FILE="docker-compose.yml"
ENV_FILE=".env.custom"

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

ensure_env_file() {
  if [[ -f "$ENV_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$ENV_FILE" || true
  fi

  if [[ -z "${REDIS_PASSWORD:-}" || "${REDIS_PASSWORD:-}" == "please-change-me" ]]; then
    REDIS_PASSWORD="$(generate_secret)"
  fi
  export REDIS_PASSWORD

  tmp="${ENV_FILE}.tmp"
  if [[ -f "$ENV_FILE" ]]; then
    awk -v v="$REDIS_PASSWORD" 'BEGIN{found=0} /^REDIS_PASSWORD=/{print "REDIS_PASSWORD="v; found=1; next} {print} END{if(!found) print "REDIS_PASSWORD="v}' "$ENV_FILE" > "$tmp"
  else
    echo "REDIS_PASSWORD=$REDIS_PASSWORD" > "$tmp"
  fi
  mv "$tmp" "$ENV_FILE"
}

if command -v docker &>/dev/null && docker compose version &>/dev/null; then
  DC="docker compose"
elif command -v docker-compose &>/dev/null; then
  DC="docker-compose"
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

echo "2) 启动依赖服务（后台）: postgres redis zookeeper kafka clickhouse"
$DC -f "${COMPOSE_FILE}" up -d postgres redis zookeeper kafka clickhouse

echo "等待 Postgres/Redis 等服务就绪（约 10-60s）..."
sleep 20

echo "3) 启动 Snuba 与 Sentry 服务（后台）..."
$DC -f "${COMPOSE_FILE}" up -d snuba-api snuba-consumer symbolicator sentry-web sentry-worker

echo "等待服务稳定（10s）..."
sleep 10

echo "4) 运行 Sentry migrations (sentry upgrade)..."
# 明确覆盖 SENTRY_DB_HOST 与 SENTRY_TSDB，防止运行时被覆盖或 race
$DC -f "${COMPOSE_FILE}" run --rm -e SENTRY_POSTGRES_HOST=postgres -e SENTRY_DB_NAME=sentry -e SENTRY_DB_USER=sentry -e SENTRY_DB_PASSWORD=sentry -e SENTRY_REDIS_PASSWORD="$REDIS_PASSWORD" sentry-web sentry upgrade --noinput

echo
echo "若需创建管理员："
echo "  $DC -f ${COMPOSE_FILE} run --rm sentry-web sentry createuser"
echo
echo "Web UI: http://localhost:9006"
echo "查看日志： $DC -f ${COMPOSE_FILE} logs -f sentry-web"
echo "停止并清理数据： $DC -f ${COMPOSE_FILE} down -v"

#!/usr/bin/env bash

if [ -z "${BASH_VERSION:-}" ]; then
  exec bash "$0" "$@"
fi

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

ENV_FILE=".env.custom"

if command -v docker &>/dev/null && docker compose version &>/dev/null; then
  DC="docker compose --env-file ./.env.custom"
elif command -v docker-compose &>/dev/null; then
  DC="docker-compose --env-file ./.env.custom"
else
  echo "未检测到 docker compose，请先安装 Docker Compose 或使用 Docker Desktop。"
  exit 1
fi

if [[ ! -f "$ENV_FILE" ]]; then
  echo "找不到 $ENV_FILE。请先执行初始化脚本：sh start.sh"
  exit 1
fi

# shellcheck disable=SC1090
set -a
source "$ENV_FILE" || true
set +a

if [[ -z "${REDIS_PASSWORD:-}" ]]; then
  echo "$ENV_FILE 中未找到 REDIS_PASSWORD，请先执行初始化脚本：sh start.sh"
  exit 1
fi

if [[ -z "${SENTRY_BIND:-}" ]]; then
  SENTRY_BIND="9006"
fi

if [[ ! -f "./nginx/nginx.conf" ]]; then
  echo "缺少 ./nginx/nginx.conf"
  exit 1
fi

if [[ ! -f "./relay/config.yml" ]]; then
  echo "缺少 ./relay/config.yml"
  exit 1
fi

echo "使用 $ENV_FILE 启动/拉起服务（不执行迁移）..."
$DC up -d

echo "等待服务启动..."
sleep 60

echo "按顺序重启 zookeeper kafka（降低启动时序问题）..."
$DC restart zookeeper
sleep 10
$DC restart kafka
sleep 10

echo "重启关键消费者（errors/transactions/replays）..."
$DC restart \
  snuba-consumer \
  snuba-transactions-consumer \
  snuba-replays-consumer \
  events-consumer \
  transactions-consumer \
  ingest-replay-recordings || true

echo "完成。Web UI: http://localhost:${SENTRY_BIND}"
echo "查看日志： $DC logs -f nginx"

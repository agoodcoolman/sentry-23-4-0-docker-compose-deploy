#!/usr/bin/env bash

if [ -z "${BASH_VERSION:-}" ]; then
  exec bash "$0" "$@"
fi

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

COMPOSE_FILE="docker-compose.yml"
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

mkdir -p ./nginx ./relay

if [[ ! -f "./nginx/nginx.conf" ]]; then
  echo "缺少 ./nginx/nginx.conf，请先创建该文件（用于 9006 入口反代）。"
  exit 1
fi

if [[ ! -f "./relay/config.yml" ]]; then
  echo "缺少 ./relay/config.yml，请先创建该文件（用于 Relay 配置）。"
  exit 1
fi

echo "使用 $ENV_FILE 启动/拉起服务（不执行迁移）..."
$DC -f "${COMPOSE_FILE}" up -d

echo "完成。Web UI: http://localhost:9006"
echo "查看日志： $DC -f ${COMPOSE_FILE} logs -f nginx"

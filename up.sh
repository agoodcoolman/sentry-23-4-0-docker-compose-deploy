#!/usr/bin/env bash
set -euo pipefail

COMPOSE_FILE="docker-compose.yml"
ENV_FILE=".env.custom"

if command -v docker &>/dev/null && docker compose version &>/dev/null; then
  DC="docker compose"
elif command -v docker-compose &>/dev/null; then
  DC="docker-compose"
else
  echo "未检测到 docker compose，请先安装 Docker Compose 或使用 Docker Desktop。"
  exit 1
fi

if [[ ! -f "$ENV_FILE" ]]; then
  echo "找不到 $ENV_FILE。请先执行初始化脚本：sh start.sh"
  exit 1
fi

# shellcheck disable=SC1090
source "$ENV_FILE" || true

if [[ -z "${REDIS_PASSWORD:-}" ]]; then
  echo "$ENV_FILE 中未找到 REDIS_PASSWORD，请先执行初始化脚本：sh start.sh"
  exit 1
fi

export REDIS_PASSWORD

echo "使用 $ENV_FILE 启动/拉起服务（不执行迁移）..."
$DC -f "${COMPOSE_FILE}" up -d

echo "完成。Web UI: http://localhost:9006"

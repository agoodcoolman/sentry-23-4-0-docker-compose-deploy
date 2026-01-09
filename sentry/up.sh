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

PY_BIN=""
if command -v python3 &>/dev/null; then
  PY_BIN="python3"
elif command -v python &>/dev/null; then
  PY_BIN="python"
fi

if [[ -n "$PY_BIN" ]]; then
  "$PY_BIN" - <<'PY'
import os
import pathlib
import urllib.parse

pw = os.environ.get("REDIS_PASSWORD", "")
cfg_path = pathlib.Path("./relay/config.yml")
if not pw or not cfg_path.exists():
    raise SystemExit(0)

text = cfg_path.read_text(encoding="utf-8")
if "${REDIS_PASSWORD}" not in text and "$REDIS_PASSWORD" not in text:
    raise SystemExit(0)

encoded = urllib.parse.quote(pw, safe="")
text = text.replace("${REDIS_PASSWORD}", encoded).replace("$REDIS_PASSWORD", encoded)
cfg_path.write_text(text, encoding="utf-8")
PY
fi

echo "使用 $ENV_FILE 启动/拉起服务（不执行迁移）..."
$DC -f "${COMPOSE_FILE}" up -d


echo "等待服务启动..."
sleep 50
# 直接启动的话，zookeeper 等启动好了再启动kafka队列   再启动消费者
echo "按照顺序重启 zookeeper kafka 消费者队列..."

$DC -f "${COMPOSE_FILE}" restart zookeeper
sleep 10
$DC -f "${COMPOSE_FILE}" restart kafka
sleep 10
$DC -f "${COMPOSE_FILE}" restart sentry-ingest-consumer snuba-consumer snuba-consumer-transactions
sleep 10

echo "完成。Web UI: http://localhost:9006"
echo "查看日志： $DC -f ${COMPOSE_FILE} logs -f nginx"

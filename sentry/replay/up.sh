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

wait_container_running() {
  local svc="$1"
  local timeout_s="${2:-180}"
  local start
  start="$(date +%s)"

  while true; do
    local cid
    cid="$($DC -f "${COMPOSE_FILE}" ps -q "$svc" 2>/dev/null || true)"
    if [[ -n "$cid" ]]; then
      local state
      state="$(docker inspect -f '{{.State.Status}}' "$cid" 2>/dev/null || true)"
      if [[ "$state" == "running" ]]; then
        return 0
      fi
    fi

    if (( $(date +%s) - start > timeout_s )); then
      echo "等待容器 $svc 进入 running 超时" >&2
      return 1
    fi
    sleep 2
  done
}

wait_zookeeper_ready() {
  local timeout_s="${1:-180}"
  local start
  start="$(date +%s)"

  while true; do
    if $DC -f "${COMPOSE_FILE}" exec -T zookeeper cub zk-ready zookeeper:2181 5 >/dev/null 2>&1; then
      return 0
    fi

    if (( $(date +%s) - start > timeout_s )); then
      echo "等待 zookeeper 就绪超时" >&2
      return 1
    fi
    sleep 2
  done
}

wait_kafka_ready() {
  local timeout_s="${1:-240}"
  local start
  start="$(date +%s)"

  while true; do
    if $DC -f "${COMPOSE_FILE}" exec -T kafka cub kafka-ready -b kafka:9092 1 5 >/dev/null 2>&1; then
      return 0
    fi

    if (( $(date +%s) - start > timeout_s )); then
      echo "等待 kafka 就绪超时" >&2
      return 1
    fi
    sleep 2
  done
}

wait_sentry_web_port() {
  local timeout_s="${1:-180}"
  local start
  start="$(date +%s)"

  while true; do
    if $DC -f "${COMPOSE_FILE}" exec -T sentry-web python - <<'PY'
import socket
sock = socket.create_connection(("127.0.0.1", 9000), timeout=2)
sock.close()
print("OK")
PY
    then
      return 0
    fi

    if (( $(date +%s) - start > timeout_s )); then
      echo "等待 sentry-web 9000 端口就绪超时" >&2
      return 1
    fi
    sleep 2
  done
}

echo "使用 $ENV_FILE 启动/拉起服务（不执行迁移）..."
$DC -f "${COMPOSE_FILE}" up -d

echo "等待核心服务进入 running..."
wait_container_running postgres 180
wait_container_running redis 180
wait_container_running zookeeper 180
echo "等待 zookeeper 服务就绪..."
wait_zookeeper_ready 240

wait_container_running kafka 240
echo "等待 kafka 服务就绪..."
wait_kafka_ready 300
wait_container_running snuba-api 240
wait_container_running sentry-web 240

echo "等待 sentry-web 9000 端口就绪..."
wait_sentry_web_port 240

echo "重启 relay（确保在 sentry-web 就绪后注册）..."
$DC -f "${COMPOSE_FILE}" restart relay
sleep 5

echo "启动/重启消费者（避免在 kafka/web 未就绪时抢跑）..."
$DC -f "${COMPOSE_FILE}" restart sentry-ingest-consumer snuba-consumer snuba-consumer-transactions snuba-consumer-replays sentry-ingest-replay-recordings
sleep 5

echo "完成。Web UI: http://localhost:9006"
echo "查看日志： $DC -f ${COMPOSE_FILE} logs -f nginx"

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
  echo "未检测到 docker compose，请先安装 Docker Compose 或使用 Docker Desktop。" >&2
  exit 1
fi

if [[ ! -f "$ENV_FILE" ]]; then
  echo "找不到 $ENV_FILE。请先执行初始化脚本：sh start.sh" >&2
  exit 1
fi

echo "确保 kafka 容器已启动..."
$DC -f "${COMPOSE_FILE}" up -d zookeeper kafka

echo "等待 kafka 就绪..."
KAFKA_READY=0
if $DC -f "${COMPOSE_FILE}" exec -T kafka bash -lc 'command -v cub >/dev/null 2>&1'; then
  if $DC -f "${COMPOSE_FILE}" exec -T kafka bash -lc 'cub kafka-ready -b localhost:9092 1 120 >/dev/null 2>&1'; then
    KAFKA_READY=1
  fi
fi

if [[ "$KAFKA_READY" != "1" ]]; then
  for i in $(seq 1 120); do
    if $DC -f "${COMPOSE_FILE}" exec -T kafka bash -lc 'kafka-topics --bootstrap-server localhost:9092 --list >/dev/null 2>&1'; then
      KAFKA_READY=1
      break
    fi
    sleep 2
  done
fi

if [[ "$KAFKA_READY" != "1" ]]; then
  echo "Kafka 在预期时间内未就绪，请检查 kafka/zookeeper 日志。" >&2
  exit 1
fi

echo "创建/补齐 Kafka topics（如已存在会跳过）..."
TOPICS=(
  "ingest-events"
  "ingest-transactions"
  "ingest-replays"
  "ingest-replay-recordings"
  "ingest-attachments"
  "ingest-sessions"
  "ingest-metrics"
)

for t in "${TOPICS[@]}"; do
  $DC -f "${COMPOSE_FILE}" exec -T kafka bash -lc "kafka-topics --bootstrap-server localhost:9092 --create --if-not-exists --topic ${t} --partitions 1 --replication-factor 1 >/dev/null"
done

echo "执行 snuba bootstrap（会创建 snuba 侧 topics + ClickHouse migrations）..."
$DC -f "${COMPOSE_FILE}" run --rm snuba-api bootstrap --force --bootstrap-server kafka:9092

echo "完成。你可以检查 topic 是否存在："
echo "  $DC -f ${COMPOSE_FILE} exec -T kafka bash -lc 'kafka-topics --bootstrap-server localhost:9092 --list | sort'"

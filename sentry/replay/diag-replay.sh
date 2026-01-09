#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

ENV_FILE="./.env.custom"
COMPOSE_FILE="./docker-compose.yml"

DC="docker compose --env-file ${ENV_FILE} -f ${COMPOSE_FILE}"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "missing ${ENV_FILE}; run: bash start.sh" >&2
  exit 1
fi

# shellcheck disable=SC1090
set -a
source "$ENV_FILE" || true
set +a

if [[ -z "${REDIS_PASSWORD:-}" ]]; then
  echo "REDIS_PASSWORD is empty in ${ENV_FILE}. Fix env file first." >&2
  exit 1
fi

kafka_exec() {
  $DC exec -T kafka bash -lc "$*"
}

echo "== A) Containers status =="
$DC ps

echo

echo "== B) Key service logs (tail) =="
for svc in relay sentry-ingest-consumer sentry-ingest-replay-recordings snuba-consumer-replays kafka; do
  echo "-- logs: ${svc}"
  $DC logs --tail 120 "$svc" 2>/dev/null | cat || true
  echo
  echo
 done

echo "== C) Kafka topics (replay/outcomes) =="
kafka_exec 'kafka-topics --bootstrap-server localhost:9092 --list | egrep -i "replay|outcomes" || true'

echo

echo "== D) Kafka end offsets (latest) =="
TOPICS=(
  outcomes
  ingest-outcomes
  ingest-replays
  ingest-replay-events
  ingest-replay-recordings
  snuba-dead-letter-replays
)
for t in "${TOPICS[@]}"; do
  echo "-- ${t}"
  kafka_exec "kafka-run-class kafka.tools.GetOffsetShell --broker-list localhost:9092 --topic ${t} --time -1" || true
  echo
 done

echo "== E) Kafka consumer groups (filter replay/snuba/ingest) =="
GROUPS_RAW="$(kafka_exec 'kafka-consumer-groups --bootstrap-server localhost:9092 --list 2>/dev/null | egrep -i "replay|snuba|ingest" || true')"
if [[ -z "$GROUPS_RAW" ]]; then
  echo "(no matching consumer groups found)"
else
  echo "$GROUPS_RAW"
  echo
  while IFS= read -r g; do
    [[ -z "$g" ]] && continue
    echo "-- describe group: $g"
    kafka_exec "kafka-consumer-groups --bootstrap-server localhost:9092 --describe --group $g" || true
    echo
  done <<< "$GROUPS_RAW"
fi

echo "== F) Two-phase offset check (to prove replay reaches Kafka) =="
echo "1) Trigger ONE replay session in browser now (do some interactions and/or throw an error)."
echo "2) Then press Enter to re-check offsets."
read -r _

echo "-- offsets after trigger"
for t in ingest-replays ingest-replay-events ingest-replay-recordings; do
  echo "-- ${t}"
  kafka_exec "kafka-run-class kafka.tools.GetOffsetShell --broker-list localhost:9092 --topic ${t} --time -1" || true
  echo
 done

echo "== Done =="

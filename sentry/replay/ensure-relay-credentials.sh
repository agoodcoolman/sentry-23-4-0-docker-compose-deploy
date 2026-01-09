#!/usr/bin/env sh
set -eu

if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  DC="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
  DC="docker-compose"
else
  echo "docker compose not found" >&2
  exit 1
fi

cd "$(dirname "$0")"

if [ ! -f ./.env.custom ]; then
  echo "missing ./.env.custom" >&2
  exit 1
fi

mkdir -p ./relay

$DC --env-file ./.env.custom -f docker-compose.yml pull relay

$DC --env-file ./.env.custom -f docker-compose.yml run --rm relay credentials generate --stdout > ./relay/credentials.json.tmp
mv ./relay/credentials.json.tmp ./relay/credentials.json

$DC --env-file ./.env.custom -f docker-compose.yml run --rm relay credentials show >/dev/null

echo "OK: relay/credentials.json generated"

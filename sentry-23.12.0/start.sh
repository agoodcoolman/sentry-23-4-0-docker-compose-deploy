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

generate_secret() {
  if command -v openssl &>/dev/null; then
    openssl rand -hex 24
    return 0
  fi
  if command -v python3 &>/dev/null; then
    python3 -c "import secrets; print(secrets.token_hex(24))"
    return 0
  fi
  if command -v python &>/dev/null; then
    python -c "import secrets; print(secrets.token_hex(24))"
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
  if [[ ! -f "$ENV_FILE" ]]; then
    if [[ ! -f "./.env" ]]; then
      echo "缺少 ./.env（需要从官方 .env 提供镜像版本等变量）。"
      exit 1
    fi
    cp "./.env" "$ENV_FILE"
  fi

  if [[ -f "$ENV_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$ENV_FILE" || true
  fi

  if [[ -z "${REDIS_PASSWORD:-}" || "${REDIS_PASSWORD:-}" == "please-change-me" ]]; then
    REDIS_PASSWORD="$(generate_secret)"
  fi

  if [[ -z "${SENTRY_BIND:-}" ]]; then
    SENTRY_BIND="9006"
  fi

  upsert_env_kv "REDIS_PASSWORD" "$REDIS_PASSWORD"
  upsert_env_kv "SENTRY_BIND" "$SENTRY_BIND"

  export REDIS_PASSWORD SENTRY_BIND
}

ensure_image_vars() {
  local version=""
  if [[ -n "${SENTRY_IMAGE:-}" ]]; then
    if [[ "${SENTRY_IMAGE}" =~ ^getsentry/sentry:([^@]+)$ ]]; then
      version="${BASH_REMATCH[1]}"
    fi
  fi

  if [[ -z "${RELAY_IMAGE:-}" && -n "$version" ]]; then
    RELAY_IMAGE="getsentry/relay:${version}"
  fi
  if [[ -z "${SNUBA_IMAGE:-}" && -n "$version" ]]; then
    SNUBA_IMAGE="getsentry/snuba:${version}"
  fi
  if [[ -z "${SYMBOLICATOR_IMAGE:-}" && -n "$version" ]]; then
    SYMBOLICATOR_IMAGE="getsentry/symbolicator:${version}"
  fi
  if [[ -z "${VROOM_IMAGE:-}" && -n "$version" ]]; then
    VROOM_IMAGE="getsentry/vroom:${version}"
  fi

  if [[ -z "${DOCKER_PLATFORM:-}" || -z "${CLICKHOUSE_IMAGE:-}" ]]; then
    local docker_arch=""
    docker_arch="$(docker info --format '{{.Architecture}}' 2>/dev/null || true)"
    if [[ "$docker_arch" == "x86_64" || "$docker_arch" == "amd64" ]]; then
      DOCKER_PLATFORM="linux/amd64"
      if [[ -z "${CLICKHOUSE_IMAGE:-}" ]]; then
        CLICKHOUSE_IMAGE="altinity/clickhouse-server:21.8.13.1.altinitystable"
      fi
    elif [[ "$docker_arch" == "aarch64" || "$docker_arch" == "arm64" ]]; then
      DOCKER_PLATFORM="linux/arm64"
      if [[ -z "${CLICKHOUSE_IMAGE:-}" ]]; then
        CLICKHOUSE_IMAGE="altinity/clickhouse-server:21.8.12.29.altinitydev.arm"
      fi
    elif [[ -z "${CLICKHOUSE_IMAGE:-}" ]]; then
      echo "无法检测 Docker Architecture（docker info --format '{{.Architecture}}'），且未设置 CLICKHOUSE_IMAGE。"
      exit 1
    fi
  fi

  if [[ -z "${SYMBOLICATOR_IMAGE:-}" ]]; then
    echo "$ENV_FILE 中未找到 SYMBOLICATOR_IMAGE，请先在 $ENV_FILE 中设置。"
    exit 1
  fi
  if [[ -z "${VROOM_IMAGE:-}" ]]; then
    echo "$ENV_FILE 中未找到 VROOM_IMAGE，请先在 $ENV_FILE 中设置。"
    exit 1
  fi
  if [[ -z "${CLICKHOUSE_IMAGE:-}" ]]; then
    echo "$ENV_FILE 中未找到 CLICKHOUSE_IMAGE，请先在 $ENV_FILE 中设置。"
    exit 1
  fi

  upsert_env_kv "DOCKER_PLATFORM" "${DOCKER_PLATFORM:-}"
  upsert_env_kv "CLICKHOUSE_IMAGE" "$CLICKHOUSE_IMAGE"
  if [[ -n "${RELAY_IMAGE:-}" ]]; then
    upsert_env_kv "RELAY_IMAGE" "$RELAY_IMAGE"
  fi
  if [[ -n "${SNUBA_IMAGE:-}" ]]; then
    upsert_env_kv "SNUBA_IMAGE" "$SNUBA_IMAGE"
  fi
  upsert_env_kv "SYMBOLICATOR_IMAGE" "$SYMBOLICATOR_IMAGE"
  upsert_env_kv "VROOM_IMAGE" "$VROOM_IMAGE"

  export DOCKER_PLATFORM CLICKHOUSE_IMAGE RELAY_IMAGE SNUBA_IMAGE SYMBOLICATOR_IMAGE VROOM_IMAGE
}

render_relay_config() {
  local cfg_path="./relay/config.yml"
  if [[ ! -f "$cfg_path" ]]; then
    echo "缺少 $cfg_path"
    exit 1
  fi

  local py=""
  if command -v python3 &>/dev/null; then
    py="python3"
  elif command -v python &>/dev/null; then
    py="python"
  fi

  if [[ -z "$py" ]]; then
    echo "未找到 python/python3，无法对 relay/config.yml 做 URL 编码渲染。"
    exit 1
  fi

  "$py" - <<'PY'
import os
import pathlib
import urllib.parse

pw = os.environ.get("REDIS_PASSWORD", "")
path = pathlib.Path("./relay/config.yml")
text = path.read_text(encoding="utf-8")
if "${REDIS_PASSWORD}" not in text and "$REDIS_PASSWORD" not in text:
    raise SystemExit(0)
encoded = urllib.parse.quote(pw, safe="")
text = text.replace("${REDIS_PASSWORD}", encoded).replace("$REDIS_PASSWORD", encoded)
path.write_text(text, encoding="utf-8")
PY
}

ensure_sentry_secret_key() {
  local cfg="./sentry/config.yml"
  if [[ ! -f "$cfg" ]]; then
    echo "缺少 $cfg"
    exit 1
  fi

  if grep -xq "system.secret-key: '!!changeme!!'" "$cfg"; then
    local py=""
    if command -v python3 &>/dev/null; then
      py="python3"
    elif command -v python &>/dev/null; then
      py="python"
    fi

    if [[ -z "$py" ]]; then
      echo "未找到 python/python3，无法生成 system.secret-key。"
      exit 1
    fi

    local secret
    secret="$($py -c "import secrets,string; alphabet=string.ascii_lowercase+string.digits+'@#%^&*(-_=+)'; print(''.join(secrets.choice(alphabet) for _ in range(50)))")"

    local tmp="${cfg}.tmp"
    sed -e "s/^system\.secret-key:.*$/system.secret-key: '${secret}'/" "$cfg" > "$tmp"
    mv "$tmp" "$cfg"
  fi

  chmod 777 "./sentry/config.yml"
}

ensure_relay_credentials() {
  if [[ -f "./relay/credentials.json" && -s "./relay/credentials.json" ]]; then
    return 0
  fi

  echo "生成 Relay credentials..."
  rm -f "./relay/credentials.json" 2>/dev/null || true

  $DC pull relay >/dev/null 2>&1 || true
  $DC run --rm --no-deps -T relay credentials generate --stdout >"./relay/credentials.json.tmp"
  mv "./relay/credentials.json.tmp" "./relay/credentials.json"

  chmod 777 "./relay/credentials.json"
}

ensure_geoip_files() {
  mkdir -p ./sentrydata/geoip
  if [[ ! -f "./sentrydata/geoip/GeoLite2-City.mmdb" ]]; then
    echo "初始化 GeoIP 数据库（使用官方空 mmdb 文件）..."
    local url="https://raw.githubusercontent.com/getsentry/self-hosted/23.12.0/geoip/GeoLite2-City.mmdb.empty"
    docker run --rm \
      -e http_proxy -e https_proxy -e HTTPS_PROXY -e no_proxy -e NO_PROXY \
      curlimages/curl:7.77.0 \
      --connect-timeout 5 \
      --max-time 30 \
      --retry 10 \
      --retry-max-time 180 \
      -L "$url" \
      >"./sentrydata/geoip/GeoLite2-City.mmdb.tmp"
    mv "./sentrydata/geoip/GeoLite2-City.mmdb.tmp" "./sentrydata/geoip/GeoLite2-City.mmdb"
  fi
}

install_wal2json() {
  local wal_dir="./postgres/wal2json"
  local file_to_use="$wal_dir/wal2json.so"
  local arch
  arch="$(uname -m)"
  local file_name="wal2json-Linux-${arch}-glibc.so"

  mkdir -p "$wal_dir"

  local version
  version="${WAL2JSON_VERSION:-latest}"

  if [[ "$version" == "latest" ]]; then
    version="0.0.2"
  fi

  local version_dir="$wal_dir/$version"
  mkdir -p "$version_dir"

  if [[ ! -f "$version_dir/$file_name" ]]; then
    echo "下载 wal2json ${version}/${file_name}（带重试）..."
    docker run --rm \
      -e http_proxy -e https_proxy -e HTTPS_PROXY -e no_proxy -e NO_PROXY \
      curlimages/curl:7.77.0 \
      --connect-timeout 5 \
      --max-time 30 \
      --retry 10 \
      --retry-max-time 180 \
      -L "https://github.com/getsentry/wal2json/releases/download/${version}/${file_name}" \
      >"$version_dir/$file_name"
  fi

  cp "$version_dir/$file_name" "$file_to_use"
}

bootstrap_snuba_and_topics() {
  echo "Bootstrapping Snuba..."
  local ok=0
  local wait_s=5
  for i in $(seq 1 12); do
    if $DC run --rm snuba-api bootstrap --no-migrate --force; then
      ok=1
      break
    fi
    echo "snuba-api bootstrap 失败，等待 ${wait_s}s 后重试（${i}/12）..."
    sleep "$wait_s"
    if [[ "$wait_s" -lt 60 ]]; then
      wait_s=$((wait_s * 2))
      if [[ "$wait_s" -gt 60 ]]; then
        wait_s=60
      fi
    fi
  done
  if [[ "$ok" != "1" ]]; then
    echo "snuba-api bootstrap 多次失败，请检查 kafka/clickhouse 状态。"
    exit 1
  fi

  $DC run --rm snuba-api migrations migrate --force

  echo "创建 Kafka topics..."
  local existing
  existing="$($DC exec -T kafka bash -lc 'kafka-topics --list --bootstrap-server kafka:9092 2>/dev/null' || true)"
  local needed="ingest-attachments ingest-transactions ingest-events ingest-replay-recordings profiles ingest-occurrences ingest-metrics ingest-performance-metrics"
  for topic in $needed; do
    if ! echo "$existing" | grep -qE "(^| )${topic}( |$)"; then
      $DC exec -T kafka bash -lc "kafka-topics --create --topic ${topic} --bootstrap-server kafka:9092" || true
    fi
  done
}

wait_kafka_ready() {
  echo "等待 Kafka 就绪..."
  local ready=0
  for i in $(seq 1 120); do
    if $DC exec -T kafka bash -lc 'kafka-topics --bootstrap-server kafka:9092 --list >/dev/null 2>&1'; then
      ready=1
      break
    fi
    sleep 2
  done

  if [[ "$ready" != "1" ]]; then
    echo "Kafka 在预期时间内未就绪，请检查 kafka/zookeeper 日志。"
    exit 1
  fi
}

chmod_all_dir() {
  chmod 777 ./postgres/postgres-entrypoint.sh
  chmod 777 ./postgres/init_hba.sh

  chmod 777 ./nginx/nginx.conf

  chmod 777 ./clickhouse/config.xml

  chmod 777 ./cron/entrypoint.sh

  chmod 777 ./sentry/enhance-image.sh
  chmod 777 ./sentry/entrypoint.sh
  chmod 777 ./sentry/sentry.conf.py

}

main() {
  echo "0) 初始化环境变量..."
  ensure_env_file
  ensure_image_vars

  echo "1) 准备目录与配置..."
  mkdir -p \
    ./sentrydata/sentry \
    ./sentrydata/postgres \
    ./sentrydata/redis \
    ./sentrydata/zookeeper \
    ./sentrydata/zookeeper-log \
    ./sentrydata/kafka \
    ./sentrydata/kafka-log \
    ./sentrydata/clickhouse \
    ./sentrydata/clickhouse-log \
    ./sentrydata/symbolicator \
    ./sentrydata/vroom \
    ./sentrydata/nginx-cache \
    ./sentrydata/secrets \
    ./sentrydata/smtp \
    ./sentrydata/smtp-log \
    ./sentrydata/certificates \
    ./sentrydata/geoip

  ensure_geoip_files
  ensure_sentry_secret_key
  render_relay_config

  echo "2) 停止并移除旧容器（包含孤儿）..."
  $DC down --remove-orphans || true

  echo "3) 下载 wal2json..."
  install_wal2json
  
  # 偷偷授权
  chmod_all_dir

  echo "4) 构建本地镜像（并行）..."
  $DC build --parallel

  echo "5) 启动基础依赖（后台）: postgres redis zookeeper kafka clickhouse"
  $DC up -d postgres redis zookeeper kafka clickhouse

  wait_kafka_ready

  echo "6) 生成 Relay credentials..."
  ensure_relay_credentials

  echo "7) 初始化 Snuba / Kafka topics..."
  bootstrap_snuba_and_topics

  echo "8) 执行数据库迁移（web upgrade --noinput）..."
  $DC run --rm web upgrade --noinput

  echo "9) 启动全部服务（后台）..."
  $DC up -d

  echo "完成。Web UI: http://localhost:${SENTRY_BIND}"
  echo "创建管理员： $DC run --rm web createuser"
  echo "查看日志： $DC logs -f nginx"
}

main "$@"

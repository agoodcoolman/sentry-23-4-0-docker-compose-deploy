#!/usr/bin/env bash
set -euo pipefail

COMPOSE_FILE="docker-compose.yml"
OUTPUT_TAR=""
PULL_MISSING=0

usage() {
  echo "用法："
  echo "  sh export-images.sh [-f docker-compose.yml] [-o images.tar] [--pull]"
  echo
  echo "参数："
  echo "  -f    指定 compose 文件（默认 docker-compose.yml）"
  echo "  -o    输出 tar 文件名（默认 sentry-images-YYYYmmdd-HHMMSS.tar）"
  echo "  --pull 若本地不存在镜像则自动 docker pull"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -f)
      COMPOSE_FILE="$2"
      shift 2
      ;;
    -o)
      OUTPUT_TAR="$2"
      shift 2
      ;;
    --pull)
      PULL_MISSING=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "未知参数：$1"
      usage
      exit 1
      ;;
  esac
done

if [[ -z "$OUTPUT_TAR" ]]; then
  TS=$(date +%Y%m%d-%H%M%S)
  OUTPUT_TAR="sentry-images-${TS}.tar"
fi

if command -v docker &>/dev/null && docker compose version &>/dev/null; then
  DC="docker compose"
elif command -v docker-compose &>/dev/null; then
  DC="docker-compose"
else
  echo "未检测到 docker compose，请先安装 Docker Compose 或使用 Docker Desktop。"
  exit 1
fi

if [[ ! -f "$COMPOSE_FILE" ]]; then
  echo "找不到 compose 文件：$COMPOSE_FILE"
  exit 1
fi

echo "1) 解析 compose 中用到的镜像列表..."
IMAGES_RAW=$($DC -f "$COMPOSE_FILE" config --images)
if [[ -z "${IMAGES_RAW// }" ]]; then
  echo "未解析到任何镜像，请检查 compose 文件是否包含 image: 字段。"
  exit 1
fi

mapfile -t IMAGES < <(echo "$IMAGES_RAW" | sed '/^\s*$/d' | sort -u)

echo "共 ${#IMAGES[@]} 个镜像："
for img in "${IMAGES[@]}"; do
  echo "- $img"
done

echo

echo "2) 检查镜像是否已在本地..."
MISSING=()
for img in "${IMAGES[@]}"; do
  if ! docker image inspect "$img" >/dev/null 2>&1; then
    MISSING+=("$img")
  fi
done

if [[ ${#MISSING[@]} -gt 0 ]]; then
  echo "以下镜像本地不存在："
  for img in "${MISSING[@]}"; do
    echo "- $img"
  done

  if [[ "$PULL_MISSING" -eq 1 ]]; then
    echo
    echo "3) 正在拉取缺失镜像（docker pull）..."
    for img in "${MISSING[@]}"; do
      docker pull "$img"
    done
  else
    echo
    echo "你可以先手动拉取：docker pull <image>"
    echo "或重新执行脚本加 --pull 参数自动拉取。"
    exit 1
  fi
fi

echo

echo "4) 导出镜像为 tar：$OUTPUT_TAR"
docker save -o "$OUTPUT_TAR" "${IMAGES[@]}"

echo

echo "完成：$OUTPUT_TAR"
echo "恢复示例：docker load -i $OUTPUT_TAR"

#!/usr/bin/env sh
set -eu

# 你的 Sentry 地址
SENTRY_URL="http://192.168.3.153:9006"
SENTRY_AUTH_TOKEN="46a1b416855b47edbe8cf55bc76a579ee2c68c8d78954226811d4f68acaf9bdf"
SENTRY_ORG="sentry"
SENTRY_PROJECT="javascript-vue"

# 基础目录
DIST_DIR="/home/sentry/sentrynew/sourcemap/"

# ======= [修改点 1: 自动获取版本号] =======
# 查找 DIST_DIR 下第一个子文件夹的名字作为版本号
# 例如：/home/.../sourcemap/1.0.0/ -> VERSION=1.0.0
VERSION=$(ls -F "$DIST_DIR" | grep '/$' | head -n 1 | sed 's/\///')

if [ -z "$VERSION" ]; then
  echo "[ERROR] No version directory found in $DIST_DIR" >&2
  exit 1
fi

# 拼接完整的 RELEASE 名称
RELEASE="$VERSION"
# 更新实际包含文件的目录
UPLOAD_DIR="${DIST_DIR}${VERSION}"
# =========================================

URL_PREFIX="http://ip/assets"

# 逻辑检查
if [ ! -d "$UPLOAD_DIR" ]; then
  echo "[ERROR] Upload directory not found: $UPLOAD_DIR" >&2
  exit 2
fi

echo "[INFO] Detected Version: $VERSION"
echo "[INFO] Release Name: $RELEASE"
echo "[INFO] Uploading from: $UPLOAD_DIR"

URL_PREFIX_NORM="$URL_PREFIX"
case "$URL_PREFIX_NORM" in
  http://*|https://*) URL_PREFIX_NORM="/${URL_PREFIX_NORM#*://*/}" ;;
esac
case "$URL_PREFIX_NORM" in
  ~/*) ;;
  /*) URL_PREFIX_NORM="~$URL_PREFIX_NORM" ;;
  *)  URL_PREFIX_NORM="~/$URL_PREFIX_NORM" ;;
esac

# 1. 创建 Release
docker run --rm \
  -e SENTRY_URL="$SENTRY_URL" \
  -e SENTRY_AUTH_TOKEN="$SENTRY_AUTH_TOKEN" \
  getsentry/sentry-cli:2.50.0 \
  releases new -p "$SENTRY_PROJECT" "$RELEASE" \
  --org "$SENTRY_ORG" || true

# 2. 上传 SourceMap
# ======= [修改点 2: 挂载路径改为 UPLOAD_DIR] =======
docker run --rm \
  -e SENTRY_URL="$SENTRY_URL" \
  -e SENTRY_AUTH_TOKEN="$SENTRY_AUTH_TOKEN" \
  -v "$UPLOAD_DIR":/work:ro \
  getsentry/sentry-cli:2.50.0 \
  releases files "$RELEASE" upload-sourcemaps /work \
  --org "$SENTRY_ORG" \
  --project "$SENTRY_PROJECT" \
  --url-prefix "$URL_PREFIX_NORM" \
  --rewrite
# =================================================

# 3. 归档 Release
docker run --rm \
  -e SENTRY_URL="$SENTRY_URL" \
  -e SENTRY_AUTH_TOKEN="$SENTRY_AUTH_TOKEN" \
  getsentry/sentry-cli:2.50.0 \
  releases finalize "$RELEASE" \
  --org "$SENTRY_ORG" || true

# ======= [修改点 3: 上传完毕删除本地 .map 文件] =======
echo "[INFO] Cleaning up SourceMaps in $UPLOAD_DIR ..."
find "$UPLOAD_DIR" -name "*.map" -type f -delete
echo "[INFO] All .map files deleted. (JS files kept)"
# =================================================

echo "[INFO] Upload and Cleanup done."
#!/usr/bin/env bash
set -euo pipefail
WORK_DIR="${TRAFFICCOP_WORK_DIR:-/root/TrafficCop}"
REPO_URL="${TRAFFICCOP_REPO_URL:-https://raw.githubusercontent.com/Johnn-Lee/vpstraffic/main}"
TARGET="$WORK_DIR/trafficcop.sh"
SOURCE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P || true)
LOCAL_SCRIPT="$SOURCE_DIR/trafficcop.sh"
[ "$(id -u)" -eq 0 ] || { echo '错误：请使用 root 用户运行。' >&2; exit 1; }
mkdir -p "$WORK_DIR"
if [ -f "$LOCAL_SCRIPT" ]; then
  if [ "$(readlink -f "$LOCAL_SCRIPT")" != "$(readlink -f "$TARGET" 2>/dev/null || true)" ]; then
    echo '正在安装当前目录中的 TrafficCop 主脚本...'
    cp -f "$LOCAL_SCRIPT" "$TARGET.new"
    chmod 700 "$TARGET.new"
    mv -f "$TARGET.new" "$TARGET"
  fi
else
  command -v curl >/dev/null 2>&1 || { echo '错误：请先安装 curl。' >&2; exit 1; }
  echo '正在下载 TrafficCop 主脚本...'
  curl -fsSL "$REPO_URL/trafficcop.sh" -o "$TARGET.new" || { rm -f "$TARGET.new"; echo '错误：下载失败。' >&2; exit 1; }
  chmod 700 "$TARGET.new"
  mv -f "$TARGET.new" "$TARGET"
fi
export TRAFFICCOP_WORK_DIR="$WORK_DIR"
exec bash "$TARGET" "$@"

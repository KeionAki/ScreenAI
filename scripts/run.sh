#!/bin/bash
# 构建并启动（默认 debug）
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/build-app.sh "${1:-debug}"
pkill -x ScreenAI 2>/dev/null || true
sleep 0.3
open dist/ScreenAI.app
echo "已启动，菜单栏可见图标。日志: log stream --predicate 'subsystem == \"com.li.screenai\"' --level info"

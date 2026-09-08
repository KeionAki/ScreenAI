#!/bin/bash
# 用一张图片代替屏幕截图，走应用内相同的编码与 API 路径，打印模型返回的事件。
# 用法: scripts/test-image.sh 图片路径 [--no-stream] [--raw] [--prompt "提示词"]
set -uo pipefail
cd "$(dirname "$0")/.."
[ -x dist/ScreenAI.app/Contents/MacOS/ScreenAI ] || { echo "请先运行 scripts/build-app.sh"; exit 1; }
exec dist/ScreenAI.app/Contents/MacOS/ScreenAI --analyze-image "$@"

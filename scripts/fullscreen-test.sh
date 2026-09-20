#!/bin/bash
# 验证键入是否会让全屏浏览器退出全屏。用法: scripts/fullscreen-test.sh [--no-escape]
set -uo pipefail
cd "$(dirname "$0")/.."
EXTRA="${1:-}"
APP="$PWD/dist/ScreenAI.app"
STAMP=$(date +%H%M%S)
LOG="$PWD/build/fslog_$STAMP.txt"
CODE="$PWD/build/fscode.txt"
printf 'alpha = one\nbravo = two\ncharlie = three\ndelta = four\n' > "$CODE"

bounds() { osascript -e 'tell application "Google Chrome" to get bounds of window 1' 2>/dev/null; }
screensize() { osascript -e 'tell application "Finder" to get bounds of window of desktop' 2>/dev/null; }

osascript -e 'tell application "Google Chrome" to activate' >/dev/null 2>&1; sleep 1
echo "屏幕:     $(screensize)"
echo "进入全屏前: $(bounds)"
open -n -a "$APP" --args --press ctrl+cmd+f >/dev/null 2>&1
sleep 4
B1=$(bounds); echo "进入全屏后: $B1"

open -n -a "$APP" --args --type-file "$CODE" --countdown 2 --cps 40 --clear-indent \
    $EXTRA --require-frontmost com.google.Chrome --log "$LOG"
for _ in $(seq 1 40); do grep -q "^结果:" "$LOG" 2>/dev/null && break; sleep 1; done
tail -2 "$LOG"
sleep 2
B2=$(bounds); echo "键入之后:   $B2"
if [ "$B1" = "$B2" ]; then echo "全屏保持 ✅（模式: ${EXTRA:-按 Esc}）"; else echo "全屏被退出 ❌（模式: ${EXTRA:-按 Esc}）"; fi

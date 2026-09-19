#!/bin/bash
# 真实键入验证：把一份代码键入到 TextEdit 新建的纯文本文档，再读回比对。
# 用法: scripts/type-test.sh [代码文件]  （默认 build/generated.py）
set -uo pipefail
cd "$(dirname "$0")/.."
SRC="${1:-build/generated.py}"
[ -f "$SRC" ] || { echo "找不到代码文件: $SRC"; exit 1; }
APP="$PWD/dist/ScreenAI.app"
DOC="$PWD/build/typing_test.py"
LOG="$PWD/build/typelog.txt"
OUT="$PWD/build/typed_back.txt"

rm -f "$LOG" "$OUT"
: > "$DOC"
osascript -e 'tell application "TextEdit" to close every document saving no' >/dev/null 2>&1
open -a TextEdit "$DOC"
sleep 2
osascript -e 'tell application "TextEdit" to activate' >/dev/null 2>&1
sleep 1
FRONT=$(osascript -e 'tell application "System Events" to get bundle identifier of first application process whose frontmost is true' 2>/dev/null)
echo "最前应用: ${FRONT:-未知}"

# 用 open -n 启动新实例，让系统把辅助功能权限归属给 ScreenAI 本身而不是终端
open -n -a "$APP" --args --type-file "$PWD/$SRC" --countdown 2 --cps 90 --clear-indent \
    --require-frontmost com.apple.TextEdit --log "$LOG"

CHARS=$(wc -c < "$SRC" | tr -d ' ')
LIMIT=$(( CHARS / 90 + 40 ))
for _ in $(seq 1 $LIMIT); do
  grep -q "^结果:" "$LOG" 2>/dev/null && break
  sleep 1
done
echo "--- 键入日志 ---"; cat "$LOG" 2>/dev/null

osascript -e 'tell application "TextEdit" to get text of document 1' > "$OUT" 2>/dev/null
# AppleScript 的换行是 \r，统一成 \n；并去掉尾部多余换行
python3 - "$SRC" "$OUT" <<'PY'
import sys
src = open(sys.argv[1], encoding='utf-8').read().replace('\r\n', '\n').replace('\r', '\n').rstrip('\n')
got = open(sys.argv[2], encoding='utf-8').read().replace('\r\n', '\n').replace('\r', '\n').rstrip('\n')
print("--- 比对 ---")
print("生成 %d 字符 / %d 行" % (len(src), src.count('\n') + 1))
print("键入 %d 字符 / %d 行" % (len(got), got.count('\n') + 1))
if src == got:
    print("完全一致 ✅")
    sys.exit(0)
print("不一致 ❌")
import difflib
for line in list(difflib.unified_diff(src.split('\n'), got.split('\n'), '生成', '键入', lineterm='', n=1))[:40]:
    print(line)
sys.exit(1)
PY

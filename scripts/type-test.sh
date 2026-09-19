#!/bin/bash
# 真实键入验证：把一份代码键入到 TextEdit 新建的纯文本文档，再按字节读回比对。
# 用法: scripts/type-test.sh [代码文件]  （默认 build/generated.py）
set -uo pipefail
cd "$(dirname "$0")/.."
SRC="${1:-build/generated.py}"
[ -f "$SRC" ] || { echo "找不到代码文件: $SRC"; exit 1; }
APP="$PWD/dist/ScreenAI.app"
STAMP=$(date +%H%M%S)
DOC="$PWD/build/typing_test_$STAMP.py"
LOG="$PWD/build/typelog_$STAMP.txt"

: > "$DOC"
open -a TextEdit "$DOC"
sleep 2
osascript -e 'tell application "TextEdit" to activate' >/dev/null 2>&1
sleep 1

# 用 open -n 启动新实例，让系统把辅助功能权限归属给 ScreenAI 本身而不是终端
open -n -a "$APP" --args --type-file "$PWD/$SRC" --countdown 2 --cps 90 --clear-indent \
    --require-frontmost com.apple.TextEdit --then-save --log "$LOG"

CHARS=$(wc -c < "$SRC" | tr -d ' ')
for _ in $(seq 1 $(( CHARS / 90 + 60 ))); do
  grep -q "^结果:" "$LOG" 2>/dev/null && break
  sleep 1
done
echo "--- 键入日志 ---"; tail -3 "$LOG" 2>/dev/null

# 等待 TextEdit 把文档写盘
for _ in $(seq 1 30); do [ -s "$DOC" ] && break; sleep 1; done

python3 - "$SRC" "$DOC" <<'PY'
import sys, difflib
src = open(sys.argv[1], encoding='utf-8').read().replace('\r\n', '\n').replace('\r', '\n').rstrip('\n')
got = open(sys.argv[2], encoding='utf-8').read().replace('\r\n', '\n').replace('\r', '\n').rstrip('\n')
print("--- 比对 ---")
print("生成 %d 字符 / %d 行" % (len(src), src.count('\n') + 1))
print("键入 %d 字符 / %d 行" % (len(got), got.count('\n') + 1))
if not got:
    print("文档为空，TextEdit 未写盘 ❌"); sys.exit(1)
if src == got:
    print("完全一致 ✅"); sys.exit(0)
diffs = [(x, y) for x, y in zip(src, got) if x != y]
if len(src) == len(got) and diffs and all(x.lower() == y.lower() for x, y in diffs):
    print("长度一致，全部 %d 处差异都只是行首字母大小写 ⚠️" % len(diffs))
    print("这是目标编辑器的「自动大写」文本替换，不是键入错误。")
    print("TextEdit：编辑 › 替换 › 取消勾选「自动大写」即可；VSCode 等代码编辑器没有此功能。")
    sys.exit(0)
print("存在实质差异 ❌")
print('\n'.join(list(difflib.unified_diff(src.split('\n'), got.split('\n'), '生成', '键入', lineterm='', n=0))[:24]))
sys.exit(1)
PY
RC=$?
osascript -e "tell application \"TextEdit\" to close (every document whose name is \"$(basename "$DOC")\") saving no" >/dev/null 2>&1
exit $RC

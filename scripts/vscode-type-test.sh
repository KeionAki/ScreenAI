#!/bin/bash
# 在 VSCode 里做键入验证。用法: scripts/vscode-type-test.sh [--no-escape] [代码文件]
set -uo pipefail
cd "$(dirname "$0")/.."
EXTRA=""
if [ "${1:-}" = "--no-escape" ]; then EXTRA="--no-escape"; shift; fi
SRC="${1:-build/generated.py}"
STAMP=$(date +%H%M%S)
DOC="$PWD/build/vstest_$STAMP.py"
LOG="$PWD/build/vslog_$STAMP.txt"
: > "$DOC"
open -a "Visual Studio Code" "$DOC"
sleep 3
osascript -e 'tell application "Visual Studio Code" to activate' >/dev/null 2>&1
sleep 2
FRONT=$(osascript -e 'tell application "System Events" to get bundle identifier of first application process whose frontmost is true' 2>/dev/null)
echo "最前应用: ${FRONT:-未知}"
open -n -a "$PWD/dist/ScreenAI.app" --args --type-file "$PWD/$SRC" --countdown 2 --cps 60 --clear-indent \
    $EXTRA --require-frontmost com.microsoft.VSCode --then-save --log "$LOG"
CHARS=$(wc -c < "$SRC" | tr -d ' ')
for _ in $(seq 1 $(( CHARS / 60 + 60 ))); do grep -q "^结果:" "$LOG" 2>/dev/null && break; sleep 1; done
tail -2 "$LOG"
for _ in $(seq 1 15); do [ -s "$DOC" ] && break; sleep 1; done
sleep 2
python3 - "$SRC" "$DOC" "${EXTRA:-with-escape}" <<'PY'
import sys, difflib
src = open(sys.argv[1], encoding='utf-8').read().replace('\r\n','\n').rstrip('\n')
got = open(sys.argv[2], encoding='utf-8').read().replace('\r\n','\n').rstrip('\n')
mode = "不按 Esc" if sys.argv[3] == "--no-escape" else "按 Esc"
print("=== %s ===" % mode)
print("生成 %d 字符 / %d 行 ；键入 %d 字符 / %d 行" % (len(src), src.count('\n')+1, len(got), got.count('\n')+1))
if src == got:
    print("完全一致 ✅"); sys.exit(0)
lost = src.count('\n') + 1 - (got.count('\n') + 1)
if lost > 0: print("少了 %d 行 ❌（整行被吞）" % lost)
print('\n'.join(list(difflib.unified_diff(src.split('\n'), got.split('\n'), '生成', '键入', lineterm='', n=0))[:16]))
sys.exit(1)
PY

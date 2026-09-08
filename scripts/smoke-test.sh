#!/bin/bash
# 启动已构建的 dist/ScreenAI.app，检查 HTTPS 主端口、HTTP 备用端口与 WebSocket，然后退出应用。
set -uo pipefail
cd "$(dirname "$0")/.."
PORT="${PORT:-8899}"
TLS_DIR="$HOME/Library/Application Support/ScreenAI/tls"
pkill -x ScreenAI 2>/dev/null; sleep 0.5
open dist/ScreenAI.app || exit 1
for i in $(seq 1 30); do
  curl -sk -m 1 "https://127.0.0.1:$PORT/api/status" >/dev/null 2>&1 && break
  sleep 0.5
done
echo "--- 进程 ---"; pgrep -x ScreenAI >/dev/null && echo "ScreenAI 运行中 (pid $(pgrep -x ScreenAI))" || { echo "未启动"; exit 1; }
echo "--- HTTPS GET /api/status (-k) ---"; curl -sk -m 3 "https://127.0.0.1:$PORT/api/status"; echo
echo "--- HTTPS 用根证书校验链 ---"; curl -s -m 3 --cacert "$TLS_DIR/ca.crt.pem" -o /dev/null -w "%{http_code} ssl_verify=%{ssl_verify_result}\n" "https://127.0.0.1:$PORT/"
echo "--- 服务器证书 SAN ---"; echo | /usr/bin/openssl s_client -connect "127.0.0.1:$PORT" -servername localhost 2>/dev/null | /usr/bin/openssl x509 -noout -text 2>/dev/null | grep -A1 "Subject Alternative Name" | tail -1 | sed 's/^ *//'
echo "--- 静态资源（HTTPS）---"
for p in / /app.js /style.css /manifest.json /sw.js /icon.png /screenai-ca.mobileconfig /ca.crt /nope; do
  printf "%-26s %s\n" "$p" "$(curl -sk -o /dev/null -m 3 -w '%{http_code} %{content_type} %{size_download}B' "https://127.0.0.1:$PORT$p")"
done
echo "--- mobileconfig 内容检查 ---"; curl -sk -m 3 "https://127.0.0.1:$PORT/screenai-ca.mobileconfig" | plutil -p - 2>/dev/null | grep -E "PayloadType|PayloadDisplayName" | head -4
echo "--- POST /api/auth 错误码 ---"; curl -sk -m 3 -X POST -H 'Content-Type: application/json' -d '{"code":"000000"}' -w " [%{http_code}]\n" "https://127.0.0.1:$PORT/api/auth"
echo "--- WebSocket (wss) 握手 + auth ---"
python3 - "$PORT" <<'PY'
import socket, ssl, base64, os, json, sys, struct
port = int(sys.argv[1])
ctx = ssl.create_default_context(); ctx.check_hostname = False; ctx.verify_mode = ssl.CERT_NONE
raw = socket.create_connection(("127.0.0.1", port), timeout=5)
s = ctx.wrap_socket(raw, server_hostname="localhost")
key = base64.b64encode(os.urandom(16)).decode()
s.sendall((f"GET /ws HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n").encode())
resp = b""
while b"\r\n\r\n" not in resp:
    chunk = s.recv(4096)
    if not chunk: break
    resp += chunk
head = resp.split(b"\r\n\r\n",1)[0].decode(errors="replace")
print("握手响应:", head.split("\r\n")[0], "| TLS:", s.version())
def send_text(t):
    payload = t.encode(); mask = os.urandom(4)
    hdr = bytes([0x81]) + bytes([0x80|len(payload)])
    s.sendall(hdr + mask + bytes(b ^ mask[i%4] for i,b in enumerate(payload)))
def recv_frame():
    h = s.recv(2)
    if len(h) < 2: return None, None
    op = h[0] & 0x0f; ln = h[1] & 0x7f
    if ln == 126: ln = struct.unpack(">H", s.recv(2))[0]
    data = b""
    while len(data) < ln: data += s.recv(ln-len(data))
    return op, data
send_text(json.dumps({"type":"auth","token":"bad-token"}))
op, data = recv_frame()
print("auth 响应:", op, data.decode(errors="replace"))
s.close()
PY
echo "--- 最近日志 ---"
log show --last 2m --predicate 'subsystem == "com.li.screenai" AND process == "ScreenAI"' --info 2>/dev/null | grep -v "^Timestamp\|^Filtering" | tail -8
pkill -x ScreenAI; sleep 1
pgrep -x ScreenAI >/dev/null && echo "退出失败" || echo "--- 已退出 ---"

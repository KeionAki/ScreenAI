#!/bin/bash
# 创建名为「ScreenAI Dev」的自签名代码签名证书并导入登录钥匙串。
# 目的：让每次重编译后的签名身份保持稳定，避免屏幕录制/钥匙串授权反复弹窗。
# 运行过程中系统会弹出对话框要求输入登录密码（用于信任设置）。
set -euo pipefail
NAME="ScreenAI Dev"
if security find-identity -v -p codesigning | grep -q "\"$NAME\""; then
  echo "证书「$NAME」已存在。"; exit 0
fi
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:false
subjectKeyIdentifier = hash
CNF
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cert.cnf" >/dev/null 2>&1
openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/cert.p12" -passout pass:screenai -name "$NAME" -legacy 2>/dev/null \
  || openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/cert.p12" -passout pass:screenai -name "$NAME"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
security import "$TMP/cert.p12" -k "$KEYCHAIN" -P screenai -T /usr/bin/codesign -T /usr/bin/security
echo "正在设置信任（系统会要求输入登录密码）…"
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem"
echo "完成。之后 scripts/build-app.sh 会自动使用「$NAME」签名。"
security find-identity -v -p codesigning | grep "$NAME" || true

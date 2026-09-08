#!/bin/bash
# 构建 ScreenAI.app（不依赖 Xcode / SwiftPM，仅需 Command Line Tools）
# 用法: scripts/build-app.sh [release|debug]
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
ARCH="${ARCH:-$(uname -m)}"
SDK="$(xcrun --show-sdk-path)"
APP="dist/ScreenAI.app"
BIN="build/ScreenAI-$CONFIG"

mkdir -p build dist
SOURCES=$(find Sources/ScreenAI -name '*.swift' | sort)

if [ "$CONFIG" = "release" ]; then
  OPT=(-O -wmo)
else
  OPT=(-Onone -g)
fi

echo "==> 编译 ($CONFIG, $ARCH)…"
# shellcheck disable=SC2086
swiftc "${OPT[@]}" \
  -target "$ARCH-apple-macos13.0" \
  -sdk "$SDK" \
  -module-name ScreenAI \
  -swift-version 5 \
  -Xlinker -rpath -Xlinker /usr/lib/swift \
  $SOURCES \
  -o "$BIN"

echo "==> 组装 $APP…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/ScreenAI"
cp Resources/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
cp -R Sources/ScreenAI/Web "$APP/Contents/Resources/Web"
if [ -f Resources/AppIcon.icns ]; then
  cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist" >/dev/null 2>&1 || true
fi

IDENTITY="${SCREENAI_SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ] && security find-identity -v -p codesigning 2>/dev/null | grep -q '"ScreenAI Dev"'; then
  IDENTITY="ScreenAI Dev"
fi
if [ -n "$IDENTITY" ]; then
  echo "==> 使用证书「$IDENTITY」签名"
  codesign --force --deep --sign "$IDENTITY" --timestamp=none "$APP"
else
  echo "==> 未找到「ScreenAI Dev」证书，使用 ad-hoc 签名并固定指定要求为 identifier \"com.li.screenai\"，使屏幕录制等授权在重新编译后仍然有效"
  codesign --force --deep --sign - -r '=designated => identifier "com.li.screenai"' "$APP"
fi
codesign --verify --verbose=1 "$APP" 2>&1 | sed 's/^/    /'
codesign -d -r- "$APP" 2>&1 | grep designated | sed 's/^/    /'
echo "==> 完成: $APP"

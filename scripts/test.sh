#!/bin/bash
# 编译并运行单元测试（自带轻量断言框架，不依赖 XCTest）
set -euo pipefail
cd "$(dirname "$0")/.."
SDK="$(xcrun --show-sdk-path)"
ARCH="${ARCH:-$(uname -m)}"
mkdir -p build
SOURCES=$(find Sources/ScreenAI -name '*.swift' ! -name main.swift | sort)
TESTS=$(find Tests/ScreenAITests -name '*.swift' | sort)
echo "==> 编译测试…"
# shellcheck disable=SC2086
swiftc -Onone -g -target "$ARCH-apple-macos13.0" -sdk "$SDK" -module-name ScreenAITests -swift-version 5 $SOURCES $TESTS -o build/ScreenAITests
echo "==> 运行测试…"
SCREENAI_WEB_DIR="$PWD/Sources/ScreenAI/Web" build/ScreenAITests

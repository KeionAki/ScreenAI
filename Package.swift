// swift-tools-version:5.8
// 说明：本机 Swift 5.8 的 SwiftPM 在仅有 Command Line Tools 时无法工作（xcrun PlatformPath 问题，5.9 修复）。
// 日常构建请使用 scripts/build-app.sh（直接调用 swiftc，零第三方依赖）。此文件供升级工具链后使用。
import PackageDescription

let package = Package(
    name: "ScreenAI",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "ScreenAI",
            path: "Sources/ScreenAI",
            resources: [.copy("Web")]
        ),
    ]
)

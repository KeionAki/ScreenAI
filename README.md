# ScreenAI

**中文** · [English](#english)

ScreenAI 是一个运行在 macOS 菜单栏的小工具：按一次全局快捷键截取屏幕，把截图交给多模态大模型识别并解答，结果实时推送到同一 Wi‑Fi 下的 iPhone 网页应用（PWA），电脑端可选置顶字幕窗口，全部分析记录保存为 CSV。

- **一键截图分析**：全局快捷键触发，支持全屏、指定显示器、指定窗口、拖拽区域四种捕获方式。
- **多模型支持**：OpenAI、Anthropic、Google Gemini，以及任意 OpenAI 兼容接口（如 DeepSeek），支持流式输出与思考模式。
- **手机端实时接收**：6 位验证码配对，WebSocket 推送，答案逐字出现，历史记录可查可导出。
- **局域网 HTTPS**：本地根证书一次安装，绕过 iOS 对 http 链接的拦截，并解锁常亮、离线外壳等能力。
- **零依赖、无需 Xcode**：纯 Swift 加 Network.framework 手写 HTTP/WebSocket，仅用 Command Line Tools 即可构建。
- **隐私**：API Key 存钥匙串，截图只在内存中处理，不落盘。

详细设计见 [DESIGN.md](DESIGN.md)。本项目以 [MIT 许可证](LICENSE) 开源。

---

## English

ScreenAI is a macOS menu‑bar utility: press a global hotkey to capture the screen, send the screenshot to a multimodal LLM for recognition and answering, and push the result in real time to an iPhone web app (PWA) on the same Wi‑Fi. An optional always‑on‑top caption panel shows results on the Mac, and every analysis is logged to CSV.

- **One‑key capture & analysis** – global hotkey; capture the full screen, a specific display, a specific window, or a drag‑selected region.
- **Multiple providers** – OpenAI, Anthropic, Google Gemini, and any OpenAI‑compatible endpoint (e.g. DeepSeek), with streaming output and thinking‑mode control.
- **Live delivery to iPhone** – 6‑digit code pairing, WebSocket push, token‑by‑token answers, searchable and exportable history.
- **HTTPS on the LAN** – a locally generated root certificate (installed once on the phone) bypasses iOS blocking of plain‑http links and enables screen wake lock and an offline app shell.
- **Zero dependencies, no Xcode required** – pure Swift with a hand‑written HTTP/WebSocket server on Network.framework; builds with Command Line Tools only.
- **Privacy** – API keys live in the Keychain; screenshots are processed in memory and never written to disk.

Requirements: macOS 13+, Swift 5.8+ Command Line Tools; iPhone with Safari on the same Wi‑Fi. Build with `scripts/build-app.sh`, then `open dist/ScreenAI.app`. The rest of this document is in Chinese; see [DESIGN.md](DESIGN.md) for the architecture. Licensed under the [MIT License](LICENSE).

---

## 环境要求

| 项目 | 要求 |
|---|---|
| 运行 | macOS 13.0+（Apple Silicon 或 Intel） |
| 构建 | 仅需 Xcode Command Line Tools（Swift 5.8+），**不需要 Xcode、不需要第三方依赖** |
| 手机 | iPhone，与 Mac 在同一 Wi‑Fi，使用 Safari |

## 构建与运行

```bash
scripts/build-app.sh            # 生成 dist/ScreenAI.app（release）
open dist/ScreenAI.app
```

调试版并直接启动：

```bash
scripts/run.sh
```

用一张图片代替屏幕截图，走应用内相同的编码与 API 路径做诊断（`--raw` 打印模型原始响应行，API Key 不会输出；首次运行可能弹出钥匙串授权，点「始终允许」）：

```bash
scripts/test-image.sh test_image.jpeg --raw
```

单元测试（自带轻量断言框架，不依赖 XCTest）：

```bash
scripts/test.sh
```

> 为什么不用 `swift build`：本机 Swift 5.8 的 SwiftPM 在只有 Command Line Tools 时会因 `xcrun --show-sdk-platform-path` 失败而无法工作（Swift 5.9 已修复）。`scripts/build-app.sh` 直接调用 `swiftc` 编译全部源码并手工组装 .app，不受此影响。若以后升级到 Xcode 15.2 对应的 Command Line Tools（Swift 5.9.2），`Package.swift` 可直接使用。

### 代码签名与权限保持

构建脚本默认使用 ad-hoc 签名，并把指定要求（Designated Requirement）固定为 `identifier "com.li.screenai"`，因此重新编译后系统仍然认为是同一个应用，已授予的「屏幕录制」权限不会失效。若希望使用真正的证书身份，运行一次下面的脚本创建自签名证书「ScreenAI Dev」，之后构建脚本会自动使用它：

```bash
scripts/make-cert.sh
```

过程中系统会弹窗要求输入登录密码（用于信任该证书）。

## 首次使用

1. 启动后菜单栏出现取景框图标。首次会弹出设置窗口。
2. **API 配置**：选择提供商（OpenAI / Anthropic / Gemini / 自定义 OpenAI 兼容），填写模型与 API Key，点「测试连接」。API Key 保存在钥匙串。
3. **捕获设置**：授予「屏幕录制」权限（系统设置 › 隐私与安全性 › 屏幕录制），选择捕获范围，设置快捷键（默认 ⌘⇧A）。
4. **手机配对**：菜单栏「显示验证码…」，iPhone 用 Safari 打开窗口中显示的地址（可扫二维码），输入 6 位验证码。
5. 按快捷键即可截图分析。结果同时出现在字幕窗口、iPhone 页面，并写入 CSV。

### iPhone 端

- 唯一地址默认为 `https://<主机名>.local:8899/`（如 `https://my-mac.local:8899/`），可在连接设置切换为局域网 IP 形式。不再提供 HTTP 备用端口。
- Mac 连接 Cisco AnyConnect 等企业 VPN 时，VPN 策略常会屏蔽本地网络的 IPv4 访问，IP 地址会打不开，而主机名地址走 IPv6 链路本地仍可用；如需用 IP，请断开 VPN 或在 AnyConnect 偏好中启用「Allow local (LAN) access」（需服务端允许）。
- **首次使用需安装根证书**（iOS 18.2 起 Safari 默认拦截从扫码等外部入口打开的 http 链接，因此主端口使用 HTTPS）：
  1. 扫码打开页面时 Safari 会提示证书不受信任，点「显示详细信息 › 访问此网站」；
  2. 页面弹出引导后点「下载证书描述文件」，允许下载；
  3. 打开「设置」顶部的「已下载描述文件」并安装；
  4. 「设置 › 通用 › 关于本机 › 证书信任设置」中打开「ScreenAI Local CA」的完全信任；
  5. 回到页面点「我已完成，重试连接」。此后地址栏显示锁标志，扫码直达。
- 安装证书后页面可保持屏幕常亮（设置中可关）、支持离线打开外壳。
- 在 Safari 分享菜单选「添加到主屏幕」可全屏使用。注意：主屏幕版本与 Safari 存储相互独立，添加后需再配对一次。
- 验证码 60 秒有效，配对成功后 24 小时内断线重连无需重新输入。
- 页面右上角设置：保留条数、提示音、消息顺序、断开重配。
- 换 Wi‑Fi 后 IP 会变化，重新在菜单栏「显示验证码」扫新二维码即可；服务器证书会自动重新签发并包含新 IP，手机不需要重装证书。

### 使用 DeepSeek 等思考模型

- 提供商选「自定义（OpenAI 兼容）」，端点填 `https://api.deepseek.com`，模型填 `deepseek-v4-flash-vision-exp`。
- DeepSeek 默认开启思考模式，思考内容计入「最大输出 tokens」。建议上限 ≥ 8192，或在 API 设置的「思考模式」中选「关闭」以缩短等待。正文为空时应用会明确提示原因（截断 / 仅有思考内容）。
- 思考期间字幕与手机端显示「思考中… N 字」。
- 模型会把图片缩到约 800×800 像素当量再识别，全屏截图上的小字会不可读，识别题目时建议用「指定区域」或「指定窗口」只截题目。

## 文件位置

| 内容 | 位置 |
|---|---|
| 设置 | `~/Library/Preferences/com.li.screenai.plist`（UserDefaults） |
| API Key | 钥匙串，服务名 `com.li.screenai.apikey` |
| 历史 CSV | 默认 `~/Library/Application Support/ScreenAI/History/yyyy-MM-dd.csv`，可在设置中修改 |
| 提示词全文 | 同目录 `prompts.json`（CSV 中只存哈希） |
| HTTPS 证书 | `~/Library/Application Support/ScreenAI/tls/`（根证书 10 年、服务器证书 800 天，IP 变化自动重签） |

查看日志：

```bash
log stream --predicate 'subsystem == "com.li.screenai"' --level info
```

## 常见问题

- **截图失败 / 提示没有权限**：在「系统设置 › 隐私与安全性 › 屏幕录制」中勾选 ScreenAI，**勾选后必须重新启动 ScreenAI**（设置 › 捕获设置 里有「重新启动 ScreenAI」按钮）。
- **系统设置里已勾选但仍显示未授予**：说明系统记录的是旧版本的签名。在设置 › 捕获设置点「重置权限记录并重新申请」，或在终端执行下面的命令后重新打开应用并允许提示：

  ```bash
  tccutil reset ScreenCapture com.li.screenai
  ```
- **端口被占用**：设置 › 连接设置中修改端口，服务器会自动重启。
- **扫码后提示「导览失败…仅限 HTTPS」**：这是 iOS 拦截 http 链接；使用 HTTPS 地址并按上面的步骤安装根证书即可。
- **页面能打开但一直「重连中」**：根证书未信任，按页面引导安装并在「证书信任设置」中开启完全信任。
- **换了 Wi‑Fi 后无法连接**：Mac IP 变化，扫新二维码；服务器证书会自动包含新 IP，手机不用重装证书。
- **手机打不开页面**：确认同一 Wi‑Fi、Mac 防火墙允许 ScreenAI、地址中端口正确；路由器开启「AP 隔离」时局域网设备互不可见。
- **快捷键无效**：可能与系统或其他应用冲突，在捕获设置中重新录制。
- **模型拒绝或报错**：错误信息会显示在字幕与手机端，并记录到 CSV 的 `error_message` 列。
- **提示「模型未返回内容」或「只返回了思考内容」**：增大「最大输出 tokens」或把「思考模式」设为关闭/低；若服务端忽略流式参数，应用会自动按普通 JSON 解析。

## 项目结构

```
Sources/ScreenAI/
  App/        入口、AppState 总控、菜单栏
  Settings/   设置存储、设置窗口、钥匙串、快捷键录制
  Capture/    CoreGraphics 截图、窗口枚举、区域框选、图像编码
  Hotkey/     Carbon 全局快捷键
  AI/         OpenAI / Anthropic / Gemini 适配、SSE 流式解析
  Pipeline/   截图→编码→AI→事件 的队列流水线
  Dispatch/   消息格式（WebSocket JSON）
  Caption/    置顶字幕窗口
  Pairing/    验证码配对、二维码、配对窗口
  Server/     Network.framework HTTP + WebSocket 服务器、路由
  History/    CSV 历史记录、历史窗口
  Web/        iPhone PWA（HTML/CSS/JS）
Tests/        单元测试
scripts/      构建 / 运行 / 测试 / 证书脚本
```

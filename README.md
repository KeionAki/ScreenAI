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

## 使用说明

### 1. 安装与启动

1. 构建：在项目目录运行 `scripts/build-app.sh`，生成 `dist/ScreenAI.app`；可把它拖到「应用程序」文件夹。
2. 启动后菜单栏出现一个取景框图标，应用没有 Dock 图标，所有操作都从菜单栏进入。
3. 菜单项一览：状态行、启动/停止捕获、显示验证码、断开手机连接、查看历史记录、打开设置、退出。未授予屏幕录制权限时会多出一行警告，点击可直达处理页。

### 2. 首次配置

打开「设置」（菜单栏 › 打开设置…，或快捷键 ⌘,），按以下顺序完成三个页签：

| 页签 | 要做的事 |
|---|---|
| API 配置 | 选择提供商（OpenAI / Anthropic / Gemini / DeepSeek / Kimi / 自定义 OpenAI 兼容），填写模型名与 API Key，点「测试连接」确认可用。API Key 保存在钥匙串。「请求参数」区域会随厂商切换，只显示该厂商支持的参数，每个厂商的参数独立保存。 |
| 捕获设置 | 授予「屏幕录制」权限：点「申请权限」，在系统设置中勾选 ScreenAI，然后点「重新启动 ScreenAI」。要用「分析并键入」还需再授予「辅助功能」权限。选择捕获范围，设置全局快捷键：可选「组合键」（默认 ⌘⇧A）或「单键」（默认 F5，推荐 F 功能键；Mac 键盘 F 键默认为媒体键时需按住 fn，或在系统设置中开启标准功能键）。 |
| 连接设置 | 查看 iPhone 访问地址与服务器状态，通常无需改动。 |

提示词模板可在 API 配置中修改，默认要求模型只输出题目答案；「显示设置」可调整电脑端字幕窗口的样式或关闭它（关闭后只在手机端显示），并可开启「结果自动复制到剪贴板」，分析完成后直接 ⌘V 粘贴答案。

### 3. 手机配对

1. 菜单栏点「显示验证码…」，弹出的窗口显示 6 位验证码、倒计时环、二维码和访问地址。
2. 用 iPhone 相机扫二维码，或在 Safari 输入地址（默认 `https://<主机名>.local:8899/`）。iPhone 与 Mac 必须在同一 Wi‑Fi。
3. 首次打开会提示证书不受信任，这是正常的，只需安装一次根证书：
   1. 点「显示详细信息 › 访问此网站」进入页面；
   2. 页面弹出引导后点「下载证书描述文件」并允许下载；
   3. 打开「设置」顶部的「已下载描述文件」并安装；
   4. 进入「设置 › 通用 › 关于本机 › 证书信任设置」，打开「ScreenAI Local CA」的完全信任；
   5. 回到页面点「我已完成，重试连接」。
4. 输入验证码，Mac 端窗口显示「已成功建立连接」并自动关闭。验证码 60 秒有效，最多 5 次错误尝试；配对成功后 24 小时内断线重连无需再输。
5. 建议在 Safari 分享菜单选「添加到主屏幕」全屏使用。主屏幕版本与 Safari 存储相互独立，添加后需再配对一次。

### 4. 日常使用

- **三个快捷键**：「分析并显示」把答案显示在字幕与手机端；「分析并键入」把代码逐字键入到光标处（见下一节）；「停止键入」随时中断键入。默认分别是 ⌘⇧A、⌘⇧D、⌘⇧. ，单键模式下为 F5、F6、F8。
- **字幕显示规则**：选择题、填空题按「题号. 答案」逐行显示，每题一行；编程题不显示代码，只显示「生成代码中…」「键入中 N%」，完成后显示「已完成」。手机端和 CSV 历史始终保留完整内容。
- **截图分析**：按快捷键即可。字幕窗口和手机端先显示「分析中」或「思考中… N 字」，答案逐字出现；结果同时写入 CSV。连续按键会排队，最多 3 个。
- **捕获范围**：「全屏」截取鼠标所在显示器；「指定窗口」按应用与标题匹配，目标关闭后按设置停止或回退全屏；「指定区域」在设置中点「选择区域…」后拖拽框选，Esc 取消。识别题目时建议只截题目区域，模型看小字更清楚。
- **字幕窗口**：置顶、可拖动、不抢焦点、不会被截进图里。文字可直接选中复制；右上角可清空，跑马灯模式下可暂停。
- **手机端**：最新消息在最上，每条可一键复制；右上角设置可调保留条数、提示音、消息顺序、屏幕常亮，以及断开重新配对。「历史记录」页可按日期浏览、搜索并导出 CSV。
- **历史记录**：菜单栏「查看历史记录…」打开窗口，按日期筛选、搜索、查看完整内容与当时的提示词，可导出所选或清空。
- **定时自动捕获**：捕获设置中开启并设定间隔（最小 3 秒），或在菜单栏「定时捕获」一键开关。默认开启「画面无变化时跳过」，同一画面不会重复请求；上一次分析未结束时到点自动跳过。
- **暂停使用**：菜单栏「停止捕获」后快捷键与定时捕获都不再触发，再点「启动捕获」恢复。
- **换网络**：Mac 的 IP 变化后重新扫一次二维码即可，证书会自动重新签发，手机不用重装。

### 5. 编程题：键入到光标处

「分析并键入」会分析截图中的编程题，提取回答里的代码块，按设定速率逐字键入到当前光标所在的编辑器。

**首次使用前的两步准备：**

1. **授予「辅助功能」权限**：设置 › 捕获设置 › 键入到光标，点「申请权限」，在系统设置中勾选 ScreenAI。
2. **关闭 VSCode 的自动补全括号与引号**，否则逐字键入会产生多余的括号。在 VSCode 的 `settings.json` 中加入（设置面板里有「复制这两行设置」按钮）：

   ```json
   "editor.autoClosingBrackets": "never",
   "editor.autoClosingQuotes": "never",
   ```

   自动缩进不用关，应用会在每次换行后清除编辑器自动插入的缩进，保证代码缩进与模型输出一致。若你把 `editor.autoIndent` 设为 `none`，可在设置里关掉「换行后清除编辑器自动缩进」，键入会更干净。

**使用流程：** 先点进编辑器把光标放好 → 按「分析并键入」快捷键 → 倒计时结束后开始逐字键入 → 需要中断时按「停止键入」。

**可调参数**（设置 › 捕获设置 › 键入到光标）：键入速度（3–80 字符/秒，默认 25）、速度抖动（默认 30%，让节奏更自然）、开始前倒计时（默认 2 秒）、制表符展开空格数。面板上的「测试键入」可以先在编辑器里试一段示例代码。

**安全设计：** 焦点在 ScreenAI 自己的窗口上时会拒绝键入；键入过程中可随时用快捷键或菜单栏停止；只键入代码块内容，模型的解释文字不会被打进去。

### 6. 各厂商的请求参数

「API 配置 › 请求参数」按厂商显示不同的选项，未显示的参数一律不会发送：

| 厂商 | 端点 | 可调参数 | 说明 |
|---|---|---|---|
| DeepSeek | `https://api.deepseek.com` | `max_tokens`、`thinking.type`、`reasoning_effort`（none/low/high/max）、`temperature`、`top_p`、`image_url.detail`（low/high/original） | 模型 `deepseek-flash` 支持图片，`deepseek-v4-pro` 不支持。思考默认开启且计入输出上限，建议 ≥ 8192；思考模式下 temperature 无效。图片会缩到约 1300×1300 当量。 |
| Kimi | `https://api.moonshot.cn/v1` | `max_completion_tokens`、`thinking.type`（仅 k2.6 可关）、`thinking.keep`、`reasoning_effort`（仅 k3：low/high/max） | temperature、top_p、n、penalty 为固定值，传入会报错，因此不发送；图片不支持 detail，分辨率 ≤ 4K；思考模式建议输出上限 ≥ 16000。 |
| OpenAI | `https://api.openai.com/v1` | `max_completion_tokens`、`reasoning_effort`（minimal/low/medium/high）、`temperature`（仅非推理模型）、`image_url.detail`（low/high） | |
| Anthropic | `https://api.anthropic.com` | `max_tokens`、`thinking`（adaptive/disabled）、`output_config.effort`、`temperature`（仅旧模型） | |
| Gemini | `https://generativelanguage.googleapis.com` | `maxOutputTokens`、`thinkingConfig`（3 系列 thinkingLevel，2.5 系列 thinkingBudget）、`temperature`、`topP` | |
| 自定义 | 任意 OpenAI 兼容端点 | 输出上限字段名可选、`thinking`、`reasoning_effort`、`temperature`、`top_p`、`detail`，以及「额外请求体字段」JSON | 额外字段会合并进请求体，可填 `stop`、`response_format` 等。 |

旧版本把 DeepSeek / Kimi 配置在「自定义」里的用户，升级后会自动迁移为对应厂商，API Key 与模型名一并搬运；已下线的 `deepseek-v4-flash-vision-exp` 会改为 `deepseek-flash`。

### 7. 关于访问地址

- 默认使用主机名地址 `https://<主机名>.local:8899/`，可在连接设置切换为局域网 IP 形式。
- Mac 连接 Cisco AnyConnect 等企业 VPN 时，VPN 策略常会屏蔽本地网络的 IPv4 访问，IP 地址会打不开，而主机名地址走 IPv6 链路本地仍可用。如需用 IP，请断开 VPN，或在 AnyConnect 偏好中启用「Allow local (LAN) access」（需服务端允许）。

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
- **提示「模型未返回内容」或「只返回了思考内容」**：在该厂商的请求参数里增大「最大输出 tokens」，或关闭/降低思考；若服务端忽略流式参数，应用会自动按普通 JSON 解析。

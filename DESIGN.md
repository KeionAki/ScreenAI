# ScreenAI 技术设计 v1.1（修订稿）

> 基于《技术设计方案报告 v1.0》与 2026-09-05 评审结论修订。本文件是实现的依据；与 v1.0 冲突处以本文为准。

## 0. 决策记录

| 编号 | 决策 | 结论 |
|---|---|---|
| A | 最低系统版本 | macOS 13.0 |
| B | 截图后端 | CoreGraphics（`CGWindowListCreateImage`），不使用 `SCScreenshotManager` |
| C | 构建工具 | Swift Package Manager + 手工组装 .app；自签名证书签名，缺省回退 ad-hoc |
| D | 流式输出 | v1 支持 SSE 流式，可在设置中关闭 |
| E | 并发 | 分析队列，最多 3 个待处理，串行执行 |
| F | 字幕窗口 | 默认静态换行 + 新消息高亮；跑马灯为可选模式 |
| G | 手机端消息顺序 | 最新在最上 |
| H | 会话 | 单会话 token；新配对撤销旧 token；同一 token 允许多个 WebSocket 通道 |
| I | 依赖 | SwiftNIO（NIO/NIOHTTP1/NIOWebSocket）、KeyboardShortcuts |
| J | 命名 | 应用名 ScreenAI，Bundle ID `com.li.screenai` |
| K | 传输安全（2026-09-05 追加） | 仅 HTTPS 单端口 8899（本地根证书签发，iPhone 一次性安装信任），对外只公布一个地址（默认 `https://<主机名>.local:8899/`，可切换为局域网 IP），不提供 HTTP 备用端口；起因是 iOS 18.2+ Safari「不安全连接警告」拦截外部打开的 http 链接 |

## 1. 环境约束

- 开发机：macOS 13.7.2 / arm64 / Swift 5.8.1 / 仅 Command Line Tools（SDK 13.3），无 Xcode。
- 因此：不使用 Swift 5.9 语法（宏、`@Observable`、if 表达式）；不使用 macOS 14 API；用 `ObservableObject`。
- 打包：`scripts/build-app.sh` 生成 `dist/ScreenAI.app`，`Info.plist` 设 `LSUIElement=true`。
- 签名：存在名为 `ScreenAI Dev` 的自签名代码签名证书时使用它，否则 ad-hoc 并显式指定 `designated => identifier "com.li.screenai"`。TCC 的授权记录绑定指定要求；默认的 ad-hoc 指定要求是 cdhash，每次重编译都会变化导致授权失效，固定为 identifier 后可跨编译保留。
- 权限流程：`CGPreflightScreenCaptureAccess` 为主判断，辅以「能否读到其他进程窗口标题」；在系统设置勾选后进程必须重启才生效，设置页提供「重新启动」与「tccutil reset 后重新申请」。

## 2. 架构

```
快捷键(KeyboardShortcuts/Carbon) ──▶ AnalysisPipeline(队列≤3, 串行)
                                        │ capture: ScreenCapturer(CoreGraphics)
                                        │ encode : ImageEncoder(缩放≤1600px, JPEG 0.85, base64)
                                        │ ai     : AIProvider(OpenAI/Anthropic/Gemini/自定义, SSE)
                                        ▼
                               ResultDispatcher(事件: started/partial/result/error/status)
                     ┌──────────────┼──────────────────┐
              HistoryStore(CSV)  CaptionPanel     LocalServer(SwiftNIO)
                                                       │ HTTP: PWA 静态资源 + /api/*
                                                       │ WS  : /ws（首条消息 auth）
                                                       ▼
                                                  iPhone PWA
```

## 3. 截图（CoreGraphics）

- 统一使用 `CGWindowListCreateImage`：
  - 全屏：鼠标所在显示器，`rect = CGDisplayBounds(displayID)`，`kCGNullWindowID`，`.optionOnScreenOnly`，`.bestResolution`。
  - 指定显示器：同上，固定 displayID。
  - 指定区域：`rect` 为全局 CG 坐标（点），附带 displayID；显示器不存在时按“区域失效行为”处理。
  - 指定窗口：`.optionIncludingWindow` + windowID，`.boundsIgnoreFraming`。
- 坐标：框选时 AppKit 坐标 → CG 全局坐标：`y_cg = 主屏高度 - y_appkit`；截图结果为像素，裁剪由 API 完成，不需要手工乘缩放系数。
- 窗口引用持久化为 `{bundleID, ownerName, title}`，每次捕获前用 `CGWindowListCopyWindowInfo` 重新解析；解析失败按“窗口关闭行为”处理。
- 自身所有窗口 `sharingType = .none`，不会出现在截图中。
- 权限：`CGPreflightScreenCaptureAccess` / `CGRequestScreenCaptureAccess`；设置页提供检查按钮与“打开系统设置”。

## 4. AI 适配层

- `protocol AIProvider { func analyze(request) -> AsyncThrowingStream<AIEvent, Error>; func testConnection(); func listModels() }`
- OpenAI / 自定义：`POST {base}/chat/completions`，`stream:true`，image_url data URL。
- Anthropic：`POST /v1/messages`，`x-api-key` + `anthropic-version: 2023-06-01`，图片块 `{type:image, source:{type:base64, media_type, data}}`，SSE `content_block_delta`。默认模型 `claude-opus-5`。
- Gemini：`:streamGenerateContent?alt=sse`，`x-goog-api-key` 头，`inline_data`。
- 不发送 `temperature`（新模型会拒绝）；`max_tokens` 可配置，默认 8192（思考模型的思考内容计入上限）。
- 流事件 `AIStreamEvent`：`text` / `reasoning` / `finished(reason)`。`reasoning_content` 不展示，只用于「思考中… N 字」进度；`finish_reason == length` 且正文为空时报「输出被截断」，仅有思考内容时报「只返回了思考内容」。
- 厂商种类：openai / anthropic / gemini / deepseek / kimi / custom；后四者中 deepseek、kimi、custom 与 openai 共用 Chat Completions 协议实现，但请求体按厂商组装（`OpenAIProvider.requestBody`）。
- 参数按厂商独立保存（`ProviderParams`：maxTokens / temperature? / topP? / thinking / thinkingKeep / reasoningEffort / imageDetail / maxTokensField / extraJSON），设置面板 `VendorParamsView` 只显示该厂商支持的项：
  - DeepSeek：`max_tokens`、`thinking.type`、`reasoning_effort`（none/low/high/max）、`temperature`/`top_p`（思考模式无效）、`detail`（low/high/original）；penalty 已废弃不发。
  - Kimi：`max_completion_tokens`；k2.6 `thinking.type`，k2.7-code 仅 `{enabled, keep: all}`，k3 `reasoning_effort`（low/high/max）；采样参数为固定值一律不发；图片无 `detail`。
  - OpenAI：`max_completion_tokens`、`reasoning_effort`（minimal…high）、`temperature`（可选）、`detail`（original 映射为 high）。
  - Anthropic：`max_tokens`、`thinking`（adaptive/disabled）、`output_config.effort`。Gemini：`maxOutputTokens`、`thinkingLevel`（3 系列）/`thinkingBudget`（2.5 系列）、`temperature`、`topP`。
  - 自定义：输出上限字段名可选，通用 thinking/effort/采样/detail，额外 JSON 字段合并进请求体。
- 迁移：旧全局 maxTokens/thinkingMode/imageDetail 种子化到各厂商；「自定义」端点指向 deepseek.com / moonshot 时自动迁移为对应厂商并搬运 Key 与模型名。
- SSE 读取必须自行按字节切行并保留空行：Foundation 的 `AsyncLineSequence` 会吞掉空行，而 SSE 以空行分隔事件，使用它会把整条流粘成一个不可解析的块（v1.1 初版的「模型未返回内容」即由此导致）。
- 诊断模式：`ScreenAI --analyze-image <图片> [--raw] [--no-stream] [--prompt …]`，走与快捷键相同的编码与调用路径，逐行打印事件。
- 流式请求若收到非 `text/event-stream` 响应（服务端忽略 stream），自动按普通 JSON 解析；SSE 无任何事件时记录响应片段到日志。
- 错误映射：401→Key 无效；404→模型不存在；429→指数退避重试 3 次；超时→重试 1 次；413/图片过大→降质量重试（0.85→0.6→0.4）。

## 5. 消息协议（WebSocket，JSON）

服务器 → 手机：`analysis_started {id, timestamp, capture_source}`、`analysis_partial {id, delta}`、`analysis_result {id, timestamp, result, capture_source, model, latency_ms, status:"success"}`、`error {id, timestamp, error_message, capture_source}`、`status_change {id, timestamp, message, status}`、`heartbeat {timestamp}`、`auth_ok {expires_at}`、`auth_failed {reason}`。

手机 → 服务器：`auth {token}`（连接后 2 秒内必须发送）、`pong`。

心跳 15 秒；45 秒无 pong 断开。手机端重连退避 2/5/10/30 秒；token 有效期 24 小时，期内重连不需重新输码。

## 6. 配对与安全

- 6 位数字验证码，60 秒有效，最多 5 次错误尝试即作废并重新生成；`/api/auth` 每 IP 每分钟 10 次。
- 验证成功颁发 32 字节随机 token（hex），24 小时；新配对撤销旧 token；“断开连接”撤销 token。
- 服务器仅接受私有网段来源（10/8、172.16/12、192.168/16、fe80::/10、127/8）。
- 配对窗口显示验证码、倒计时环、二维码（内容为访问地址）、`http://<主机名>.local:端口/` 与各 IP 地址。

## 6.1 HTTPS 与证书

- 目录 `~/Library/Application Support/ScreenAI/tls/`：`ca.key.pem`/`ca.crt.pem`/`ca.der`（根证书，10 年）、`server.key.pem`/`server.crt.pem`/`server.p12`（服务器证书，800 天，满足 iOS ≤ 825 天要求）、`server.json`（SAN 与有效期）。
- 用系统自带 `/usr/bin/openssl`（LibreSSL）生成：RSA 2048、SHA-256、EKU serverAuth、SAN 含 `localhost`、`<主机名>.local` 与全部私网 IPv4。
- 服务器身份通过 `SecPKCS12Import` 导入应用私有钥匙串文件 `screenai-tls.keychain-db`，每次启动重建，避免 ad-hoc 签名变化引发授权弹窗；TLS 由 Network.framework `NWProtocolTLS` 提供，最低 TLS 1.2。
- 刷新策略：每 60 秒与唤醒后检查当前地址；服务器证书缺失、30 天内到期或 SAN 未覆盖当前 IP 时自动重新签发并重启 HTTPS 监听，根证书不变。
- iPhone 安装：`GET /screenai-ca.mobileconfig` 返回 `com.apple.security.root` 描述文件（UUID 由根证书指纹派生，幂等）；安装后需在「证书信任设置」开启完全信任。页面在 wss 连续失败且 HTTPS 请求正常时弹出安装引导。
- 不提供 HTTP 备用端口；证书生成失败时主端口退化为 HTTP。对外地址形式可选：主机名（默认，走 mDNS/IPv6 链路本地，不受 AnyConnect 等 VPN 的 IPv4 本地网络屏蔽影响）或局域网 IP；证书 SAN 同时包含主机名与 IP。
- 安全上下文带来的功能：Service Worker 缓存外壳（`/sw.js`，网络优先）、Screen Wake Lock 保持常亮、Clipboard API。

## 6.2 题目识别与结果去向

- **提示词统一处理三种场景**，不由用户切换：逐题分段、跳过被边缘截断或缺选项的题、选择/填空题输出「题号. 答案」每题一行且禁用代码块、编程题只输出一个 ``` 代码块。因此「回答是否含围栏」即为「是否编程题」的判据（`CodeExtractor.containsCodeBlock`）。
- **两段式键入**：分析完成后若回答含代码块，`AppState` 把提取出的代码暂存（`pendingCode`），字幕显示「已完成」；键入由用户按「开始键入代码」快捷键手动触发，不会自动开始。下一次分析若非编程题则清空暂存。
- **字幕规则**：非编程题原样显示「题号. 答案」；编程题（`CaptionEntry.isCode`）不显示代码，依次显示「生成代码中…」「键入中 N%」「已完成」。手机端与 CSV 保留完整内容。
- **快捷键动作**（`HotkeyAction`，Carbon 热键 id 1/2/3）：capture / startTyping / stopTyping，共用一个「组合键或单键」类型开关。

## 6.3 键入到光标（TextTyper）

- 需要「辅助功能」权限（`AXIsProcessTrusted`），与屏幕录制是两项独立授权。
- 用 `CGEvent` + `keyboardSetUnicodeString` 逐字符合成键盘事件，投递到 `.cghidEventTap`；换行用真实回车键（`kVK_Return`）。
- **换行前先按 Esc**（`dismissSuggestions`，默认开）：编辑器默认 `acceptSuggestionOnEnter: "on"`，补全浮层打开时回车会被用来接受补全而不换行；此时后续的「占位字符 + 选到行首」会选中上一整行并被下一行首字符替换，表现为「刚打完的一整行突然消失」。Esc 先关闭浮层可避免。`EditorSimulator` 里用 `suggestOnEnter` 建模了这一行为并作为回归测试。
- **VSCode 适配**：自动补全括号/引号无法在单次按键层面绕开，要求用户在 `settings.json` 中关闭 `editor.autoClosingBrackets` 与 `editor.autoClosingQuotes`。自动缩进由程序处理：换行后先打一个标记字符（保证选区非空，否则空行上的退格会删掉刚建立的换行），再按两次 Shift+Home（VSCode 为智能行首，两次才到第 0 列）选中「缩进 + 标记」，随后键入的第一个字符直接替换选区；空行则用退格删除选区。
- 速率 = 1 / 每秒字符数，乘以 `1 ± jitter` 的随机系数；睡眠分片执行以便及时响应中止。
- 安全：开始前倒计时、焦点在自身窗口时拒绝键入、键入期间挂起截图捕获（`AnalysisPipeline.trigger` 直接返回）、随时可中止、只键入 `CodeExtractor` 提取出的代码。
- 行首选择用 ⌘⇧←（按两次）而非 Shift+Home：Home 在 NSTextView 中是「移到文稿开头」，Shift+Home 会选中整篇并被下一个字符替换。
- 验证：`EditorSimulator` 单测在「有/无自动缩进」两种编辑器模型下回放 `TypingStep`，断言还原出原始代码；`scripts/type-test.sh` 用 `open -n -a` 启动（让 TCC 把辅助功能权限归属给 ScreenAI 而非终端）键入到 TextEdit 并按字节比对。已实测：TextEdit 574 字符 25 行完全还原（唯一差异是 TextEdit 的「自动大写」）；VSCode 在应用推荐设置后逐字节完全一致。`scripts/vscode-type-test.sh` 为 VSCode 版验证脚本。

## 7. HTTP 接口

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/`, `/app.js`, `/style.css`, `/manifest.json`, `/sw.js`, `/icon.png`, `/icon-512.png` | PWA 静态资源（图标运行时生成，sw.js 注入版本号） |
| GET | `/screenai-ca.mobileconfig`, `/ca.crt`, `/ca.pem` | 根证书描述文件 / DER / PEM |
| GET | `/api/status` | `{connected, paired, version}` |
| POST | `/api/auth` | `{code}` → `{success, token, expires_at}` |
| GET | `/api/history/dates` | 有记录的日期列表（需 Bearer） |
| GET | `/api/history?date=&q=&limit=` | 记录 JSON（需 Bearer） |
| GET | `/api/history/export?from=&to=` | 合并 CSV 下载（需 Bearer） |
| GET | `/ws` | WebSocket 升级 |

## 8. CSV 历史

- 目录默认 `~/Library/Application Support/ScreenAI/History/`，可改。
- 文件 `yyyy-MM-dd.csv`，列：`id,timestamp,capture_source,prompt_hash,provider,model,result,status,error_message,latency_ms`。
- `prompts.json` 记录 `prompt_hash → 提示词全文`。
- RFC 4180 引号转义；追加写入并 `synchronize`；写入失败缓存最近 10 条稍后重试。

## 9. 字幕窗口

- `NSPanel` `[.borderless, .nonactivatingPanel]`，`level = .floating`，`[.canJoinAllSpaces, .fullScreenAuxiliary]`，可拖动，位置持久化。
- 静态模式：最新在上、高亮；流式时逐字更新；历史按设置条数保留，越旧越淡。
- 跑马灯模式：仅最新一条滚动，其余静态。
- 透明度、字号、条数由设置控制；提供暂停/清空。

## 10. iPhone PWA

- 纯 HTML/CSS/JS；HTTPS 下注册 Service Worker 缓存外壳，HTTP 下自动跳过。
- 页面：配对页 → 实时页（最新在上，流式填充，复制按钮，提示音）→ 历史页（按日期加载、搜索）。
- token 存 localStorage；独立 PWA 与 Safari 存储隔离，添加到主屏幕后需再配对一次。
- 手机端保留条数为本地设置（默认 100）。

## 11. 默认值

| 项 | 默认 |
|---|---|
| 快捷键 | 分析 ⌘⇧A，开始键入代码 ⌘⇧D，停止键入 ⌘⇧.（单键模式 F5 / F6 / F8） |
| 键入速度 / 抖动 / 倒计时 | 25 字符每秒 / 30% / 2 秒 |
| 捕获范围 | 全屏（鼠标所在显示器） |
| 目标丢失行为 | 停止捕获 |
| 端口 | 8899（HTTPS） |
| 验证码有效期 | 60 秒 |
| API 超时 | 60 秒 |
| 最大输出 tokens | 8192 |
| JPEG 质量 / 最长边 | 0.85 / 1600 px |
| 字幕透明度 / 字号 / 条数 | 90% / 14pt / 5 |
| 防抖 | 300 ms |
| 队列上限 | 3 |

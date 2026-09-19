import SwiftUI
import AppKit

// MARK: - API

struct APISettingsView: View {
    @ObservedObject var state: AppState
    @ObservedObject private var settings: SettingsStore
    @State private var apiKey = ""
    @State private var testing = false
    @State private var testResult = ""
    @State private var models: [String] = []
    @State private var loadingModels = false

    init(state: AppState) {
        self.state = state
        self.settings = state.settings
    }

    private var modelBinding: Binding<String> {
        Binding(get: { settings.currentModel }, set: { settings.currentModel = $0 })
    }

    var body: some View {
        Form {
            Section("提供商") {
                Picker("API 提供商", selection: $settings.apiProvider) {
                    ForEach(AIProviderKind.allCases) { Text($0.displayName).tag($0) }
                }
                if settings.apiProvider == .custom {
                    TextField("API 端点 URL", text: $settings.customEndpoint, prompt: Text("https://host/v1"))
                    Text("填写 OpenAI 兼容接口的基础地址，程序会自动追加 /chat/completions").font(.caption).foregroundColor(.secondary)
                }
                HStack {
                    TextField("模型名称", text: modelBinding, prompt: Text(settings.apiProvider.defaultModel.isEmpty ? "模型名称" : settings.apiProvider.defaultModel))
                    if !models.isEmpty {
                        Menu("选择") {
                            ForEach(models, id: \.self) { m in Button(m) { settings.currentModel = m } }
                        }.frame(width: 80)
                    }
                    Button(loadingModels ? "拉取中…" : "拉取模型列表") { fetchModels() }.disabled(loadingModels)
                }
                Text("常用模型：\(settings.apiProvider.modelHint)").font(.caption).foregroundColor(.secondary)
                SecureKeyField(title: "API Key", value: $apiKey)
                    .onChange(of: apiKey) { settings.setAPIKey($0, for: settings.apiProvider) }
                HStack {
                    Button(testing ? "测试中…" : "测试连接") { testConnection() }.disabled(testing)
                    if testing { ProgressView().controlSize(.small) }
                    Text(testResult).font(.caption).foregroundColor(testResult.hasPrefix("成功") ? .green : .red).lineLimit(2)
                }
            }
            Section("提示词模板") {
                TextEditor(text: $settings.promptTemplate)
                    .font(.body)
                    .frame(minHeight: 110)
                HStack {
                    Button("恢复默认") { settings.promptTemplate = SettingsStore.defaultPrompt }
                    Spacer()
                    Text("\(settings.promptTemplate.count) 字").font(.caption).foregroundColor(.secondary)
                }
            }
            Section("请求参数 · \(settings.apiProvider.displayName)") {
                Toggle("流式输出（答案逐字出现）", isOn: $settings.streamingEnabled)
                VendorParamsView(settings: settings, kind: settings.apiProvider, model: settings.currentModel)
            }
            Section("截图") {
                LabeledContent("截图最长边（像素）") {
                    TextField("", value: $settings.maxImageLongEdge, format: .number).frame(width: 80)
                }
                LabeledContent("JPEG 质量 \(String(format: "%.2f", settings.jpegQuality))") {
                    Slider(value: $settings.jpegQuality, in: 0.3...1.0, step: 0.05).frame(width: 180)
                }
                Text("多数模型会把图片缩到约 800–1600 像素当量再识别，全屏截图上的小字可能不可读；识别题目时建议用「指定区域」或「指定窗口」只截题目部分。")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { apiKey = settings.apiKey(for: settings.apiProvider) }
        .onChange(of: settings.apiProvider) { kind in
            apiKey = settings.apiKey(for: kind)
            models = []
            testResult = ""
        }
    }

    private func currentProvider() -> AIProvider {
        AIProviderFactory.make(ProviderConfig(kind: settings.apiProvider, apiKey: settings.apiKey(for: settings.apiProvider), endpoint: settings.currentEndpoint))
    }

    private func testConnection() {
        testing = true
        testResult = ""
        let provider = currentProvider()
        let model = settings.currentModel
        let timeout = min(60, settings.apiTimeout)
        let params = settings.currentParams
        Task { @MainActor in
            do {
                let r = try await provider.testConnection(model: model, timeout: timeout, params: params)
                if !r.text.isEmpty {
                    testResult = "成功：模型回复「\(r.text.truncated(60))」"
                } else if r.reasoningChars > 0 {
                    testResult = "接口可用，但模型只返回了 \(r.reasoningChars) 字思考内容、正文为空：请增大「最大输出 tokens」或关闭思考模式"
                } else {
                    testResult = "接口可用，但模型未返回文本"
                }
            } catch {
                testResult = "失败：\(error.localizedDescription)"
            }
            testing = false
        }
    }

    private func fetchModels() {
        loadingModels = true
        let provider = currentProvider()
        Task { @MainActor in
            do {
                models = try await provider.listModels(timeout: 30)
                if models.isEmpty { testResult = "未获取到模型" }
            } catch {
                testResult = "拉取模型失败：\(error.localizedDescription)"
            }
            loadingModels = false
        }
    }
}

// MARK: - Capture

struct CaptureSettingsView: View {
    @ObservedObject var state: AppState
    @ObservedObject private var settings: SettingsStore
    @State private var hasPermission = ScreenCapturer.effectivePermission()
    @State private var permissionMessage = ""
    @State private var hasAccessibility = TextTyper.hasPermission()
    @State private var typingMessage = ""
    @State private var displays: [DisplayInfo] = []
    @State private var windows: [WindowInfo] = []
    private let permissionTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    init(state: AppState) {
        self.state = state
        self.settings = state.settings
    }

    var body: some View {
        Form {
            Section("屏幕录制权限") {
                HStack {
                    Image(systemName: hasPermission ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundColor(hasPermission ? .green : .orange)
                    Text(hasPermission ? "已授予屏幕录制权限" : "未授予屏幕录制权限，截图会失败")
                    Spacer()
                    Button("重新检查") { checkPermission() }
                }
                if !hasPermission {
                    Text("步骤：1) 点「申请权限」或「打开系统设置」，在「隐私与安全性 › 屏幕录制」中勾选 ScreenAI；2) 勾选后必须点「重新启动 ScreenAI」才会生效。")
                        .font(.caption).foregroundColor(.secondary)
                    HStack {
                        Button("申请权限") { ScreenCapturer.requestPermission(); checkPermission() }
                        Button("打开系统设置") { ScreenCapturer.openPrivacySettings() }
                        Button("重置权限记录并重新申请") { resetPermission() }
                    }
                    Text("如果系统设置里已经勾选却仍显示未授予：通常是 ScreenAI 重新编译后被系统当作新应用。点「重置权限记录并重新申请」，在系统提示中允许，再点「重新启动 ScreenAI」。")
                        .font(.caption).foregroundColor(.secondary)
                }
                HStack {
                    Button("重新启动 ScreenAI") { PermissionHelper.relaunch() }.disabled(!PermissionHelper.isBundled)
                    if !permissionMessage.isEmpty { Text(permissionMessage).font(.caption).foregroundColor(.secondary) }
                }
            }
            Section("捕获范围") {
                Picker("范围", selection: $settings.captureScope) {
                    ForEach(CaptureScope.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.radioGroup)
                switch settings.captureScope {
                case .fullScreen:
                    Text("按下快捷键时，捕获鼠标所在的整个显示器。").font(.caption).foregroundColor(.secondary)
                case .display:
                    HStack {
                        Picker("显示器", selection: $settings.selectedDisplayID) {
                            ForEach(displays) { Text($0.displayName).tag($0.id) }
                        }
                        Button("刷新") { refreshDisplays() }
                    }
                case .window:
                    HStack {
                        Picker("窗口", selection: $settings.selectedWindow) {
                            Text("未选择").tag(WindowRef?.none)
                            ForEach(windows) { w in Text(w.displayName.truncated(70)).tag(Optional(w.ref)) }
                        }
                        Button("刷新") { refreshWindows() }
                    }
                    if let ref = settings.selectedWindow {
                        Text("已选择：\(ref.displayName)").font(.caption).foregroundColor(.secondary)
                    }
                case .region:
                    HStack {
                        Text(settings.selectedRegion?.displayName ?? "未选择区域")
                        Spacer()
                        Button("选择区域…") {
                            RegionSelector.begin { region in
                                if let r = region { settings.selectedRegion = r }
                            }
                        }
                    }
                }
            }
            Section("全局快捷键") {
                Picker("快捷键类型", selection: $settings.hotkeyMode) {
                    Text("组合键（含 ⌘/⌃/⌥）").tag("combo")
                    Text("单键（如 F5）").tag("single")
                }
                .pickerStyle(.segmented)
                .onChange(of: settings.hotkeyMode) { mode in
                    if mode == "single" {
                        if !settings.hotkey.isSingleKey { settings.hotkey = .defaultSingle }
                        if !settings.typeHotkey.isSingleKey { settings.typeHotkey = .defaultTypeSingle }
                        if !settings.stopHotkey.isSingleKey { settings.stopHotkey = .defaultStopSingle }
                    } else {
                        if settings.hotkey.isSingleKey { settings.hotkey = .default }
                        if settings.typeHotkey.isSingleKey { settings.typeHotkey = .defaultType }
                        if settings.stopHotkey.isSingleKey { settings.stopHotkey = .defaultStop }
                    }
                }
                HStack {
                    Text("分析并显示")
                    Spacer()
                    HotkeyRecorderView(hotkey: $settings.hotkey, allowSingleKey: settings.hotkeyMode == "single").frame(width: 160, height: 24)
                    Button("恢复默认") { settings.hotkey = settings.hotkeyMode == "single" ? .defaultSingle : .default }
                }
                HStack {
                    Text("分析并键入到光标")
                    Spacer()
                    HotkeyRecorderView(hotkey: $settings.typeHotkey, allowSingleKey: settings.hotkeyMode == "single").frame(width: 160, height: 24)
                    Button("恢复默认") { settings.typeHotkey = settings.hotkeyMode == "single" ? .defaultTypeSingle : .defaultType }
                }
                HStack {
                    Text("停止键入")
                    Spacer()
                    HotkeyRecorderView(hotkey: $settings.stopHotkey, allowSingleKey: settings.hotkeyMode == "single").frame(width: 160, height: 24)
                    Button("恢复默认") { settings.stopHotkey = settings.hotkeyMode == "single" ? .defaultStopSingle : .defaultStop }
                }
                if settings.hotkeyMode == "single" {
                    Text("点击输入框后按下一个按键即可。推荐 F1–F19 或数字小键盘；Mac 键盘的 F 键默认是亮度、音量等媒体键，需按住 fn 再按，或在「系统设置 › 键盘 › 键盘快捷键 › 功能键」中开启「将 F1、F2 等键用作标准功能键」。空格、回车、Tab、删除、Esc 不能作为单键。")
                        .font(.caption).foregroundColor(.secondary)
                }
                if let warning = settings.hotkey.singleKeyWarning {
                    Text(warning).font(.caption).foregroundColor(.orange)
                }
                if let err = state.hotkeyError {
                    Text(err).font(.caption).foregroundColor(.red)
                }
                Stepper("防抖间隔：\(settings.debounceMs) ms", value: $settings.debounceMs, in: 100...2000, step: 100)
            }
            Section("定时自动捕获") {
                Toggle("按固定间隔自动截图分析", isOn: $settings.autoCaptureEnabled)
                LabeledContent("间隔（秒）") {
                    HStack {
                        TextField("", value: $settings.autoCaptureInterval, format: .number).frame(width: 70)
                        Stepper("", value: $settings.autoCaptureInterval, in: 3...3600, step: 5).labelsHidden()
                    }
                }
                Toggle("画面无变化时跳过（节省 API 调用）", isOn: $settings.autoCaptureSkipUnchanged)
                Text("最小 3 秒。上一次分析尚未结束时，到点会自动跳过等下一周期；定时产生的记录在来源中标注「定时」。菜单栏也可随时开关。")
                    .font(.caption).foregroundColor(.secondary)
            }
            Section("键入到光标（编程题）") {
                HStack {
                    Image(systemName: hasAccessibility ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundColor(hasAccessibility ? .green : .orange)
                    Text(hasAccessibility ? "已授予「辅助功能」权限" : "未授予「辅助功能」权限，无法键入")
                    Spacer()
                    Button("重新检查") { hasAccessibility = TextTyper.hasPermission() }
                    if !hasAccessibility {
                        Button("申请权限") { TextTyper.requestPermission(); hasAccessibility = TextTyper.hasPermission() }
                        Button("打开系统设置") { TextTyper.openAccessibilitySettings() }
                    }
                }
                LabeledContent("键入速度 \(Int(settings.typingCPS)) 字符/秒") {
                    Slider(value: $settings.typingCPS, in: 3...80, step: 1).frame(width: 200)
                }
                LabeledContent("速度抖动 \(Int(settings.typingJitter * 100))%") {
                    Slider(value: $settings.typingJitter, in: 0...0.8, step: 0.05).frame(width: 200)
                }
                LabeledContent("开始前倒计时 \(String(format: "%.1f", settings.typingCountdown)) 秒") {
                    Slider(value: $settings.typingCountdown, in: 0...10, step: 0.5).frame(width: 200)
                }
                Toggle("换行后清除编辑器自动缩进", isOn: $settings.typingClearAutoIndent)
                LabeledContent("制表符展开为空格数") {
                    Stepper("\(settings.typingTabWidth)", value: $settings.typingTabWidth, in: 1...8)
                }
                HStack {
                    Button(TextTyper.shared.isTyping ? "键入中…" : "测试键入") { testTyping() }
                        .disabled(!hasAccessibility)
                    Button("停止键入") { state.stopTyping() }
                    if !typingMessage.isEmpty { Text(typingMessage).font(.caption).foregroundColor(.secondary) }
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("使用前请在 VSCode 中关闭自动补全括号与引号，否则逐字键入会产生多余的括号：")
                        .font(.caption).foregroundColor(.secondary)
                    Text("\"editor.autoClosingBrackets\": \"never\"\n\"editor.autoClosingQuotes\": \"never\"")
                        .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    HStack {
                        Button("复制这两行设置") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString("\"editor.autoClosingBrackets\": \"never\",\n\"editor.autoClosingQuotes\": \"never\",", forType: .string)
                            typingMessage = "已复制，粘贴到 VSCode 的 settings.json"
                        }.controlSize(.small)
                    }
                    Text("流程：先点进编辑器把光标放好，再按「分析并键入」快捷键；倒计时结束后开始逐字键入，按「停止键入」可随时中断。答案中的代码块会被自动提取，只键入代码本身。")
                        .font(.caption).foregroundColor(.secondary)
                }
            }
            Section("目标丢失时的行为") {
                Picker("窗口关闭时", selection: $settings.windowLossBehavior) {
                    ForEach(TargetLossBehavior.allCases) { Text($0.displayName).tag($0) }
                }
                Picker("显示器断开时", selection: $settings.displayLossBehavior) {
                    ForEach(TargetLossBehavior.allCases) { Text($0.displayName).tag($0) }
                }
                Picker("区域失效时", selection: $settings.regionLossBehavior) {
                    ForEach(TargetLossBehavior.allCases) { Text($0.displayName).tag($0) }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            checkPermission()
            hasAccessibility = TextTyper.hasPermission()
            refreshDisplays()
            refreshWindows()
        }
        .onReceive(permissionTimer) { _ in
            let ax = TextTyper.hasPermission()
            if ax != hasAccessibility { hasAccessibility = ax }
            let now = ScreenCapturer.effectivePermission()
            if now != hasPermission {
                hasPermission = now
                state.menuBar?.refresh()
            }
        }
    }

    private func checkPermission() {
        hasPermission = ScreenCapturer.effectivePermission()
        state.menuBar?.refresh()
        if !hasPermission && CGPreflightScreenCaptureAccess() == false {
            permissionMessage = ""
        }
    }

    private func testTyping() {
        typingMessage = "\(Int(settings.typingCountdown)) 秒后开始，请把光标放到编辑器里"
        let sample = "def solve(nums):\n    total = 0\n    for n in nums:\n        total += n\n\n    return total\n"
        TextTyper.shared.type(sample, options: settings.typingOptions)
    }

    private func resetPermission() {
        let result = PermissionHelper.resetScreenCaptureRecord()
        if result.ok {
            permissionMessage = "已重置授权记录，请在系统提示中允许，然后重新启动 ScreenAI"
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                ScreenCapturer.requestPermission()
                checkPermission()
            }
        } else {
            permissionMessage = "重置失败：\(result.output.isEmpty ? "未知错误" : result.output)。可在终端执行：tccutil reset ScreenCapture com.li.screenai"
        }
    }

    private func refreshDisplays() {
        displays = ScreenCapturer.displays()
        if !displays.contains(where: { $0.id == settings.selectedDisplayID }), let first = displays.first {
            settings.selectedDisplayID = first.id
        }
    }

    private func refreshWindows() {
        windows = WindowEnumerator.list()
    }
}

// MARK: - Display

struct DisplaySettingsView: View {
    @ObservedObject var state: AppState
    @ObservedObject private var settings: SettingsStore

    init(state: AppState) {
        self.state = state
        self.settings = state.settings
    }

    var body: some View {
        Form {
            Section("电脑端字幕窗口") {
                Picker("显示方式", selection: $settings.captionMode) {
                    ForEach(CaptionMode.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.radioGroup)
                LabeledContent("透明度 \(Int(settings.captionOpacity * 100))%") {
                    Slider(value: $settings.captionOpacity, in: 0.2...1.0).frame(width: 200)
                }
                LabeledContent("文字大小 \(Int(settings.captionFontSize)) pt") {
                    Slider(value: $settings.captionFontSize, in: 10...24, step: 1).frame(width: 200)
                }
                Stepper("保留条数：\(settings.captionHistoryCount)", value: $settings.captionHistoryCount, in: 1...20)
                LabeledContent("窗口宽度 \(Int(settings.captionWidth)) pt") {
                    Slider(value: $settings.captionWidth, in: 100...800, step: 10).frame(width: 200)
                }
                LabeledContent("窗口高度 \(Int(settings.captionHeight)) pt") {
                    Slider(value: $settings.captionHeight, in: 60...1000, step: 10).frame(width: 200)
                }
                Text("窗口大小固定，内容超出时在窗口内滚动，输出过程中不会改变窗口尺寸。").font(.caption).foregroundColor(.secondary)
                Button("重置窗口位置") { state.captionPanel.resetPosition() }
            }
            Section("结果输出") {
                Toggle("结果自动复制到剪贴板", isOn: $settings.autoCopyToClipboard)
                Text("开启后每次分析完成，答案文本会自动写入剪贴板，可直接 ⌘V 粘贴；会覆盖剪贴板原有内容。").font(.caption).foregroundColor(.secondary)
            }
            Section("手机端") {
                Text("手机端消息保留条数与提示音在 iPhone 页面右上角的设置中调整。").font(.caption).foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Connection

struct ConnectionSettingsView: View {
    @ObservedObject var state: AppState
    @ObservedObject private var settings: SettingsStore
    @ObservedObject private var pairing: PairingManager
    @State private var certMessage = ""

    init(state: AppState) {
        self.state = state
        self.settings = state.settings
        self.pairing = state.pairing
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    var body: some View {
        Form {
            Section("服务器") {
                LabeledContent("HTTPS 端口") {
                    TextField("", value: $settings.listenPort, format: .number.grouping(.never)).frame(width: 90)
                }
                HStack {
                    Circle().fill(state.serverRunning ? Color.green : Color.red).frame(width: 8, height: 8)
                    Text(state.serverRunning ? (state.server.isTLS ? "HTTPS 运行中（端口 \(state.httpsPort)）" : "HTTP 运行中（端口 \(state.httpsPort)，证书不可用）") : (state.serverError ?? "未运行"))
                    Spacer()
                    Button("重启服务器") { state.restartServer() }
                }
                if let e = state.tlsError { Text(e).font(.caption).foregroundColor(.red) }
                Picker("地址形式", selection: $settings.addressMode) {
                    Text("主机名（<主机名>.local）").tag("hostname")
                    Text("局域网 IP").tag("ip")
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("iPhone 访问地址（二维码使用）").font(.caption).foregroundColor(.secondary)
                    Text(state.primaryURL()).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    Text(settings.addressMode == "ip"
                         ? "局域网 IPv4 地址。Mac 连着 VPN（如 Cisco AnyConnect）且策略禁止本地网络访问时，此地址会无法连接，请改用主机名。"
                         : "主机名通过 mDNS 解析，通常走 IPv6 链路本地地址，不受 VPN 的 IPv4 过滤影响；iPhone 与 Mac 需在同一 Wi‑Fi。")
                        .font(.caption).foregroundColor(.secondary)
                }
            }
            Section("HTTPS 证书") {
                if let fp = state.certs.caFingerprint {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("根证书：\(state.certs.caInfo?.commonName ?? "ScreenAI Local CA")")
                        Text("SHA-256 指纹：\(fp)").font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        if let ca = state.certs.caInfo {
                            Text("根证书有效期至 \(ConnectionSettingsView.dateFormatter.string(from: ca.notAfter))").font(.caption).foregroundColor(.secondary)
                        }
                        if let info = state.certs.serverInfo {
                            Text("服务器证书有效期至 \(ConnectionSettingsView.dateFormatter.string(from: info.notAfter))，地址：\(info.sans.joined(separator: "、"))")
                                .font(.caption).foregroundColor(.secondary)
                        }
                    }
                } else {
                    Text("尚未生成证书").foregroundColor(.secondary)
                }
                HStack {
                    Button("重新签发服务器证书") { state.regenerateServerCertificate(); certMessage = "已重新签发服务器证书" }
                    Button("重置根证书…") { resetRoot() }
                    Button("导出根证书…") { exportRoot() }
                    Button("打开证书目录") { NSWorkspace.shared.open(state.certs.directory) }
                }
                if !certMessage.isEmpty { Text(certMessage).font(.caption).foregroundColor(.secondary) }
                Text("iPhone 首次使用需安装并信任根证书（页面内有引导，或访问 /screenai-ca.mobileconfig）。重置根证书后所有手机需重新安装。换 Wi‑Fi 导致 IP 变化时服务器证书会自动重新签发，手机无需操作。")
                    .font(.caption).foregroundColor(.secondary)
            }
            Section("手机连接") {
                HStack {
                    Circle().fill(state.connectedClients > 0 ? Color.green : Color.gray).frame(width: 8, height: 8)
                    if state.connectedClients > 0, let s = pairing.session {
                        Text("已连接：\(s.clientAddress)，通道 \(state.connectedClients)")
                    } else if let s = pairing.session {
                        Text("已配对（\(s.clientAddress)），等待手机重连；token 有效至 \(s.expiresAt.formatted(date: .abbreviated, time: .shortened))")
                    } else {
                        Text("未连接")
                    }
                }
                HStack {
                    Button("显示验证码…") { state.showPairing() }
                    Button("断开连接") { state.disconnectPhone() }.disabled(pairing.session == nil && state.connectedClients == 0)
                }
                Text("验证码 60 秒有效，最多 5 次错误尝试；配对成功后 24 小时内手机重连无需再次输入。").font(.caption).foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func resetRoot() {
        let alert = NSAlert()
        alert.messageText = "重置根证书？"
        alert.informativeText = "将生成新的根证书与服务器证书，所有已配对的 iPhone 需要重新安装并信任新证书。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "重置")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn {
            state.resetRootCertificate()
            certMessage = "已重置根证书"
        }
    }

    private func exportRoot() {
        guard let der = state.certs.caCertificateDER else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "screenai-ca.crt"
        if panel.runModal() == .OK, let url = panel.url {
            do { try der.write(to: url); certMessage = "已导出到 \(url.path)" } catch { certMessage = "导出失败：\(error.localizedDescription)" }
        }
    }
}

// MARK: - History

struct HistorySettingsView: View {
    @ObservedObject var state: AppState
    @ObservedObject private var settings: SettingsStore
    @State private var message = ""

    init(state: AppState) {
        self.state = state
        self.settings = state.settings
    }

    var body: some View {
        Form {
            Section("CSV 保存目录") {
                Text(settings.historyDirectory).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                HStack {
                    Button("选择目录…") { chooseDirectory() }
                    Button("恢复默认") { settings.historyDirectory = SettingsStore.defaultHistoryDirectory.path }
                    Button("在访达中显示") { NSWorkspace.shared.open(settings.historyDirectoryURL) }
                }
                Text("每天一个 CSV 文件；提示词全文记录在 prompts.json 中，CSV 只保存其哈希。").font(.caption).foregroundColor(.secondary)
            }
            Section("记录") {
                HStack {
                    Button("查看历史记录…") { state.showHistory() }
                    Button("导出全部…") { exportAll() }
                    Button("清空历史记录…") { clearAll() }
                }
                if !message.isEmpty { Text(message).font(.caption).foregroundColor(.secondary) }
            }
        }
        .formStyle(.grouped)
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = settings.historyDirectoryURL
        if panel.runModal() == .OK, let url = panel.url {
            settings.historyDirectory = url.path
        }
    }

    private func exportAll() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "screenai-history.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        if panel.runModal() == .OK, let url = panel.url {
            let csv = "\u{FEFF}" + state.history.exportCSV(dates: state.history.dates())
            do {
                try csv.write(to: url, atomically: true, encoding: .utf8)
                message = "已导出到 \(url.path)"
            } catch {
                message = "导出失败：\(error.localizedDescription)"
            }
        }
    }

    private func clearAll() {
        let alert = NSAlert()
        alert.messageText = "清空全部历史记录？"
        alert.informativeText = "将删除目录中所有按日期命名的 CSV 文件，此操作不可撤销。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "清空")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn {
            do {
                try state.history.clearAll()
                message = "历史记录已清空"
            } catch {
                message = "清空失败：\(error.localizedDescription)"
            }
        }
    }
}

// MARK: - About

struct AboutView: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("ScreenAI").font(.title.bold())
            Text("版本 \(AppRouter.version)")
            Text("屏幕内容 AI 分析与手机推送：按快捷键截图 → 多模态模型解答 → 局域网推送到 iPhone。")
            Divider()
            Text("使用步骤").font(.headline)
            Text("1. 在「API 配置」填写 API Key 并测试连接。\n2. 在「捕获设置」授予屏幕录制权限，设定范围与快捷键。\n3. 菜单栏点击「显示验证码」，iPhone 用 Safari 打开地址并输入验证码。\n4. 按快捷键即可分析当前屏幕。")
            Divider()
            Text("Bundle ID：com.li.screenai").font(.caption).foregroundColor(.secondary)
            if let host = NetworkInfo.localHostname() {
                Text("主机名：\(host).local").font(.caption).foregroundColor(.secondary)
            }
        }
    }
}

import Foundation
import AppKit
import Combine
import Security

/// 应用总控：把设置、流水线、配对、服务器、字幕窗口串起来。仅在主线程使用。
final class AppState: ObservableObject {
    static let shared = AppState()

    let settings = SettingsStore.shared
    let history: HistoryStore
    let pipeline: AnalysisPipeline
    let pairing = PairingManager()
    let hub = WebSocketHub()
    let caption = CaptionModel()
    let certs: CertificateManager
    /// 唯一监听端口：HTTPS（证书失败时退化为 HTTP）
    let server: LocalServer
    let router: AppRouter

    @Published var serverRunning = false
    @Published var serverError: String?
    @Published var tlsError: String?
    @Published var connectedClients = 0
    @Published var lastStatus = ""
    @Published var hotkeyError: String?
    @Published var typingProgress: String?
    /// 最近一次分析得到的、等待键入的代码（编程题）
    @Published private(set) var pendingCodeSummary: String?
    @Published var analyzingCount = 0

    private var cancellables = Set<AnyCancellable>()
    private var certTimer: Timer?
    private var autoCaptureTimer: Timer?
    private var typingJobID: String?
    private var pendingCode: String?
    private var pendingCodeJobID: String?
    var menuBar: MenuBarController?
    lazy var captionPanel = CaptionPanelController(model: caption, settings: settings)
    lazy var pairingWindow = PairingWindowController(state: self)
    lazy var settingsWindow = SettingsWindowController(state: self)
    lazy var historyWindow = HistoryWindowController(state: self)

    static var tlsDirectory: URL {
        SettingsStore.defaultHistoryDirectory.deletingLastPathComponent().appendingPathComponent("tls", isDirectory: true)
    }

    private init() {
        history = HistoryStore(directory: settings.historyDirectoryURL)
        pipeline = AnalysisPipeline(settings: settings, history: history)
        router = AppRouter(pairing: pairing, history: history, hub: hub)
        certs = CertificateManager(directory: AppState.tlsDirectory)
        server = LocalServer(port: UInt16(clamping: settings.listenPort), hub: hub)
    }

    // MARK: Lifecycle

    func start() {
        let pairing = self.pairing

        HotkeyManager.shared.onTrigger = { [weak self] action in self?.handleHotkey(action) }
        registerAllHotkeys()
        setupTyping()

        pipeline.onEvent = { [weak self] e in self?.handle(e) }
        pipeline.onCaptureDisabled = { [weak self] in self?.menuBar?.refresh() }

        hub.authenticate = { token in pairing.isValid(token: token) }
        hub.authOKPayload = { .authOK(expiresAt: pairing.currentSession?.expiresAt ?? Date()) }
        hub.onAuthenticatedCountChanged = { [weak self] n in
            self?.connectedClients = n
            pairing.setConnectedClients(n)
            self?.caption.phoneConnected = n > 0
            self?.menuBar?.refresh()
        }

        router.certificates = certs
        router.statusProvider = { [weak self] in self?.statusDictionary() ?? [:] }
        server.httpHandler = router.handler()
        server.onFailure = { [weak self] msg in
            self?.serverError = msg
            self?.serverRunning = false
            self?.handle(.status(message: msg, level: "warning"))
        }
        server.onStateChange = { [weak self] s in
            self?.serverRunning = (s == "running")
            if s == "running" { self?.serverError = nil }
            self?.menuBar?.refresh()
        }
        startServer()

        history.onWriteError = { [weak self] msg in
            DispatchQueue.main.async { self?.handle(.status(message: "历史记录写入失败：\(msg)", level: "warning")) }
        }

        updateCaptionVisibility()
        observeSettings()

        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                if !self.server.isRunning { self.startServer() } else { self.refreshCertificatesIfNeeded() }
            }
        }
        certTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.refreshCertificatesIfNeeded() }
        rescheduleAutoCapture()

        if !ScreenCapturer.hasPermission() {
            ScreenCapturer.requestPermission()
        }
        Log.app.info("ScreenAI 已启动")
    }

    func shutdown() {
        HotkeyManager.shared.unregisterAll()
        TextTyper.shared.abort()
        certTimer?.invalidate()
        autoCaptureTimer?.invalidate()
        hub.stop()
        server.stop()
        captionPanel.hide()
        Log.app.info("ScreenAI 已退出")
    }

    private func observeSettings() {
        settings.$hotkey.dropFirst().removeDuplicates()
            .sink { [weak self] hk in self?.register(hk, for: .capture) }.store(in: &cancellables)
        settings.$typeHotkey.dropFirst().removeDuplicates()
            .sink { [weak self] hk in self?.register(hk, for: .startTyping) }.store(in: &cancellables)
        settings.$stopHotkey.dropFirst().removeDuplicates()
            .sink { [weak self] hk in self?.register(hk, for: .stopTyping) }.store(in: &cancellables)
        settings.$listenPort.dropFirst().removeDuplicates()
            .debounce(for: .seconds(1), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.restartServer() }.store(in: &cancellables)
        // 注意：@Published 在赋值前发出通知，必须用通知携带的新值，不能回读属性
        settings.$captionMode.dropFirst().removeDuplicates()
            .sink { [weak self] mode in self?.updateCaptionVisibility(mode: mode) }.store(in: &cancellables)
        settings.$historyDirectory.dropFirst().removeDuplicates()
            .sink { [weak self] p in self?.history.setDirectory(URL(fileURLWithPath: p, isDirectory: true)) }.store(in: &cancellables)
        settings.$captureEnabled.dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.menuBar?.refresh() }.store(in: &cancellables)
        settings.$autoCaptureEnabled.dropFirst().removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.rescheduleAutoCapture() }.store(in: &cancellables)
        settings.$autoCaptureInterval.dropFirst().removeDuplicates()
            .debounce(for: .seconds(0.5), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.rescheduleAutoCapture() }.store(in: &cancellables)
        pairing.$session.receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.menuBar?.refresh() }.store(in: &cancellables)
    }

    // MARK: Events

    private func handle(_ e: PipelineEvent) {
        caption.apply(e, maxCount: settings.captionHistoryCount)
        if let m = e.serverMessage { hub.broadcast(m) }
        switch e {
        case let .status(message, _): lastStatus = message
        case let .failed(_, message, _): lastStatus = message
        case let .completed(id, text, _, _, _):
            copyToClipboardIfEnabled(text)
            bufferCode(jobID: id, answer: text)
        default: break
        }
        analyzingCount = pipeline.queueCount
        menuBar?.refresh()
    }

    // MARK: Actions

    func toggleCapture() {
        settings.captureEnabled.toggle()
        menuBar?.refresh()
    }

    func showPairing() { pairingWindow.show() }
    func showSettings(_ tab: SettingsTab? = nil) { settingsWindow.show(tab: tab) }
    func showHistory() { historyWindow.show() }

    func disconnectPhone() {
        pairing.revokeSession()
        hub.disconnectAll(reason: "disconnected by user")
        menuBar?.refresh()
    }

    func quit() {
        shutdown()
        NSApp.terminate(nil)
    }

    // MARK: 定时自动捕获

    func rescheduleAutoCapture() {
        autoCaptureTimer?.invalidate()
        autoCaptureTimer = nil
        guard settings.autoCaptureEnabled else { menuBar?.refresh(); return }
        let interval = max(3, settings.autoCaptureInterval)
        let t = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            guard let self = self, self.settings.captureEnabled else { return }
            self.pipeline.trigger(automatic: true)
        }
        t.tolerance = min(2, interval * 0.1)
        autoCaptureTimer = t
        Log.app.info("定时捕获已开启，每 \(Int(interval)) 秒")
        menuBar?.refresh()
    }

    func toggleAutoCapture() {
        settings.autoCaptureEnabled.toggle()
    }

    // MARK: Hotkey

    func handleHotkey(_ action: HotkeyAction) {
        switch action {
        case .capture:
            pipeline.trigger()
        case .startTyping:
            startTypingPendingCode()
        case .stopTyping:
            stopTyping()
        }
    }

    func registerAllHotkeys() {
        var failed: [String] = []
        if !HotkeyManager.shared.register(settings.hotkey, for: .capture) {
            failed.append("\(HotkeyAction.capture.displayName) \(settings.hotkey.displayString)")
        }
        if !HotkeyManager.shared.register(settings.typeHotkey, for: .startTyping) {
            failed.append("\(HotkeyAction.startTyping.displayName) \(settings.typeHotkey.displayString)")
        }
        if !HotkeyManager.shared.register(settings.stopHotkey, for: .stopTyping) {
            failed.append("\(HotkeyAction.stopTyping.displayName) \(settings.stopHotkey.displayString)")
        }
        hotkeyError = failed.isEmpty ? nil : "以下快捷键注册失败，可能已被系统或其他应用占用：" + failed.joined(separator: "、")
        menuBar?.refresh()
    }

    func register(_ hk: Hotkey, for action: HotkeyAction) {
        if HotkeyManager.shared.register(hk, for: action) {
            hotkeyError = nil
        } else {
            hotkeyError = "快捷键 \(hk.displayString)（\(action.displayName)）注册失败，可能已被系统或其他应用占用"
        }
        menuBar?.refresh()
    }

    // MARK: 键入到光标

    private func setupTyping() {
        TextTyper.shared.onProgress = { [weak self] typed, total in
            guard let self = self else { return }
            let percent = total > 0 ? Int(Double(typed) / Double(total) * 100) : 0
            self.typingProgress = "键入中 \(percent)%"
            if let id = self.typingJobID { self.caption.setNote("键入中 \(percent)%", for: id) }
            self.menuBar?.refresh()
        }
        TextTyper.shared.onFinished = { [weak self] result in
            guard let self = self else { return }
            let id = self.typingJobID
            self.typingJobID = nil
            self.typingProgress = nil
            if let id = id { self.caption.setNote("", for: id) }
            if let message = result.message {
                self.handle(.status(message: message, level: "warning"))
            }
            self.menuBar?.refresh()
        }
    }

    /// 分析完成后把代码存起来，等待用户按键触发键入。非编程题会清空缓存。
    private func bufferCode(jobID: String, answer: String) {
        guard CodeExtractor.containsCodeBlock(answer), let code = CodeExtractor.extract(answer), !code.isEmpty else {
            pendingCode = nil
            pendingCodeJobID = nil
            pendingCodeSummary = nil
            menuBar?.refresh()
            return
        }
        pendingCode = code
        pendingCodeJobID = jobID
        let lines = code.components(separatedBy: "\n").count
        pendingCodeSummary = "\(lines) 行"
        Log.app.info("已准备好可键入的代码，\(lines) 行；按 \(self.settings.typeHotkey.displayString, privacy: .public) 开始键入")
        menuBar?.refresh()
    }

    var hasPendingCode: Bool { pendingCode?.isEmpty == false }

    /// 「开始键入」快捷键：把上一次分析得到的代码键入到当前光标处
    func startTypingPendingCode() {
        guard !TextTyper.shared.isTyping else {
            handle(.status(message: "正在键入中，按 \(settings.stopHotkey.displayString) 可停止", level: "warning"))
            return
        }
        guard let code = pendingCode, !code.isEmpty else {
            handle(.status(message: "还没有可键入的代码，请先按 \(settings.hotkey.displayString) 分析一道编程题", level: "warning"))
            return
        }
        guard TextTyper.shared.hasAccessibilityPermission else {
            handle(.status(message: "键入需要「辅助功能」权限，请在设置 › 捕获设置中授权", level: "warning"))
            showSettings(.capture)
            return
        }
        typingJobID = pendingCodeJobID
        typingProgress = "键入中 0%"
        if let id = typingJobID { caption.setNote("键入中 0%", for: id) }
        TextTyper.shared.type(code, options: settings.typingOptions)
        menuBar?.refresh()
    }

    func stopTyping() {
        guard TextTyper.shared.isTyping else { return }
        TextTyper.shared.abort()
    }

    // MARK: Certificates

    func currentHostnames() -> [String] {
        var hosts = ["localhost"]
        if let h = NetworkInfo.localHostname() { hosts.append("\(h).local") }
        return hosts
    }

    func currentIPs() -> [String] {
        ["127.0.0.1"] + NetworkInfo.lanIPv4Addresses()
    }

    func refreshCertificatesIfNeeded() {
        guard server.isTLS else { return }
        certs.unlockKeychain()
        if certs.needsRefresh(hostnames: currentHostnames(), ips: currentIPs()) {
            Log.server.info("网络地址变化，重新签发服务器证书")
            restartServer()
        }
    }

    func regenerateServerCertificate() {
        do {
            _ = try certs.regenerateServer(hostnames: currentHostnames(), ips: currentIPs())
            tlsError = nil
        } catch {
            tlsError = "重新签发失败：\(error.localizedDescription)"
        }
        restartServer()
    }

    func resetRootCertificate() {
        do {
            _ = try certs.resetAll(hostnames: currentHostnames(), ips: currentIPs())
            tlsError = nil
        } catch {
            tlsError = "重置根证书失败：\(error.localizedDescription)"
        }
        restartServer()
    }

    // MARK: Server

    var httpsPort: Int { settings.listenPort }

    func startServer() {
        server.port = UInt16(clamping: httpsPort)
        do {
            server.identity = try certs.ensureIdentity(hostnames: currentHostnames(), ips: currentIPs())
            tlsError = nil
        } catch {
            server.identity = nil
            tlsError = "HTTPS 证书不可用，已退化为 HTTP：\(error.localizedDescription)"
            Log.server.error("\(self.tlsError ?? "", privacy: .public)")
        }
        do {
            try server.start()
        } catch {
            serverError = "服务器启动失败：\(error.localizedDescription)"
            serverRunning = false
        }
        menuBar?.refresh()
    }

    func restartServer() {
        server.stop()
        startServer()
    }

    // MARK: URLs

    private var scheme: String { server.isTLS ? "https" : "http" }

    /// 唯一对外地址：按设置选择主机名或局域网 IP，取不到时互为退路
    func primaryURL() -> String {
        let host = NetworkInfo.localHostname().map { "\($0).local" }
        let ip = NetworkInfo.lanIPv4Addresses().first
        let chosen: String?
        if settings.addressMode == "ip" { chosen = ip ?? host } else { chosen = host ?? ip }
        return "\(scheme)://\(chosen ?? "<Mac IP>"):\(httpsPort)/"
    }

    func httpsURLs() -> [String] { server.isTLS ? [primaryURL()] : [] }
    func httpURLs() -> [String] { server.isTLS ? [] : [primaryURL()] }
    func accessURLs() -> [String] { [primaryURL()] }

    private func statusDictionary() -> [String: Any] {
        var d: [String: Any] = [
            "capture_enabled": settings.captureEnabled,
            "capture_scope": settings.captureScope.rawValue,
            "hotkey": settings.hotkey.displayString,
            "type_hotkey": settings.typeHotkey.displayString,
            "stop_hotkey": settings.stopHotkey.displayString,
            "typing": TextTyper.shared.isTyping,
            "pending_code": pendingCodeSummary ?? "",
            "queue": pipeline.queueCount,
            "provider": settings.apiProvider.rawValue,
            "model": settings.currentModel,
            "tls": server.isTLS,
            "address": primaryURL(),
        ]
        if server.isTLS { d["https_port"] = httpsPort }
        return d
    }

    // MARK: Caption

    func updateCaptionVisibility(mode: CaptionMode? = nil) {
        if (mode ?? settings.captionMode) == .off { captionPanel.hide() } else { captionPanel.show() }
    }

    /// 结果自动复制到剪贴板
    private func copyToClipboardIfEnabled(_ text: String) {
        guard settings.autoCopyToClipboard, !text.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }
}

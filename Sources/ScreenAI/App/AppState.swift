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
    @Published var analyzingCount = 0

    private var cancellables = Set<AnyCancellable>()
    private var certTimer: Timer?
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

        HotkeyManager.shared.onTrigger = { [weak self] in self?.pipeline.trigger() }
        registerHotkey(settings.hotkey)

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

        if !ScreenCapturer.hasPermission() {
            ScreenCapturer.requestPermission()
        }
        Log.app.info("ScreenAI 已启动")
    }

    func shutdown() {
        HotkeyManager.shared.unregister()
        certTimer?.invalidate()
        hub.stop()
        server.stop()
        captionPanel.hide()
        Log.app.info("ScreenAI 已退出")
    }

    private func observeSettings() {
        settings.$hotkey.dropFirst().removeDuplicates()
            .sink { [weak self] hk in self?.registerHotkey(hk) }.store(in: &cancellables)
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
        case let .completed(_, text, _, _, _): copyToClipboardIfEnabled(text)
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

    // MARK: Hotkey

    func registerHotkey(_ hk: Hotkey) {
        if HotkeyManager.shared.register(hk) {
            hotkeyError = nil
        } else {
            hotkeyError = "快捷键 \(hk.displayString) 注册失败，可能已被系统或其他应用占用"
        }
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

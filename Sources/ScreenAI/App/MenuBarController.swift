import AppKit

final class MenuBarController: NSObject {
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private unowned let state: AppState

    private let statusLine = NSMenuItem(title: "状态：就绪", action: nil, keyEquivalent: "")
    private let toggleItem = NSMenuItem(title: "停止捕获", action: #selector(toggleCapture), keyEquivalent: "")
    private let queueLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let autoItem = NSMenuItem(title: "定时捕获", action: #selector(toggleAuto), keyEquivalent: "")
    private let typeItem = NSMenuItem(title: "分析并键入到光标", action: #selector(typeCode), keyEquivalent: "")
    private let stopTypeItem = NSMenuItem(title: "停止键入", action: #selector(stopTyping), keyEquivalent: "")
    private let phoneLine = NSMenuItem(title: "手机：未连接", action: nil, keyEquivalent: "")
    private let pairItem = NSMenuItem(title: "显示验证码…", action: #selector(showPairing), keyEquivalent: "")
    private let disconnectItem = NSMenuItem(title: "断开手机连接", action: #selector(disconnect), keyEquivalent: "")
    private let serverLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let permissionItem = NSMenuItem(title: "⚠️ 屏幕录制权限未授予，点击处理…", action: #selector(fixPermission), keyEquivalent: "")

    init(state: AppState) {
        self.state = state
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        build()
        refresh()
    }

    private func build() {
        statusLine.isEnabled = false
        queueLine.isEnabled = false
        phoneLine.isEnabled = false
        serverLine.isEnabled = false
        for item in [toggleItem, pairItem, disconnectItem, permissionItem, autoItem, typeItem, stopTypeItem] { item.target = self }

        let history = NSMenuItem(title: "查看历史记录…", action: #selector(showHistory), keyEquivalent: "h")
        history.target = self
        let settings = NSMenuItem(title: "打开设置…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        let quit = NSMenuItem(title: "退出 ScreenAI", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self

        menu.addItem(statusLine)
        menu.addItem(permissionItem)
        menu.addItem(queueLine)
        menu.addItem(toggleItem)
        menu.addItem(autoItem)
        menu.addItem(typeItem)
        menu.addItem(stopTypeItem)
        menu.addItem(.separator())
        menu.addItem(phoneLine)
        menu.addItem(serverLine)
        menu.addItem(pairItem)
        menu.addItem(disconnectItem)
        menu.addItem(.separator())
        menu.addItem(history)
        menu.addItem(settings)
        menu.addItem(.separator())
        menu.addItem(quit)
        statusItem.menu = menu
    }

    func refresh() {
        let running = state.settings.captureEnabled
        let symbol = running ? "viewfinder.circle.fill" : "viewfinder.circle"
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "ScreenAI")
            image?.isTemplate = true
            button.image = image
            button.appearsDisabled = !running
            button.toolTip = running ? "ScreenAI：运行中（\(state.settings.hotkey.displayString) 截图分析）" : "ScreenAI：已停止"
        }
        statusLine.title = running ? "状态：运行中（\(state.settings.hotkey.displayString)）" : "状态：已停止"
        permissionItem.isHidden = ScreenCapturer.effectivePermission()
        toggleItem.title = running ? "停止捕获" : "启动捕获"
        let interval = Int(max(3, state.settings.autoCaptureInterval))
        autoItem.title = "定时捕获（每 \(interval) 秒）"
        autoItem.state = state.settings.autoCaptureEnabled ? .on : .off
        autoItem.isEnabled = running
        let typing = TextTyper.shared.isTyping
        typeItem.title = "分析并键入到光标（\(state.settings.typeHotkey.displayString)）"
        typeItem.isEnabled = running && !typing
        stopTypeItem.title = "停止键入（\(state.settings.stopHotkey.displayString)）"
        stopTypeItem.isHidden = !typing
        let q = state.pipeline.queueCount
        if let progress = state.typingProgress {
            queueLine.title = progress
        } else {
            queueLine.title = q > 0 ? "分析中…（队列 \(q)）" : (state.lastStatus.isEmpty ? "" : state.lastStatus.truncated(50))
        }
        queueLine.isHidden = queueLine.title.isEmpty

        let n = state.connectedClients
        if n > 0 {
            let addr = state.pairing.currentSession?.clientAddress ?? ""
            phoneLine.title = "手机：已连接（\(addr)）"
        } else if state.pairing.currentSession != nil {
            phoneLine.title = "手机：已配对，等待重连"
        } else {
            phoneLine.title = "手机：未连接"
        }
        disconnectItem.isEnabled = state.pairing.currentSession != nil || n > 0
        if state.serverRunning {
            serverLine.title = "服务：端口 \(state.settings.listenPort)"
        } else {
            serverLine.title = state.serverError ?? "服务：未运行"
        }
    }

    @objc private func toggleCapture() { state.toggleCapture() }
    @objc private func toggleAuto() { state.toggleAutoCapture() }
    @objc private func typeCode() { state.triggerTypeCode() }
    @objc private func stopTyping() { state.stopTyping() }
    @objc private func fixPermission() { state.showSettings(.capture) }
    @objc private func showPairing() { state.showPairing() }
    @objc private func disconnect() { state.disconnectPhone() }
    @objc private func showHistory() { state.showHistory() }
    @objc private func showSettings() { state.showSettings() }
    @objc private func quitApp() { state.quit() }
}

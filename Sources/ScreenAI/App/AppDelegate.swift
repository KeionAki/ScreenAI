import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let state = AppState.shared
        state.menuBar = MenuBarController(state: state)
        state.start()
        // 首次使用：没有任何 API Key 时打开设置。钥匙串读取可能弹出授权对话框并阻塞，放到后台线程，避免卡住服务器启动。
        DispatchQueue.global(qos: .userInitiated).async {
            let hasKey = AIProviderKind.allCases.contains { !state.settings.apiKey(for: $0).isEmpty }
            DispatchQueue.main.async {
                if !hasKey {
                    state.showSettings(.api)
                } else if !ScreenCapturer.effectivePermission() {
                    state.showSettings(.capture)
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppState.shared.shutdown()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        AppState.shared.showSettings()
        return true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
}

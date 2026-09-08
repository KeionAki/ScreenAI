import AppKit
import SwiftUI
import Combine

enum SettingsTab: String, CaseIterable, Identifiable {
    case api, capture, display, connection, history, about
    var id: String { rawValue }
    var title: String {
        switch self {
        case .api: return "API 配置"
        case .capture: return "捕获设置"
        case .display: return "显示设置"
        case .connection: return "连接设置"
        case .history: return "历史记录"
        case .about: return "关于"
        }
    }
    var icon: String {
        switch self {
        case .api: return "sparkles"
        case .capture: return "camera.viewfinder"
        case .display: return "rectangle.on.rectangle"
        case .connection: return "iphone.radiowaves.left.and.right"
        case .history: return "clock.arrow.circlepath"
        case .about: return "info.circle"
        }
    }
}

final class SettingsSelection: ObservableObject {
    @Published var tab: SettingsTab? = .api
}

struct SettingsRootView: View {
    @ObservedObject var state: AppState
    @ObservedObject var selection: SettingsSelection

    var body: some View {
        NavigationSplitView {
            List(SettingsTab.allCases, selection: $selection.tab) { tab in
                Label(tab.title, systemImage: tab.icon).tag(tab)
            }
            .navigationSplitViewColumnWidth(min: 150, ideal: 160, max: 200)
        } detail: {
            ScrollView {
                Group {
                    switch selection.tab ?? .api {
                    case .api: APISettingsView(state: state)
                    case .capture: CaptureSettingsView(state: state)
                    case .display: DisplaySettingsView(state: state)
                    case .connection: ConnectionSettingsView(state: state)
                    case .history: HistorySettingsView(state: state)
                    case .about: AboutView(state: state)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 720, minHeight: 500)
    }
}

final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private let selection = SettingsSelection()

    init(state: AppState) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 560),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init()
        window.title = "ScreenAI 设置"
        window.isReleasedWhenClosed = false
        window.sharingType = .none
        window.contentView = NSHostingView(rootView: SettingsRootView(state: state, selection: selection))
        window.center()
        window.delegate = self
    }

    func show(tab: SettingsTab? = nil) {
        if let tab = tab { selection.tab = tab }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

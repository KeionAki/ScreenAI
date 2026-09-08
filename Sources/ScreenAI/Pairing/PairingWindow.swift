import AppKit
import SwiftUI
import Combine

struct PairingView: View {
    @ObservedObject var pairing: PairingManager
    let httpsURLs: [String]
    let httpURLs: [String]
    let primaryURL: String
    let successEvent: Int
    @State private var now = Date()
    private let timer = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 14) {
            if pairing.pairedEvent > successEvent {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 56)).foregroundColor(.green)
                Text("已成功建立连接").font(.title3.bold())
                if let s = pairing.session { Text("来自 \(s.clientAddress)").font(.caption).foregroundColor(.secondary) }
            } else {
                Text("在 iPhone 上输入验证码").font(.headline)
                Text(spaced(pairing.code ?? "------"))
                    .font(.system(size: 40, weight: .bold, design: .monospaced))
                    .foregroundColor(pairing.code == nil ? .secondary : .primary)
                ring
                if let qr = QRCode.image(primaryURL, size: 150) {
                    Image(nsImage: qr).interpolation(.none).frame(width: 150, height: 150)
                        .background(Color.white).cornerRadius(6)
                }
                Text(primaryURL).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                Text("用 iPhone 相机扫码或在 Safari 打开地址（同一 Wi‑Fi）。首次使用请按页面提示安装根证书。")
                    .font(.caption).foregroundColor(.secondary).multilineTextAlignment(.center)
                Button("重新生成验证码") { pairing.generateCode() }.controlSize(.small)
            }
        }
        .padding(20)
        .frame(width: 300)
        .onReceive(timer) { t in
            now = t
            if pairing.pairedEvent <= successEvent { pairing.refreshIfExpired() }
        }
    }

    private var remaining: Double {
        guard let exp = pairing.codeExpiresAt else { return 0 }
        return max(0, exp.timeIntervalSince(now))
    }

    private var ring: some View {
        let progress = remaining / PairingManager.codeLifetime
        let color: Color = remaining > 20 ? .green : (remaining > 10 ? .orange : .red)
        return ZStack {
            Circle().stroke(Color.gray.opacity(0.25), lineWidth: 6)
            Circle().trim(from: 0, to: CGFloat(progress)).stroke(color, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(Int(remaining.rounded(.up)))s").font(.system(size: 14, weight: .semibold, design: .rounded))
        }
        .frame(width: 64, height: 64)
    }

    private func spaced(_ s: String) -> String { s.map { String($0) }.joined(separator: " ") }
}

final class PairingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

final class PairingWindowController: NSObject, NSWindowDelegate {
    private let panel: PairingPanel
    private unowned let state: AppState
    private var cancellables = Set<AnyCancellable>()
    private var successBaseline = 0

    init(state: AppState) {
        self.state = state
        panel = PairingPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 540),
                             styleMask: [.titled, .closable, .nonactivatingPanel, .utilityWindow], backing: .buffered, defer: false)
        super.init()
        panel.title = "手机配对"
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.sharingType = .none
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.delegate = self

        state.pairing.$pairedEvent.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in
            guard let self = self, self.panel.isVisible else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.panel.orderOut(nil)
            }
        }.store(in: &cancellables)
    }

    func show() {
        successBaseline = state.pairing.pairedEvent
        state.pairing.generateCode()
        let view = PairingView(pairing: state.pairing, httpsURLs: state.httpsURLs(), httpURLs: state.httpURLs(), primaryURL: state.primaryURL(), successEvent: successBaseline)
        let hosting = NSHostingView(rootView: view)
        panel.contentView = hosting
        panel.setContentSize(hosting.fittingSize)
        panel.center()
        panel.orderFrontRegardless()
    }

    func windowWillClose(_ notification: Notification) {
        state.pairing.invalidateCode()
    }
}

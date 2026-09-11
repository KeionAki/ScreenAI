import AppKit
import SwiftUI
import Combine

final class CaptionPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// 置顶、无边框、可拖动、不抢焦点、不会被截图的字幕面板。
final class CaptionPanelController {
    let panel: CaptionPanel
    private let hosting: NSHostingView<CaptionView>
    private let settings: SettingsStore
    private var cancellables = Set<AnyCancellable>()
    private var sizing = false

    init(model: CaptionModel, settings: SettingsStore) {
        self.settings = settings
        panel = CaptionPanel(contentRect: NSRect(x: 80, y: 120, width: settings.captionWidth, height: 100),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false   // 系统阴影在浅色背景上会显示为一圈深色"边框"
        panel.isMovableByWindowBackground = true
        panel.sharingType = .none
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        hosting = NSHostingView(rootView: CaptionView(model: model, settings: settings))
        panel.contentView = hosting
        panel.setFrameAutosaveName("ScreenAICaptionPanel")

        model.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in DispatchQueue.main.async { self?.updateSize() } }
            .store(in: &cancellables)
        settings.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in DispatchQueue.main.async { self?.updateSize() } }
            .store(in: &cancellables)
    }

    func show() {
        updateSize()
        ensureOnScreen()
        panel.orderFrontRegardless()
    }

    func hide() { panel.orderOut(nil) }

    var isVisible: Bool { panel.isVisible }

    func updateSize() {
        guard !sizing else { return }
        sizing = true
        defer { sizing = false }
        hosting.layoutSubtreeIfNeeded()
        let fitting = hosting.fittingSize
        let width = CGFloat(settings.captionWidth)
        let height = max(44, fitting.height)
        var frame = panel.frame
        let top = frame.maxY
        frame.size = NSSize(width: width, height: height)
        frame.origin.y = top - height
        if abs(panel.frame.height - height) > 0.5 || abs(panel.frame.width - width) > 0.5 {
            panel.setFrame(frame, display: true, animate: false)
        }
    }

    func resetPosition() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let v = screen.visibleFrame
        let frame = panel.frame
        panel.setFrameOrigin(NSPoint(x: v.maxX - frame.width - 20, y: v.maxY - frame.height - 20))
    }

    private func ensureOnScreen() {
        let frame = panel.frame
        let onSomeScreen = NSScreen.screens.contains { $0.visibleFrame.intersects(frame) }
        if !onSomeScreen { resetPosition() }
    }
}

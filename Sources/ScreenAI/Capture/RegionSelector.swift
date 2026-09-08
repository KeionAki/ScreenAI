import AppKit

/// 在所有显示器上覆盖半透明遮罩，拖拽框选区域，返回全局 CG 坐标的 RegionRef。
final class RegionSelector {
    private static var current: RegionSelector?
    private var windows: [RegionWindow] = []
    private let completion: (RegionRef?) -> Void
    private var finished = false

    static func begin(completion: @escaping (RegionRef?) -> Void) {
        current?.finish(nil)
        let s = RegionSelector(completion: completion)
        current = s
        s.present()
    }

    private init(completion: @escaping (RegionRef?) -> Void) {
        self.completion = completion
    }

    private func present() {
        NSApp.activate(ignoringOtherApps: true)
        for screen in NSScreen.screens {
            let w = RegionWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false, screen: screen)
            w.level = .screenSaver
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = false
            w.ignoresMouseEvents = false
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            w.sharingType = .none
            w.isReleasedWhenClosed = false
            let view = RegionSelectionView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.onFinish = { [weak self, weak w] rect in
                guard let self = self else { return }
                guard let rect = rect, let w = w, rect.width >= 10, rect.height >= 10 else { self.finish(nil); return }
                let screenRect = w.convertToScreen(rect)
                self.finish(RegionSelector.toRegion(screenRect, on: w.screen ?? screen))
            }
            view.onCancel = { [weak self] in self?.finish(nil) }
            w.contentView = view
            w.makeKeyAndOrderFront(nil)
            windows.append(w)
        }
        windows.first?.makeKey()
    }

    /// AppKit 屏幕坐标（左下原点）→ CG 全局坐标（主屏左上原点）
    static func toRegion(_ r: NSRect, on screen: NSScreen) -> RegionRef {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        let cgY = primaryHeight - r.maxY
        let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
        return RegionRef(displayID: id, x: Double(r.minX.rounded()), y: Double(cgY.rounded()), width: Double(r.width.rounded()), height: Double(r.height.rounded()))
    }

    private func finish(_ region: RegionRef?) {
        guard !finished else { return }
        finished = true
        for w in windows { w.orderOut(nil) }
        windows.removeAll()
        RegionSelector.current = nil
        completion(region)
    }
}

final class RegionWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class RegionSelectionView: NSView {
    var onFinish: ((NSRect?) -> Void)?
    var onCancel: (() -> Void)?
    private var start: NSPoint?
    private var currentRect: NSRect?

    override var acceptsFirstResponder: Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func mouseDown(with event: NSEvent) {
        start = convert(event.locationInWindow, from: nil)
        currentRect = nil
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let s = start else { return }
        let p = convert(event.locationInWindow, from: nil)
        currentRect = NSRect(x: min(s.x, p.x), y: min(s.y, p.y), width: abs(p.x - s.x), height: abs(p.y - s.y))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let s = start else { return }
        let p = convert(event.locationInWindow, from: nil)
        let rect = NSRect(x: min(s.x, p.x), y: min(s.y, p.y), width: abs(p.x - s.x), height: abs(p.y - s.y))
        start = nil
        onFinish?(rect)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?() } else { super.keyDown(with: event) }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.35).setFill()
        bounds.fill()
        if let r = currentRect {
            NSColor.clear.setFill()
            r.fill(using: .copy)
            NSColor.controlAccentColor.setStroke()
            let p = NSBezierPath(rect: r)
            p.lineWidth = 2
            p.stroke()
            let label = "\(Int(r.width)) × \(Int(r.height))" as NSString
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.white]
            let size = label.size(withAttributes: attrs)
            let bg = NSRect(x: r.minX, y: r.maxY + 4, width: size.width + 10, height: size.height + 4)
            NSColor.black.withAlphaComponent(0.7).setFill()
            NSBezierPath(roundedRect: bg, xRadius: 4, yRadius: 4).fill()
            label.draw(at: NSPoint(x: bg.minX + 5, y: bg.minY + 2), withAttributes: attrs)
        } else {
            let hint = "拖拽框选捕获区域，Esc 取消" as NSString
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 18, weight: .medium), .foregroundColor: NSColor.white]
            let size = hint.size(withAttributes: attrs)
            hint.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: bounds.height - 120), withAttributes: attrs)
        }
    }
}

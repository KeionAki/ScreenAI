import SwiftUI
import AppKit

/// 快捷键录制控件：点击后按下组合键即完成录制，Esc 取消。
struct HotkeyRecorderView: NSViewRepresentable {
    @Binding var hotkey: Hotkey

    func makeNSView(context: Context) -> HotkeyRecorderNSView {
        let v = HotkeyRecorderNSView()
        v.onCapture = { hk in hotkey = hk }
        v.display = hotkey.displayString
        return v
    }

    func updateNSView(_ nsView: HotkeyRecorderNSView, context: Context) {
        nsView.display = hotkey.displayString
        nsView.needsDisplay = true
    }
}

final class HotkeyRecorderNSView: NSView {
    var onCapture: ((Hotkey) -> Void)?
    var display: String = "" { didSet { needsDisplay = true } }
    private var recording = false { didSet { needsDisplay = true } }

    override var acceptsFirstResponder: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 150, height: 24) }

    override func mouseDown(with event: NSEvent) {
        if recording {
            recording = false
            window?.makeFirstResponder(nil)
        } else {
            window?.makeFirstResponder(self)
            recording = true
        }
    }

    override func resignFirstResponder() -> Bool {
        recording = false
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard recording else { super.keyDown(with: event); return }
        handle(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard recording, event.type == .keyDown else { return super.performKeyEquivalent(with: event) }
        handle(event)
        return true
    }

    private func handle(_ event: NSEvent) {
        if event.keyCode == 53 { // Esc
            recording = false
            window?.makeFirstResponder(nil)
            return
        }
        if let hk = Hotkey(event: event) {
            onCapture?(hk)
            recording = false
            window?.makeFirstResponder(nil)
        } else {
            NSSound.beep()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        (recording ? NSColor.controlAccentColor.withAlphaComponent(0.15) : NSColor.controlBackgroundColor).setFill()
        path.fill()
        (recording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.stroke()
        let text = recording ? "请按下组合键…（Esc 取消）" : display
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: recording ? .regular : .semibold),
            .foregroundColor: recording ? NSColor.secondaryLabelColor : NSColor.labelColor,
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        (text as NSString).draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attrs)
    }
}

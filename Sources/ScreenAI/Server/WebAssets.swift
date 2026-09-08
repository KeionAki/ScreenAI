import Foundation
import AppKit

/// PWA 静态资源定位与运行时生成的图标。
enum WebAssets {
    static var overrideDirectory: URL?
    private static var iconCache: [Int: Data] = [:]
    private static let iconLock = NSLock()

    static func directory() -> URL? {
        var candidates: [URL] = []
        if let o = overrideDirectory { candidates.append(o) }
        if let env = ProcessInfo.processInfo.environment["SCREENAI_WEB_DIR"] { candidates.append(URL(fileURLWithPath: env)) }
        if let r = Bundle.main.resourceURL { candidates.append(r.appendingPathComponent("Web")) }
        if let exe = Bundle.main.executableURL?.deletingLastPathComponent() {
            candidates.append(exe.appendingPathComponent("../Sources/ScreenAI/Web").standardized)
            candidates.append(exe.appendingPathComponent("../../Sources/ScreenAI/Web").standardized)
        }
        candidates.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Sources/ScreenAI/Web"))
        return candidates.first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("index.html").path) }
    }

    static func data(_ name: String) -> Data? {
        guard !name.contains(".."), !name.contains("/"), let dir = directory() else { return nil }
        return try? Data(contentsOf: dir.appendingPathComponent(name))
    }

    /// 生成 PNG 应用图标（圆角渐变底 + “AI”），按尺寸缓存。
    static func icon(size: Int) -> Data {
        iconLock.lock()
        if let d = iconCache[size] { iconLock.unlock(); return d }
        iconLock.unlock()
        let render: () -> Data = {
            let space = CGColorSpaceCreateDeviceRGB()
            guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return Data() }
            let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = ns
            let rect = NSRect(x: 0, y: 0, width: size, height: size)
            let radius = rect.width * 0.22
            let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
            let g = NSGradient(starting: NSColor(calibratedRed: 0.10, green: 0.14, blue: 0.36, alpha: 1),
                               ending: NSColor(calibratedRed: 0.42, green: 0.22, blue: 0.68, alpha: 1))
            g?.draw(in: path, angle: -60)
            // 取景框四角
            let inset = rect.width * 0.16, len = rect.width * 0.14, lw = max(2, rect.width * 0.045)
            let corner = NSBezierPath()
            corner.lineWidth = lw
            corner.lineCapStyle = .round
            let pts: [(NSPoint, NSPoint, NSPoint)] = [
                (NSPoint(x: inset, y: inset + len), NSPoint(x: inset, y: inset), NSPoint(x: inset + len, y: inset)),
                (NSPoint(x: rect.width - inset - len, y: inset), NSPoint(x: rect.width - inset, y: inset), NSPoint(x: rect.width - inset, y: inset + len)),
                (NSPoint(x: inset, y: rect.height - inset - len), NSPoint(x: inset, y: rect.height - inset), NSPoint(x: inset + len, y: rect.height - inset)),
                (NSPoint(x: rect.width - inset - len, y: rect.height - inset), NSPoint(x: rect.width - inset, y: rect.height - inset), NSPoint(x: rect.width - inset, y: rect.height - inset - len)),
            ]
            for (a, b, c) in pts { corner.move(to: a); corner.line(to: b); corner.line(to: c) }
            NSColor.white.withAlphaComponent(0.85).setStroke()
            corner.stroke()
            let text = "AI" as NSString
            let font = NSFont.systemFont(ofSize: rect.width * 0.40, weight: .bold)
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
            let s = text.size(withAttributes: attrs)
            text.draw(at: NSPoint(x: (rect.width - s.width) / 2, y: (rect.height - s.height) / 2), withAttributes: attrs)
            NSGraphicsContext.restoreGraphicsState()
            guard let cg = ctx.makeImage(), let png = ImageEncoder.png(cg) else { return Data() }
            return png
        }
        let data = Thread.isMainThread ? render() : DispatchQueue.main.sync(execute: render)
        iconLock.lock(); iconCache[size] = data; iconLock.unlock()
        return data
    }
}

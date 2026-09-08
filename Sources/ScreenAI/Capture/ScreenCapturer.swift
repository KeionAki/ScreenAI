import Foundation
import AppKit
import CoreGraphics

enum CaptureTarget: Equatable {
    case fullScreen
    case display(UInt32)
    case window(WindowRef)
    case region(RegionRef)
}

struct CaptureResult {
    let image: CGImage
    let sourceDescription: String
}

enum CaptureError: LocalizedError {
    case permissionDenied
    case displayNotFound
    case windowNotFound(WindowRef)
    case regionDisplayNotFound
    case captureFailed

    var errorDescription: String? {
        switch self {
        case .permissionDenied: return "没有屏幕录制权限：请在「系统设置 › 隐私与安全性 › 屏幕录制」中勾选 ScreenAI，然后重新启动 ScreenAI（设置 › 捕获设置 里有按钮）"
        case .displayNotFound: return "目标显示器已断开"
        case .windowNotFound(let ref): return "目标窗口已关闭：\(ref.displayName)"
        case .regionDisplayNotFound: return "区域所在显示器已断开"
        case .captureFailed: return "屏幕捕获失败"
        }
    }
}

/// CoreGraphics 截图后端（macOS 12.3–15 可用）。自身窗口 sharingType = .none，不会被截入。
enum ScreenCapturer {
    // MARK: Permission

    static func hasPermission() -> Bool { CGPreflightScreenCaptureAccess() }

    @discardableResult
    static func requestPermission() -> Bool { CGRequestScreenCaptureAccess() }

    /// 没有屏幕录制权限时，系统会隐藏其他进程窗口的标题；能看到标题即说明当前进程实际已获授权。
    static func windowTitlesVisible() -> Bool {
        guard let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return false }
        let own = getpid()
        return raw.contains { w in
            guard let pid = w[kCGWindowOwnerPID as String] as? pid_t, pid != own,
                  let layer = w[kCGWindowLayer as String] as? Int, layer == 0,
                  let name = w[kCGWindowName as String] as? String else { return false }
            return !name.isEmpty
        }
    }

    /// 当前进程是否实际可以截图（预检为准，窗口标题可见作为补充判断）
    static func effectivePermission() -> Bool {
        hasPermission() || windowTitlesVisible()
    }

    static func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Displays

    static func displays() -> [DisplayInfo] {
        onMain {
            NSScreen.screens.compactMap { screen in
                guard let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
                let id = num.uint32Value
                return DisplayInfo(id: id, name: screen.localizedName, bounds: CGDisplayBounds(id), scale: screen.backingScaleFactor)
            }
        }
    }

    static func displayExists(_ id: UInt32) -> Bool {
        var count: UInt32 = 0
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        guard CGGetActiveDisplayList(16, &ids, &count) == .success else { return false }
        return ids.prefix(Int(count)).contains(id)
    }

    static func displayName(_ id: UInt32) -> String {
        displays().first { $0.id == id }?.name ?? "显示器 \(id)"
    }

    static func displayUnderMouse() -> UInt32 {
        onMain {
            let loc = NSEvent.mouseLocation
            let screen = NSScreen.screens.first { $0.frame.contains(loc) } ?? NSScreen.main ?? NSScreen.screens.first
            let num = screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            return num?.uint32Value ?? CGMainDisplayID()
        }
    }

    // MARK: Capture

    static func capture(_ target: CaptureTarget) throws -> CaptureResult {
        guard effectivePermission() else { throw CaptureError.permissionDenied }
        switch target {
        case .fullScreen:
            let id = displayUnderMouse()
            let image = try captureRect(CGDisplayBounds(id))
            return CaptureResult(image: image, sourceDescription: "全屏：\(displayName(id))")
        case .display(let id):
            guard displayExists(id) else { throw CaptureError.displayNotFound }
            let image = try captureRect(CGDisplayBounds(id))
            return CaptureResult(image: image, sourceDescription: "显示器：\(displayName(id))")
        case .window(let ref):
            guard let info = WindowEnumerator.resolve(ref) else { throw CaptureError.windowNotFound(ref) }
            guard let image = CGWindowListCreateImage(.null, .optionIncludingWindow, info.id, [.boundsIgnoreFraming, .bestResolution]),
                  image.width > 1, image.height > 1 else { throw CaptureError.captureFailed }
            return CaptureResult(image: image, sourceDescription: "窗口：\(info.displayName.truncated(60))")
        case .region(let region):
            guard displayExists(region.displayID) else { throw CaptureError.regionDisplayNotFound }
            let image = try captureRect(region.rect)
            return CaptureResult(image: image, sourceDescription: region.displayName)
        }
    }

    /// rect 为全局 CG 坐标（点）；返回像素级图像。
    private static func captureRect(_ rect: CGRect) throws -> CGImage {
        guard rect.width >= 1, rect.height >= 1,
              let image = CGWindowListCreateImage(rect, .optionOnScreenOnly, kCGNullWindowID, [.bestResolution]),
              image.width > 1, image.height > 1 else { throw CaptureError.captureFailed }
        return image
    }

    // MARK: Helpers

    private static func onMain<T>(_ block: () -> T) -> T {
        if Thread.isMainThread { return block() }
        return DispatchQueue.main.sync(execute: block)
    }
}

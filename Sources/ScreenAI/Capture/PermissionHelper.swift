import Foundation
import AppKit

/// 屏幕录制权限的辅助操作：重置系统授权记录、重新启动应用。
enum PermissionHelper {
    static var bundleID: String { Bundle.main.bundleIdentifier ?? "com.li.screenai" }

    /// 用 tccutil 清除本应用的屏幕录制授权记录（用户级，不需要管理员权限），之后可重新申请。
    static func resetScreenCaptureRecord() -> (ok: Bool, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        p.arguments = ["reset", "ScreenCapture", bundleID]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do {
            try p.run()
        } catch {
            return (false, error.localizedDescription)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let out = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        Log.app.info("tccutil reset ScreenCapture: status \(p.terminationStatus), \(out, privacy: .public)")
        return (p.terminationStatus == 0, out)
    }

    /// 是否以 .app 包形式运行（直接运行裸二进制时无法重新启动）
    static var isBundled: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    /// 退出并重新打开应用（系统设置里勾选屏幕录制后需要重启才生效）
    static func relaunch() {
        guard isBundled else { return }
        let path = Bundle.main.bundleURL.path
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.8; /usr/bin/open \"\(path)\""]
        try? task.run()
        AppState.shared.quit()
    }
}

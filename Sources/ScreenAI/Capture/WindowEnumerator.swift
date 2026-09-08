import Foundation
import AppKit
import CoreGraphics

enum WindowEnumerator {
    /// 枚举可捕获的窗口（普通窗口层、有标题、非本应用）。
    static func list() -> [WindowInfo] {
        let options: CGWindowListOption = [.optionAll, .excludeDesktopElements]
        guard let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        let ownPID = getpid()
        var bundleCache: [pid_t: String?] = [:]
        var out: [WindowInfo] = []
        for w in raw {
            guard let layer = w[kCGWindowLayer as String] as? Int, layer == 0,
                  let id = w[kCGWindowNumber as String] as? UInt32,
                  let pid = w[kCGWindowOwnerPID as String] as? pid_t, pid != ownPID,
                  let owner = w[kCGWindowOwnerName as String] as? String, !owner.isEmpty,
                  let title = w[kCGWindowName as String] as? String, !title.isEmpty else { continue }
            if let alpha = w[kCGWindowAlpha as String] as? Double, alpha <= 0.01 { continue }
            var bounds = CGRect.zero
            if let b = w[kCGWindowBounds as String] as? NSDictionary, let r = CGRect(dictionaryRepresentation: b) { bounds = r }
            if bounds.width < 50 || bounds.height < 50 { continue }
            let bundleID: String?
            if let cached = bundleCache[pid] {
                bundleID = cached
            } else {
                bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
                bundleCache[pid] = bundleID
            }
            out.append(WindowInfo(id: id, pid: pid, bundleID: bundleID, ownerName: owner, title: title, bounds: bounds))
        }
        return out.sorted { a, b in
            if a.ownerName != b.ownerName { return a.ownerName.localizedCaseInsensitiveCompare(b.ownerName) == .orderedAscending }
            return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
        }
    }

    /// 按应用 + 标题重新解析窗口；标题精确匹配优先，其次同应用中标题前缀匹配。
    static func resolve(_ ref: WindowRef) -> WindowInfo? {
        let all = list()
        let sameApp = all.filter { w in
            if let b = ref.bundleID, let wb = w.bundleID { return b == wb }
            return w.ownerName == ref.ownerName
        }
        if let exact = sameApp.first(where: { $0.title == ref.title }) { return exact }
        if let prefix = sameApp.first(where: { $0.title.hasPrefix(ref.title) || ref.title.hasPrefix($0.title) }) { return prefix }
        return nil
    }
}

import Foundation
import AppKit
import Carbon.HIToolbox
import ApplicationServices

struct TypingOptions {
    var charsPerSecond: Double = 25
    /// 每个字符的间隔随机抖动比例（0 = 匀速，0.5 = ±50%）
    var jitter: Double = 0.3
    /// 开始前倒计时秒数，留出切换窗口的时间
    var countdown: TimeInterval = 2
    /// 换行后清除编辑器自动插入的缩进（VSCode 默认会自动缩进）
    var clearAutoIndent: Bool = true
    var tabWidth: Int = 4
}

enum TypingResult {
    case completed
    case aborted
    case noPermission
    case selfFocused
    case empty
}

/// 用合成键盘事件把文本键入当前焦点所在的输入框（需要「辅助功能」权限）。
/// 换行使用真实回车键；可选地在换行后清除编辑器自动缩进，保证代码缩进与原文一致。
final class TextTyper {
    static let shared = TextTyper()

    private let queue = DispatchQueue(label: "com.li.screenai.typer", qos: .userInitiated)
    private let lock = NSLock()
    private var _aborted = false
    private var _typing = false

    /// (已键入字符数, 总字符数)，主线程回调
    var onProgress: ((Int, Int) -> Void)?
    /// 主线程回调
    var onFinished: ((TypingResult) -> Void)?

    private init() {}

    var isTyping: Bool { lock.lock(); defer { lock.unlock() }; return _typing }
    var hasAccessibilityPermission: Bool { TextTyper.hasPermission() }

    // MARK: 权限

    static func hasPermission() -> Bool { AXIsProcessTrusted() }

    static func requestPermission() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: 控制

    func abort() {
        lock.lock(); _aborted = true; lock.unlock()
    }

    private var aborted: Bool { lock.lock(); defer { lock.unlock() }; return _aborted }

    /// 键入文本。text 为已提取的代码原文。
    func type(_ text: String, options: TypingOptions) {
        lock.lock()
        guard !_typing else { lock.unlock(); return }
        _typing = true
        _aborted = false
        lock.unlock()

        let code = CodeExtractor.normalize(text, tabWidth: options.tabWidth)
        guard !code.isEmpty else { finish(.empty); return }
        guard TextTyper.hasPermission() else { finish(.noPermission); return }
        // 防止把代码打进自己的窗口
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid() {
            finish(.selfFocused); return
        }

        queue.async { [weak self] in
            guard let self = self else { return }
            if !self.sleepInterruptibly(options.countdown) { self.finish(.aborted); return }
            // 倒计时后再确认一次焦点
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid() {
                self.finish(.selfFocused); return
            }
            self.run(code, options: options)
        }
    }

    // MARK: 键入实现

    private func run(_ code: String, options: TypingOptions) {
        let source = CGEventSource(stateID: .hidSystemState)
        source?.keyboardType = 0
        let lines = code.components(separatedBy: "\n")
        let total = code.count
        var typed = 0
        let baseDelay = 1.0 / max(1.0, options.charsPerSecond)
        let jitter = min(max(options.jitter, 0), 0.9)

        func pause() -> Bool {
            let factor = jitter > 0 ? Double.random(in: (1 - jitter)...(1 + jitter)) : 1
            return sleepInterruptibly(baseDelay * factor)
        }

        for (index, line) in lines.enumerated() {
            if index > 0 {
                // 换行
                postKey(CGKeyCode(kVK_Return), source: source)
                usleep(12_000)
                if options.clearAutoIndent {
                    // 先打一个标记字符，保证随后的 Shift+Home 选区非空，
                    // 否则空行上的退格会删掉刚建立的换行。
                    postUnicode("x", source: source)
                    usleep(6_000)
                    // VSCode 的 Home 为智能行首：按两次才能到第 0 列
                    postKey(CGKeyCode(kVK_Home), flags: .maskShift, source: source)
                    postKey(CGKeyCode(kVK_Home), flags: .maskShift, source: source)
                    usleep(6_000)
                    if line.isEmpty {
                        // 空行：删掉选中的「缩进 + 标记」
                        postKey(CGKeyCode(kVK_Delete), source: source)
                        usleep(6_000)
                    }
                    // 非空行：下面第一个字符会直接替换掉选区
                }
                if !pause() { finish(.aborted); return }
            }
            for ch in line {
                if aborted { finish(.aborted); return }
                postUnicode(String(ch), source: source)
                typed += 1
                if typed % 8 == 0 { report(typed, total) }
                if !pause() { finish(.aborted); return }
            }
            typed += 1   // 换行符计入进度
            report(typed, total)
        }
        finish(.completed)
    }

    private func postUnicode(_ s: String, source: CGEventSource?) {
        var utf16 = Array(s.utf16)
        guard !utf16.isEmpty else { return }
        if let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true) {
            down.flags = []
            down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
            down.post(tap: .cghidEventTap)
        }
        if let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) {
            up.flags = []
            up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
            up.post(tap: .cghidEventTap)
        }
    }

    private func postKey(_ key: CGKeyCode, flags: CGEventFlags = [], source: CGEventSource?) {
        if let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true) {
            down.flags = flags
            down.post(tap: .cghidEventTap)
        }
        if let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false) {
            up.flags = flags
            up.post(tap: .cghidEventTap)
        }
    }

    /// 分片睡眠，便于及时响应停止；返回 false 表示被中止
    private func sleepInterruptibly(_ seconds: TimeInterval) -> Bool {
        guard seconds > 0 else { return !aborted }
        var remaining = seconds
        let slice = 0.02
        while remaining > 0 {
            if aborted { return false }
            let step = min(slice, remaining)
            usleep(useconds_t(step * 1_000_000))
            remaining -= step
        }
        return !aborted
    }

    private func report(_ typed: Int, _ total: Int) {
        DispatchQueue.main.async { self.onProgress?(min(typed, total), total) }
    }

    private func finish(_ result: TypingResult) {
        lock.lock(); _typing = false; _aborted = false; lock.unlock()
        Log.app.info("键入结束: \(String(describing: result), privacy: .public)")
        DispatchQueue.main.async { self.onFinished?(result) }
    }
}

extension TypingResult {
    var message: String? {
        switch self {
        case .completed: return nil
        case .aborted: return "已停止键入"
        case .noPermission: return "没有「辅助功能」权限，无法键入。请在设置 › 捕获设置中授权后重试"
        case .selfFocused: return "当前焦点在 ScreenAI 自己的窗口上，已取消键入。请先点进编辑器再触发"
        case .empty: return "回答中没有可键入的代码"
        }
    }
}

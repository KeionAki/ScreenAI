import Foundation
import AppKit
import Carbon.HIToolbox
import ApplicationServices

/// 换行前关闭补全浮层的方式。编辑器默认「按回车接受补全」，浮层打开时回车不会换行，
/// 会导致刚打完的一整行被下一行内容顶替；但直接按 Esc 会让全屏的浏览器退出全屏。
enum SuggestionDismiss: String, CaseIterable, Identifiable {
    case none          // 不处理
    case cursorNudge   // 左移再右移：光标位置不变，可关闭浮层，浏览器全屏不受影响
    case escape        // 按 Esc：最彻底，但会退出浏览器全屏

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .none: return "不处理"
        case .cursorNudge: return "移动光标（推荐）"
        case .escape: return "按 Esc（会退出浏览器全屏）"
        }
    }
}

struct TypingOptions {
    var charsPerSecond: Double = 25
    /// 每个字符的间隔随机抖动比例（0 = 匀速，0.5 = ±50%）
    var jitter: Double = 0.3
    /// 开始前倒计时秒数，留出切换窗口的时间
    var countdown: TimeInterval = 2
    /// 换行后清除编辑器自动插入的缩进（VSCode 默认会自动缩进）
    var clearAutoIndent: Bool = true
    var suggestionDismiss: SuggestionDismiss = .cursorNudge
    var tabWidth: Int = 4
}

enum TypingResult {
    case completed
    case aborted
    case noPermission
    case selfFocused
    case empty
}

/// 键入动作的最小单位。把"打什么"与"怎么打"分开，便于在测试中用编辑器模型验证算法。
enum TypingStep: Equatable {
    case char(Character)     // 键入一个字符（选区存在时会替换选区）
    case newline             // 回车
    case escape              // Esc，关闭补全浮层（会退出浏览器全屏）
    case cursorNudge         // 左移再右移，位置不变但会关闭补全浮层
    case marker              // 占位字符，保证随后的选区非空
    case selectToLineStart   // 从光标选到行首（⌘⇧← 按两次，兼容智能行首）
    case deleteSelection     // 退格，删除选区
}

/// 用合成键盘事件把文本键入当前焦点所在的输入框（需要「辅助功能」权限）。
final class TextTyper {
    static let shared = TextTyper()
    static let markerCharacter: Character = "x"

    private let queue = DispatchQueue(label: "com.li.screenai.typer", qos: .userInitiated)
    private let lock = NSLock()
    private var _aborted = false
    private var _typing = false

    /// (已键入可见字符数, 总数)，主线程回调
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

    // MARK: 键入计划

    /// 把代码转换成键入步骤。
    /// clearAutoIndent 时的做法：换行后先打一个占位字符，保证「选到行首」的选区非空
    /// （否则空行上的退格会删掉刚建立的换行），再选中「自动缩进 + 占位字符」，
    /// 由本行的第一个字符直接替换选区；空行则用退格删除选区。
    static func plan(code: String, clearAutoIndent: Bool, dismiss: SuggestionDismiss = .cursorNudge) -> [TypingStep] {
        var steps: [TypingStep] = []
        let lines = code.components(separatedBy: "\n")
        // 注意：不在开头插入关闭浮层的动作。此时光标可能停在文稿最开头，
        // 左移无效而右移会前进一格，导致插入点偏移；换行前一定已经离开了文稿开头。
        for (index, line) in lines.enumerated() {
            if index > 0 {
                // 先关掉补全浮层，保证回车真的换行，而不是被「回车接受补全」吃掉
                switch dismiss {
                case .none: break
                case .cursorNudge: steps.append(.cursorNudge)
                case .escape: steps.append(.escape)
                }
                steps.append(.newline)
                if clearAutoIndent {
                    steps.append(.marker)
                    steps.append(.selectToLineStart)
                    if line.isEmpty { steps.append(.deleteSelection) }
                }
            }
            for ch in line { steps.append(.char(ch)) }
        }
        return steps
    }

    /// 计划中会产生可见文本的步骤数，用于进度显示
    static func visibleCount(_ steps: [TypingStep]) -> Int {
        steps.reduce(0) { acc, step in
            switch step {
            case .char, .newline: return acc + 1
            default: return acc
            }
        }
    }

    // MARK: 控制

    func abort() { lock.lock(); _aborted = true; lock.unlock() }

    private var aborted: Bool { lock.lock(); defer { lock.unlock() }; return _aborted }

    func type(_ text: String, options: TypingOptions) {
        lock.lock()
        guard !_typing else { lock.unlock(); return }
        _typing = true
        _aborted = false
        lock.unlock()

        let code = CodeExtractor.normalize(text, tabWidth: options.tabWidth)
        guard !code.isEmpty else { finish(.empty); return }
        guard TextTyper.hasPermission() else { finish(.noPermission); return }
        if TextTyper.selfIsFrontmost() { finish(.selfFocused); return }

        let steps = TextTyper.plan(code: code, clearAutoIndent: options.clearAutoIndent, dismiss: options.suggestionDismiss)
        queue.async { [weak self] in
            guard let self = self else { return }
            if !self.sleepInterruptibly(options.countdown) { self.finish(.aborted); return }
            if TextTyper.selfIsFrontmost() { self.finish(.selfFocused); return }
            self.run(steps, options: options)
        }
    }

    static func selfIsFrontmost() -> Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid()
    }

    // MARK: 执行

    private func run(_ steps: [TypingStep], options: TypingOptions) {
        let source = CGEventSource(stateID: .hidSystemState)
        source?.keyboardType = 0
        let total = TextTyper.visibleCount(steps)
        var typed = 0
        let baseDelay = 1.0 / max(1.0, options.charsPerSecond)
        let jitter = min(max(options.jitter, 0), 0.9)

        for step in steps {
            if aborted { finish(.aborted); return }
            switch step {
            case .char(let c):
                postUnicode(String(c), source: source)
                typed += 1
                if typed % 8 == 0 { report(typed, total) }
                let factor = jitter > 0 ? Double.random(in: (1 - jitter)...(1 + jitter)) : 1
                if !sleepInterruptibly(baseDelay * factor) { finish(.aborted); return }
            case .escape:
                postKey(CGKeyCode(kVK_Escape), source: source)
                usleep(12_000)
            case .cursorNudge:
                // 左移再右移：净位移为零，但足以让编辑器取消补全浮层
                postKey(CGKeyCode(kVK_LeftArrow), source: source)
                postKey(CGKeyCode(kVK_RightArrow), source: source)
                usleep(12_000)
            case .newline:
                postKey(CGKeyCode(kVK_Return), source: source)
                typed += 1
                report(typed, total)
                // 换行后稍作停顿，等编辑器完成自动缩进等处理
                if !sleepInterruptibly(max(baseDelay, 0.030)) { finish(.aborted); return }
            case .marker:
                postUnicode(String(TextTyper.markerCharacter), source: source)
                usleep(6_000)
            case .selectToLineStart:
                // 按两次：VSCode 的行首是智能行首，第一次到首个非空白字符，第二次才到第 0 列；
                // 普通 macOS 文本视图两次都停在行首，无副作用。
                postKey(CGKeyCode(kVK_LeftArrow), flags: [.maskCommand, .maskShift], source: source)
                postKey(CGKeyCode(kVK_LeftArrow), flags: [.maskCommand, .maskShift], source: source)
                usleep(6_000)
            case .deleteSelection:
                postKey(CGKeyCode(kVK_Delete), source: source)
                usleep(6_000)
            }
        }
        report(total, total)
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
        usleep(3_000)
    }

    /// 分片睡眠，便于及时响应停止；返回 false 表示被中止
    private func sleepInterruptibly(_ seconds: TimeInterval) -> Bool {
        guard seconds > 0 else { return !aborted }
        var remaining = seconds
        while remaining > 0 {
            if aborted { return false }
            let step = min(0.02, remaining)
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

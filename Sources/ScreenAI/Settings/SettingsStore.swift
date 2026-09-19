import Foundation
import Combine

/// 所有用户偏好设置；写入 UserDefaults，API Key 走钥匙串。
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    static let defaultPrompt = """
你是屏幕答题助手。请分析截图，从上到下逐题识别其中的题目。

规则：
1. 按题号分段，逐题独立处理，绝不把一道题的选项用到另一道题上。
2. 如果某道题的题干或选项被画面边缘截断、缺少选项、或看不到完整题干，直接跳过该题，不要输出，也不要说明跳过原因。
3. 按题型输出：
   - 选择题、多选题、填空题、判断题：每道完整的题输出一行，格式为「题号. 答案」，例如「2. B」「5. AC」「7. 光合作用」。只给答案，不要解释，不要使用代码块。
   - 编程题：只输出完整可运行的代码，整段放在一个 ``` 代码块中，代码块外不要写任何文字。
4. 如果画面中没有任何完整题目，只输出：未检测到完整题目
"""

    /// v1.1 及更早的默认提示词，仅用于升级迁移
    static let legacyPrompt = "你是一个题目识别与解答助手。请分析提供的屏幕截图，识别其中包含的题目内容（包括图片和文字区域），将题目完整地整理出来，然后给出正确答案。仅输出答案文本，不要包含额外解释。如果截图中没有题目，输出\"未检测到题目\"。"

    static var defaultHistoryDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("ScreenAI/History", isDirectory: true)
    }

    private let d: UserDefaults

    // MARK: API
    @Published var apiProvider: AIProviderKind { didSet { d.set(apiProvider.rawValue, forKey: "apiProvider") } }
    @Published var modelByProvider: [String: String] { didSet { d.set(modelByProvider, forKey: "modelByProvider") } }
    @Published var customEndpoint: String { didSet { d.set(customEndpoint, forKey: "customEndpoint") } }
    @Published var promptTemplate: String { didSet { d.set(promptTemplate, forKey: "promptTemplate") } }
    @Published var apiTimeout: Double { didSet { d.set(apiTimeout, forKey: "apiTimeout") } }
    @Published var streamingEnabled: Bool { didSet { d.set(streamingEnabled, forKey: "streamingEnabled") } }
    @Published var maxImageLongEdge: Int { didSet { d.set(maxImageLongEdge, forKey: "maxImageLongEdge") } }
    @Published var jpegQuality: Double { didSet { d.set(jpegQuality, forKey: "jpegQuality") } }
    /// 各厂商独立的请求参数
    @Published var paramsByProvider: [String: ProviderParams] { didSet { d.setCodable(paramsByProvider, forKey: "paramsByProvider") } }

    // MARK: Capture
    @Published var captureScope: CaptureScope { didSet { d.set(captureScope.rawValue, forKey: "captureScope") } }
    @Published var selectedDisplayID: UInt32 { didSet { d.set(Int(selectedDisplayID), forKey: "selectedDisplayID") } }
    @Published var selectedWindow: WindowRef? { didSet { d.setCodable(selectedWindow, forKey: "selectedWindow") } }
    @Published var selectedRegion: RegionRef? { didSet { d.setCodable(selectedRegion, forKey: "selectedRegion") } }
    @Published var windowLossBehavior: TargetLossBehavior { didSet { d.set(windowLossBehavior.rawValue, forKey: "windowLossBehavior") } }
    @Published var displayLossBehavior: TargetLossBehavior { didSet { d.set(displayLossBehavior.rawValue, forKey: "displayLossBehavior") } }
    @Published var regionLossBehavior: TargetLossBehavior { didSet { d.set(regionLossBehavior.rawValue, forKey: "regionLossBehavior") } }
    @Published var debounceMs: Int { didSet { d.set(debounceMs, forKey: "debounceMs") } }
    @Published var captureEnabled: Bool { didSet { d.set(captureEnabled, forKey: "captureEnabled") } }
    @Published var autoCaptureEnabled: Bool { didSet { d.set(autoCaptureEnabled, forKey: "autoCaptureEnabled") } }
    @Published var autoCaptureInterval: Double { didSet { d.set(autoCaptureInterval, forKey: "autoCaptureInterval") } }
    @Published var autoCaptureSkipUnchanged: Bool { didSet { d.set(autoCaptureSkipUnchanged, forKey: "autoCaptureSkipUnchanged") } }
    @Published var hotkey: Hotkey { didSet { d.setCodable(hotkey, forKey: "hotkey") } }
    /// 快捷键类型："combo"（组合键）或 "single"（单键）
    @Published var hotkeyMode: String { didSet { d.set(hotkeyMode, forKey: "hotkeyMode") } }
    @Published var typeHotkey: Hotkey { didSet { d.setCodable(typeHotkey, forKey: "typeHotkey") } }
    @Published var stopHotkey: Hotkey { didSet { d.setCodable(stopHotkey, forKey: "stopHotkey") } }

    // MARK: 键入到光标（编程题）
    @Published var typingCPS: Double { didSet { d.set(typingCPS, forKey: "typingCPS") } }
    @Published var typingJitter: Double { didSet { d.set(typingJitter, forKey: "typingJitter") } }
    @Published var typingCountdown: Double { didSet { d.set(typingCountdown, forKey: "typingCountdown") } }
    @Published var typingClearAutoIndent: Bool { didSet { d.set(typingClearAutoIndent, forKey: "typingClearAutoIndent") } }
    @Published var typingTabWidth: Int { didSet { d.set(typingTabWidth, forKey: "typingTabWidth") } }

    // MARK: Caption
    @Published var captionMode: CaptionMode { didSet { d.set(captionMode.rawValue, forKey: "captionMode") } }
    @Published var captionOpacity: Double { didSet { d.set(captionOpacity, forKey: "captionOpacity") } }
    @Published var captionFontSize: Double { didSet { d.set(captionFontSize, forKey: "captionFontSize") } }
    @Published var captionHistoryCount: Int { didSet { d.set(captionHistoryCount, forKey: "captionHistoryCount") } }
    @Published var captionWidth: Double { didSet { d.set(captionWidth, forKey: "captionWidth") } }
    @Published var captionHeight: Double { didSet { d.set(captionHeight, forKey: "captionHeight") } }
    @Published var autoCopyToClipboard: Bool { didSet { d.set(autoCopyToClipboard, forKey: "autoCopyToClipboard") } }

    // MARK: Connection
    @Published var listenPort: Int { didSet { d.set(listenPort, forKey: "listenPort") } }
    /// 对外公布的地址形式："hostname"（<主机名>.local，走 mDNS/IPv6 链路本地，不受 VPN 的 IPv4 过滤影响）或 "ip"（局域网 IPv4）
    @Published var addressMode: String { didSet { d.set(addressMode, forKey: "addressMode") } }

    // MARK: History
    @Published var historyDirectory: String { didSet { d.set(historyDirectory, forKey: "historyDirectory") } }

    init(defaults: UserDefaults = .standard) {
        d = defaults
        apiProvider = AIProviderKind(rawValue: d.string(forKey: "apiProvider") ?? "") ?? .openai
        modelByProvider = (d.dictionary(forKey: "modelByProvider") as? [String: String]) ?? [:]
        customEndpoint = d.string(forKey: "customEndpoint") ?? ""
        promptTemplate = d.string(forKey: "promptTemplate") ?? SettingsStore.defaultPrompt
        apiTimeout = d.object(forKey: "apiTimeout") as? Double ?? 60
        streamingEnabled = d.object(forKey: "streamingEnabled") as? Bool ?? true
        maxImageLongEdge = d.object(forKey: "maxImageLongEdge") as? Int ?? 1600
        jpegQuality = d.object(forKey: "jpegQuality") as? Double ?? 0.85
        paramsByProvider = d.codable([String: ProviderParams].self, forKey: "paramsByProvider") ?? [:]

        captureScope = CaptureScope(rawValue: d.string(forKey: "captureScope") ?? "") ?? .fullScreen
        selectedDisplayID = UInt32(clamping: d.integer(forKey: "selectedDisplayID"))
        selectedWindow = d.codable(WindowRef.self, forKey: "selectedWindow")
        selectedRegion = d.codable(RegionRef.self, forKey: "selectedRegion")
        windowLossBehavior = TargetLossBehavior(rawValue: d.string(forKey: "windowLossBehavior") ?? "") ?? .stop
        displayLossBehavior = TargetLossBehavior(rawValue: d.string(forKey: "displayLossBehavior") ?? "") ?? .stop
        regionLossBehavior = TargetLossBehavior(rawValue: d.string(forKey: "regionLossBehavior") ?? "") ?? .stop
        debounceMs = d.object(forKey: "debounceMs") as? Int ?? 300
        captureEnabled = d.object(forKey: "captureEnabled") as? Bool ?? true
        autoCaptureEnabled = d.object(forKey: "autoCaptureEnabled") as? Bool ?? false
        autoCaptureInterval = d.object(forKey: "autoCaptureInterval") as? Double ?? 30
        autoCaptureSkipUnchanged = d.object(forKey: "autoCaptureSkipUnchanged") as? Bool ?? true
        hotkey = d.codable(Hotkey.self, forKey: "hotkey") ?? Hotkey.default
        hotkeyMode = d.string(forKey: "hotkeyMode") ?? "combo"
        // 未设置过时，按当前快捷键类型给出对应的默认值，避免与「快捷键类型」开关不一致
        let singleMode = (d.string(forKey: "hotkeyMode") ?? "combo") == "single"
        typeHotkey = d.codable(Hotkey.self, forKey: "typeHotkey") ?? (singleMode ? Hotkey.defaultTypeSingle : Hotkey.defaultType)
        stopHotkey = d.codable(Hotkey.self, forKey: "stopHotkey") ?? (singleMode ? Hotkey.defaultStopSingle : Hotkey.defaultStop)
        typingCPS = d.object(forKey: "typingCPS") as? Double ?? 25
        typingJitter = d.object(forKey: "typingJitter") as? Double ?? 0.3
        typingCountdown = d.object(forKey: "typingCountdown") as? Double ?? 2
        typingClearAutoIndent = d.object(forKey: "typingClearAutoIndent") as? Bool ?? true
        typingTabWidth = d.object(forKey: "typingTabWidth") as? Int ?? 4

        captionMode = CaptionMode(rawValue: d.string(forKey: "captionMode") ?? "") ?? .staticList
        captionOpacity = d.object(forKey: "captionOpacity") as? Double ?? 0.9
        captionFontSize = d.object(forKey: "captionFontSize") as? Double ?? 14
        captionHistoryCount = d.object(forKey: "captionHistoryCount") as? Int ?? 5
        captionWidth = d.object(forKey: "captionWidth") as? Double ?? 400
        captionHeight = d.object(forKey: "captionHeight") as? Double ?? 220
        autoCopyToClipboard = d.object(forKey: "autoCopyToClipboard") as? Bool ?? false

        listenPort = d.object(forKey: "listenPort") as? Int ?? 8899
        addressMode = d.string(forKey: "addressMode") ?? "hostname"
        historyDirectory = d.string(forKey: "historyDirectory") ?? SettingsStore.defaultHistoryDirectory.path
        migrateIfNeeded()
        migratePromptIfNeeded()
    }

    /// 用户仍在使用 v1.1 的默认提示词时，自动升级为支持多题与编程题识别的新模板；
    /// 自定义过的提示词不会被覆盖。
    private func migratePromptIfNeeded() {
        guard !d.bool(forKey: "migratedPromptV3") else { return }
        if promptTemplate.trimmingCharacters(in: .whitespacesAndNewlines) == SettingsStore.legacyPrompt.trimmingCharacters(in: .whitespacesAndNewlines) {
            promptTemplate = SettingsStore.defaultPrompt
        }
        d.set(true, forKey: "migratedPromptV3")
    }

    var typingOptions: TypingOptions {
        TypingOptions(charsPerSecond: typingCPS, jitter: typingJitter, countdown: typingCountdown,
                      clearAutoIndent: typingClearAutoIndent, tabWidth: typingTabWidth)
    }

    /// 旧版本（全局 maxTokens / thinkingMode / imageDetail，DeepSeek、Kimi 走「自定义」）→ 按厂商参数
    private func migrateIfNeeded() {
        guard !d.bool(forKey: "migratedProviderParamsV2") else { return }
        if paramsByProvider.isEmpty {
            let oldMax = d.object(forKey: "maxTokens") as? Int
            let oldThinking = d.string(forKey: "thinkingMode") ?? "default"
            let oldDetail = d.string(forKey: "imageDetail") ?? "auto"
            var map: [String: ProviderParams] = [:]
            for kind in AIProviderKind.allCases {
                var p = ProviderParams.defaults(for: kind)
                if let m = oldMax { p.maxTokens = max(m, kind == .kimi ? 16000 : m) }
                switch oldThinking {
                case "disabled": p.thinking = "disabled"
                case "low", "high", "max": p.reasoningEffort = oldThinking
                default: break
                }
                if oldDetail != "auto" { p.imageDetail = oldDetail }
                map[kind.rawValue] = p
            }
            paramsByProvider = map
        }
        // 自定义端点指向 DeepSeek / Kimi 时迁移为专用厂商，并搬运 API Key 与模型名
        let ep = customEndpoint.lowercased()
        var target: AIProviderKind?
        if ep.contains("deepseek.com") { target = .deepseek }
        else if ep.contains("moonshot.cn") || ep.contains("moonshot.ai") || ep.contains("kimi.com") { target = .kimi }
        if let t = target, apiProvider == .custom {
            if let key = KeychainStore.read(account: AIProviderKind.custom.rawValue), !key.isEmpty, (KeychainStore.read(account: t.rawValue) ?? "").isEmpty {
                KeychainStore.write(account: t.rawValue, value: key)
            }
            var model = modelByProvider[AIProviderKind.custom.rawValue] ?? ""
            if t == .deepseek, model == "deepseek-v4-flash-vision-exp" { model = "deepseek-flash" }
            if !model.isEmpty { modelByProvider[t.rawValue] = model }
            apiProvider = t
        }
        d.set(true, forKey: "migratedProviderParamsV2")
    }

    // MARK: 厂商参数

    func params(for kind: AIProviderKind) -> ProviderParams {
        paramsByProvider[kind.rawValue] ?? ProviderParams.defaults(for: kind)
    }

    func setParams(_ p: ProviderParams, for kind: AIProviderKind) {
        paramsByProvider[kind.rawValue] = p
    }

    var currentParams: ProviderParams {
        get { params(for: apiProvider) }
        set { setParams(newValue, for: apiProvider) }
    }

    // MARK: Derived

    var currentModel: String {
        get { modelByProvider[apiProvider.rawValue] ?? apiProvider.defaultModel }
        set { modelByProvider[apiProvider.rawValue] = newValue }
    }

    func model(for kind: AIProviderKind) -> String {
        modelByProvider[kind.rawValue] ?? kind.defaultModel
    }

    var currentEndpoint: String {
        apiProvider == .custom ? customEndpoint : apiProvider.defaultEndpoint
    }

    func apiKey(for kind: AIProviderKind) -> String {
        KeychainStore.read(account: kind.rawValue) ?? ""
    }

    func setAPIKey(_ key: String, for kind: AIProviderKind) {
        KeychainStore.write(account: kind.rawValue, value: key.trimmingCharacters(in: .whitespacesAndNewlines))
        objectWillChange.send()
    }

    var historyDirectoryURL: URL { URL(fileURLWithPath: historyDirectory, isDirectory: true) }
}

extension UserDefaults {
    func setCodable<T: Encodable>(_ value: T?, forKey key: String) {
        guard let value = value, let data = try? JSONEncoder().encode(value) else {
            removeObject(forKey: key)
            return
        }
        set(data, forKey: key)
    }

    func codable<T: Decodable>(_ type: T.Type, forKey key: String) -> T? {
        guard let data = data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}

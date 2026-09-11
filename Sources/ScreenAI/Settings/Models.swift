import Foundation
import CoreGraphics

enum AIProviderKind: String, CaseIterable, Codable, Identifiable {
    case openai, anthropic, gemini, deepseek, kimi, custom
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openai: return "OpenAI"
        case .anthropic: return "Anthropic"
        case .gemini: return "Google Gemini"
        case .deepseek: return "DeepSeek"
        case .kimi: return "Kimi（月之暗面）"
        case .custom: return "自定义（OpenAI 兼容）"
        }
    }

    var defaultModel: String {
        switch self {
        case .openai: return "gpt-5"
        case .anthropic: return "claude-opus-5"
        case .gemini: return "gemini-2.5-flash"
        case .deepseek: return "deepseek-flash"
        case .kimi: return "kimi-k2.6"
        case .custom: return ""
        }
    }

    var defaultEndpoint: String {
        switch self {
        case .openai: return "https://api.openai.com/v1"
        case .anthropic: return "https://api.anthropic.com"
        case .gemini: return "https://generativelanguage.googleapis.com"
        case .deepseek: return "https://api.deepseek.com"
        case .kimi: return "https://api.moonshot.cn/v1"
        case .custom: return ""
        }
    }

    /// 走 OpenAI Chat Completions 协议
    var isOpenAICompatible: Bool {
        switch self {
        case .openai, .deepseek, .kimi, .custom: return true
        case .anthropic, .gemini: return false
        }
    }

    /// 模型名提示
    var modelHint: String {
        switch self {
        case .openai: return "gpt-5 / gpt-5-mini / gpt-4.1"
        case .anthropic: return "claude-opus-5 / claude-sonnet-5"
        case .gemini: return "gemini-2.5-flash / gemini-3-pro-preview"
        case .deepseek: return "deepseek-flash（支持图片）；deepseek-v4-pro 不支持图片"
        case .kimi: return "kimi-k2.6（可关思考）/ kimi-k3（始终推理）/ kimi-k2.7-code"
        case .custom: return "填写端点要求的模型名"
        }
    }
}

/// 每个厂商独立保存的请求参数；各字段是否生效由厂商决定，见 OpenAIProvider.requestBody 等。
struct ProviderParams: Codable, Equatable {
    var maxTokens: Int = 8192
    var temperature: Double? = nil          // nil = 不发送
    var topP: Double? = nil                 // nil = 不发送
    var thinking: String = "default"        // default / enabled / disabled / adaptive
    var thinkingKeep: Bool = false          // Kimi：thinking.keep = "all"
    var reasoningEffort: String = "default" // default / none / minimal / low / medium / high / max
    var imageDetail: String = "auto"        // auto = 不发送 / low / high / original
    var maxTokensField: String = "auto"     // 自定义端点：auto / max_tokens / max_completion_tokens
    var extraJSON: String = ""              // 自定义端点：额外请求体字段（JSON 对象）

    static func defaults(for kind: AIProviderKind) -> ProviderParams {
        var p = ProviderParams()
        switch kind {
        case .kimi: p.maxTokens = 16000
        case .anthropic: p.maxTokens = 8192
        default: break
        }
        return p
    }

    /// 解析额外 JSON；非对象或解析失败返回 nil
    var extraObject: [String: Any]? {
        let t = extraJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, let obj = JSON.parse(t) else { return nil }
        return obj
    }

    var extraJSONIsValid: Bool {
        extraJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || extraObject != nil
    }

    enum CodingKeys: String, CodingKey { case maxTokens, temperature, topP, thinking, thinkingKeep, reasoningEffort, imageDetail, maxTokensField, extraJSON }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        maxTokens = try c.decodeIfPresent(Int.self, forKey: .maxTokens) ?? 8192
        temperature = try c.decodeIfPresent(Double.self, forKey: .temperature)
        topP = try c.decodeIfPresent(Double.self, forKey: .topP)
        thinking = try c.decodeIfPresent(String.self, forKey: .thinking) ?? "default"
        thinkingKeep = try c.decodeIfPresent(Bool.self, forKey: .thinkingKeep) ?? false
        reasoningEffort = try c.decodeIfPresent(String.self, forKey: .reasoningEffort) ?? "default"
        imageDetail = try c.decodeIfPresent(String.self, forKey: .imageDetail) ?? "auto"
        maxTokensField = try c.decodeIfPresent(String.self, forKey: .maxTokensField) ?? "auto"
        extraJSON = try c.decodeIfPresent(String.self, forKey: .extraJSON) ?? ""
    }
}

enum CaptureScope: String, CaseIterable, Codable, Identifiable {
    case fullScreen, display, window, region
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .fullScreen: return "全屏（鼠标所在显示器）"
        case .display: return "指定显示器"
        case .window: return "指定窗口"
        case .region: return "指定区域"
        }
    }
}

enum TargetLossBehavior: String, CaseIterable, Codable, Identifiable {
    case stop, fallbackFullScreen
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .stop: return "停止捕获"
        case .fallbackFullScreen: return "自动回退全屏"
        }
    }
}

enum CaptionMode: String, CaseIterable, Codable, Identifiable {
    case off, staticList, marquee
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .off: return "不显示（仅手机推送）"
        case .staticList: return "静态列表"
        case .marquee: return "跑马灯"
        }
    }
}

/// 窗口引用：不保存易变的 windowID，而是保存应用与标题，捕获前重新解析。
struct WindowRef: Codable, Equatable, Hashable {
    var bundleID: String?
    var ownerName: String
    var title: String

    var displayName: String { "\(ownerName) – \(title)" }
}

/// 区域引用：全局 CG 坐标（点，原点在主显示器左上角）+ 所属显示器。
struct RegionRef: Codable, Equatable {
    var displayID: UInt32
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }

    var displayName: String {
        "区域 \(Int(width))×\(Int(height)) @(\(Int(x)),\(Int(y)))"
    }
}

struct DisplayInfo: Identifiable, Equatable {
    let id: UInt32
    let name: String
    let bounds: CGRect
    let scale: CGFloat
    var displayName: String {
        "\(name)（\(Int(bounds.width * scale))×\(Int(bounds.height * scale))）"
    }
}

struct WindowInfo: Identifiable, Equatable {
    let id: UInt32
    let pid: pid_t
    let bundleID: String?
    let ownerName: String
    let title: String
    let bounds: CGRect
    var ref: WindowRef { WindowRef(bundleID: bundleID, ownerName: ownerName, title: title) }
    var displayName: String { "\(ownerName) – \(title)" }
}

import Foundation
import CoreGraphics

enum AIProviderKind: String, CaseIterable, Codable, Identifiable {
    case openai, anthropic, gemini, custom
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openai: return "OpenAI"
        case .anthropic: return "Anthropic"
        case .gemini: return "Google Gemini"
        case .custom: return "自定义（OpenAI 兼容）"
        }
    }

    var defaultModel: String {
        switch self {
        case .openai: return "gpt-5"
        case .anthropic: return "claude-opus-5"
        case .gemini: return "gemini-2.5-flash"
        case .custom: return ""
        }
    }

    var defaultEndpoint: String {
        switch self {
        case .openai: return "https://api.openai.com/v1"
        case .anthropic: return "https://api.anthropic.com"
        case .gemini: return "https://generativelanguage.googleapis.com"
        case .custom: return ""
        }
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

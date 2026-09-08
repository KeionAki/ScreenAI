import Foundation

enum AIError: LocalizedError {
    case missingAPIKey
    case missingModel
    case invalidEndpoint
    case invalidAPIKey
    case modelNotFound(String)
    case rateLimited(retryAfter: TimeInterval?)
    case timeout
    case network(String)
    case imageTooLarge
    case server(status: Int, message: String)
    case badResponse(String)
    case refused(String)
    case emptyResponse(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: return "未配置 API Key，请在设置中填写"
        case .missingModel: return "未配置模型名称"
        case .invalidEndpoint: return "API 端点 URL 无效"
        case .invalidAPIKey: return "API Key 无效或已过期，请检查设置"
        case .modelNotFound(let m): return "模型不存在：\(m)，请检查模型名称"
        case .rateLimited: return "请求被限流（429），已重试仍失败"
        case .timeout: return "请求超时，请检查网络或增大超时时间"
        case .network(let s): return "网络错误：\(s)"
        case .imageTooLarge: return "图片过大，已降低质量仍被拒绝"
        case .server(let status, let message): return "API 错误（\(status)）：\(message)"
        case .badResponse(let s): return "响应解析失败：\(s)"
        case .refused(let s): return "模型拒绝回答：\(s)"
        case .emptyResponse(let s): return s
        case .cancelled: return "已取消"
        }
    }

    var isImageTooLarge: Bool {
        if case .imageTooLarge = self { return true }
        return false
    }

    var isRateLimited: Bool {
        if case .rateLimited = self { return true }
        return false
    }

    var isTimeout: Bool {
        if case .timeout = self { return true }
        return false
    }
}

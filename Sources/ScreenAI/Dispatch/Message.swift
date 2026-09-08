import Foundation

/// 服务器 → 手机端 / 字幕窗口 的消息。JSON 键使用 snake_case，时间戳为毫秒。
enum ServerMessage {
    case analysisStarted(id: String, timestamp: Date, source: String)
    case analysisThinking(id: String, chars: Int)
    case analysisPartial(id: String, delta: String)
    case analysisResult(id: String, timestamp: Date, result: String, source: String, model: String, latencyMs: Int)
    case error(id: String, timestamp: Date, message: String, source: String?)
    case statusChange(id: String, timestamp: Date, message: String, level: String)
    case heartbeat
    case authOK(expiresAt: Date)
    case authFailed(reason: String)

    var type: String {
        switch self {
        case .analysisStarted: return "analysis_started"
        case .analysisThinking: return "analysis_thinking"
        case .analysisPartial: return "analysis_partial"
        case .analysisResult: return "analysis_result"
        case .error: return "error"
        case .statusChange: return "status_change"
        case .heartbeat: return "heartbeat"
        case .authOK: return "auth_ok"
        case .authFailed: return "auth_failed"
        }
    }

    var dictionary: [String: Any] {
        var m: [String: Any] = ["type": type]
        switch self {
        case let .analysisStarted(id, ts, source):
            m["id"] = id; m["timestamp"] = ts.millis; m["capture_source"] = source
        case let .analysisThinking(id, chars):
            m["id"] = id; m["chars"] = chars
        case let .analysisPartial(id, delta):
            m["id"] = id; m["delta"] = delta
        case let .analysisResult(id, ts, result, source, model, latency):
            m["id"] = id; m["timestamp"] = ts.millis; m["result"] = result
            m["capture_source"] = source; m["model"] = model; m["latency_ms"] = latency
            m["status"] = "success"
        case let .error(id, ts, message, source):
            m["id"] = id; m["timestamp"] = ts.millis; m["error_message"] = message
            m["status"] = "error"
            if let source = source { m["capture_source"] = source }
        case let .statusChange(id, ts, message, level):
            m["id"] = id; m["timestamp"] = ts.millis; m["message"] = message; m["status"] = level
        case .heartbeat:
            m["timestamp"] = Date().millis
        case let .authOK(expiresAt):
            m["expires_at"] = expiresAt.millis
        case let .authFailed(reason):
            m["reason"] = reason
        }
        return m
    }

    var json: String {
        JSON.string(dictionary)
    }
}

enum JSON {
    static func string(_ object: Any) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }

    static func data(_ object: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
    }

    static func parse(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func parse(_ text: String) -> [String: Any]? {
        parse(Data(text.utf8))
    }
}

extension Date {
    var millis: Int { Int((timeIntervalSince1970 * 1000).rounded()) }
    static func fromMillis(_ ms: Int) -> Date { Date(timeIntervalSince1970: Double(ms) / 1000) }
}

extension String {
    /// 用于字幕/日志的短描述
    func truncated(_ max: Int) -> String {
        count <= max ? self : String(prefix(max)) + "…"
    }
}

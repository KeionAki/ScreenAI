import Foundation

struct HistoryRecord: Codable, Identifiable, Equatable {
    var id: String
    var timestamp: Date
    var captureSource: String
    var promptHash: String
    var provider: String
    var model: String
    var result: String
    var status: String        // success / error
    var errorMessage: String
    var latencyMs: Int

    static let csvHeader = ["id", "timestamp", "capture_source", "prompt_hash", "provider", "model", "result", "status", "error_message", "latency_ms"]

    var csvFields: [String] {
        [id, ISO8601.string(timestamp), captureSource, promptHash, provider, model, result, status, errorMessage, String(latencyMs)]
    }

    init(id: String = UUID().uuidString, timestamp: Date = Date(), captureSource: String, promptHash: String, provider: String, model: String, result: String, status: String, errorMessage: String = "", latencyMs: Int = 0) {
        self.id = id; self.timestamp = timestamp; self.captureSource = captureSource; self.promptHash = promptHash
        self.provider = provider; self.model = model; self.result = result; self.status = status
        self.errorMessage = errorMessage; self.latencyMs = latencyMs
    }

    init?(csvFields f: [String]) {
        guard f.count >= 10, let ts = ISO8601.date(f[1]) else { return nil }
        self.init(id: f[0], timestamp: ts, captureSource: f[2], promptHash: f[3], provider: f[4], model: f[5], result: f[6], status: f[7], errorMessage: f[8], latencyMs: Int(f[9]) ?? 0)
    }

    var jsonObject: [String: Any] {
        [
            "id": id,
            "timestamp": timestamp.millis,
            "timestamp_iso": ISO8601.string(timestamp),
            "capture_source": captureSource,
            "prompt_hash": promptHash,
            "provider": provider,
            "model": model,
            "result": result,
            "status": status,
            "error_message": errorMessage,
            "latency_ms": latencyMs,
        ]
    }
}

enum ISO8601 {
    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let fallback: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    static func string(_ d: Date) -> String { formatter.string(from: d) }
    static func date(_ s: String) -> Date? { formatter.date(from: s) ?? fallback.date(from: s) }
}

enum DayKey {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    static func string(_ d: Date) -> String { formatter.string(from: d) }
    static func isValid(_ s: String) -> Bool { formatter.date(from: s) != nil }
}

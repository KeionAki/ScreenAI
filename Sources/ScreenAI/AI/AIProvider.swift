import Foundation

struct AIRequest {
    var imageBase64: String
    var mimeType: String = "image/jpeg"
    var prompt: String
    var model: String
    var timeout: TimeInterval
    var stream: Bool
    var params: ProviderParams
}

/// 模型输出流事件
enum AIStreamEvent {
    case text(String)          // 正文增量
    case reasoning(String)     // 思考内容增量（不展示，仅用于进度）
    case finished(reason: String?)
}

struct AITestResult {
    var text: String
    var reasoningChars: Int
}

protocol AIProvider {
    var kind: AIProviderKind { get }
    /// 产出流事件；非流式模式下一次给出全文。
    func analyze(_ request: AIRequest) -> AsyncThrowingStream<AIStreamEvent, Error>
    func testConnection(model: String, timeout: TimeInterval, params: ProviderParams) async throws -> AITestResult
    func listModels(timeout: TimeInterval) async throws -> [String]
}

struct ProviderConfig {
    var kind: AIProviderKind
    var apiKey: String
    var endpoint: String
}

enum AIProviderFactory {
    static func make(_ config: ProviderConfig) -> AIProvider {
        switch config.kind {
        case .openai, .custom, .deepseek, .kimi: return OpenAIProvider(config: config)
        case .anthropic: return AnthropicProvider(config: config)
        case .gemini: return GeminiProvider(config: config)
        }
    }
}

// MARK: - 共享 HTTP 基础设施

enum AIHTTP {
    /// 诊断模式：每收到一行响应就回调（不含请求头，不会泄露 API Key）
    static var rawLineHandler: ((String) -> Void)?

    static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.waitsForConnectivity = false
        c.timeoutIntervalForRequest = 120
        c.timeoutIntervalForResource = 600
        return URLSession(configuration: c)
    }()

    static func request(url: URL, method: String = "POST", headers: [String: String], body: Any?, timeout: TimeInterval) throws -> URLRequest {
        var r = URLRequest(url: url)
        r.httpMethod = method
        r.timeoutInterval = timeout
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        if let body = body {
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = JSON.data(body)
        }
        return r
    }

    /// 非流式：返回 JSON 对象
    static func json(_ req: URLRequest, mapError: (Int, String) -> AIError) async throws -> [String: Any] {
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw translate(error)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if let h = rawLineHandler {
            h("HTTP \(status) \((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? "")")
            h(String(data: data.prefix(4000), encoding: .utf8) ?? "<非文本 \(data.count) 字节>")
        }
        guard (200..<300).contains(status) else {
            throw mapError(status, String(data: data, encoding: .utf8) ?? "")
        }
        guard let obj = JSON.parse(data) else {
            throw AIError.badResponse(String(data: data.prefix(300), encoding: .utf8) ?? "")
        }
        return obj
    }

    /// 流式：逐个 SSE 事件回调。若服务端忽略 stream 参数返回普通 JSON，则交给 onNonStream 处理。
    static func sse(_ req: URLRequest, mapError: (Int, String) -> AIError, onNonStream: ((Data) throws -> Void)? = nil, onEvent: (SSEEvent) throws -> Void) async throws {
        let (bytes, response): (URLSession.AsyncBytes, URLResponse)
        do {
            (bytes, response) = try await session.bytes(for: req)
        } catch {
            throw translate(error)
        }
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            var body = ""
            do {
                for try await line in bytes.lines { body += line; if body.count > 4000 { break } }
            } catch {}
            throw mapError(status, body)
        }
        let contentType = (http?.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        rawLineHandler?("HTTP \(status) \(contentType)")
        if !contentType.contains("text/event-stream") {
            var body = Data()
            do {
                for try await byte in bytes {
                    body.append(byte)
                    if body.count > 32 * 1024 * 1024 { break }
                }
            } catch {
                throw translate(error)
            }
            Log.ai.warning("流式请求收到非 SSE 响应（Content-Type: \(contentType, privacy: .public)，\(body.count) 字节），按普通 JSON 解析")
            rawLineHandler?(String(data: body.prefix(4000), encoding: .utf8) ?? "<非文本 \(body.count) 字节>")
            guard let fallback = onNonStream else {
                throw AIError.badResponse("服务端未按流式返回：\(String(data: body.prefix(200), encoding: .utf8) ?? "")")
            }
            try fallback(body)
            return
        }
        var parser = SSEParser()
        var eventCount = 0
        var sample = ""
        do {
            // 注意：不能用 bytes.lines，AsyncLineSequence 会吞掉空行，而 SSE 依赖空行分隔事件
            try await forEachLine(bytes) { line in
                try Task.checkCancellation()
                rawLineHandler?(line)
                if sample.count < 600 { sample += line.prefix(300) + "\n" }
                if let ev = parser.feed(line: line) { eventCount += 1; try onEvent(ev) }
            }
            if let ev = parser.flush() { eventCount += 1; try onEvent(ev) }
            if eventCount == 0 {
                Log.ai.warning("SSE 流没有任何事件，响应片段: \(sample, privacy: .public)")
            }
        } catch let e as AIError {
            throw e
        } catch is CancellationError {
            throw AIError.cancelled
        } catch {
            throw translate(error)
        }
    }

    /// 按字节切行，保留空行（LF 或 CRLF 结尾），用于 SSE 解析。
    static func forEachLine<S: AsyncSequence>(_ bytes: S, limit: Int = 64 * 1024 * 1024, _ body: (String) throws -> Void) async throws where S.Element == UInt8 {
        var buffer = [UInt8]()
        buffer.reserveCapacity(1024)
        var total = 0
        for try await byte in bytes {
            total += 1
            if byte == 0x0A {
                if buffer.last == 0x0D { buffer.removeLast() }
                try body(String(decoding: buffer, as: UTF8.self))
                buffer.removeAll(keepingCapacity: true)
            } else {
                buffer.append(byte)
            }
            if total > limit { break }
        }
        if !buffer.isEmpty {
            if buffer.last == 0x0D { buffer.removeLast() }
            try body(String(decoding: buffer, as: UTF8.self))
        }
    }

    static func translate(_ error: Error) -> AIError {
        if let e = error as? AIError { return e }
        if error is CancellationError { return .cancelled }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            switch ns.code {
            case NSURLErrorTimedOut: return .timeout
            case NSURLErrorCancelled: return .cancelled
            case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost, NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost, NSURLErrorDNSLookupFailed:
                return .network("无法连接到服务器，请检查互联网连接")
            default: return .network(ns.localizedDescription)
            }
        }
        return .network(ns.localizedDescription)
    }

    /// 通用状态码映射，各提供商可先尝试解析自己的错误消息
    static func mapStatus(_ status: Int, message: String, model: String) -> AIError {
        let lower = message.lowercased()
        switch status {
        case 401, 403: return .invalidAPIKey
        case 404:
            if lower.contains("model") { return .modelNotFound(model) }
            return .server(status: status, message: message.truncated(200))
        case 413: return .imageTooLarge
        case 429: return .rateLimited(retryAfter: nil)
        case 408, 504: return .timeout
        default:
            if lower.contains("too large") || lower.contains("exceeds") && lower.contains("size") || lower.contains("image") && lower.contains("too") {
                return .imageTooLarge
            }
            if status == 400 && (lower.contains("model") && (lower.contains("not found") || lower.contains("does not exist") || lower.contains("not exist") || lower.contains("invalid model"))) {
                return .modelNotFound(model)
            }
            return .server(status: status, message: message.truncated(300))
        }
    }

    /// 从常见错误 JSON 中提取 message
    static func extractMessage(_ body: String) -> String {
        guard let obj = JSON.parse(body) else { return body }
        if let err = obj["error"] as? [String: Any] {
            if let m = err["message"] as? String { return m }
        }
        if let err = obj["error"] as? String { return err }
        if let m = obj["message"] as? String { return m }
        return body
    }

    static func streamTask(_ work: @escaping (@escaping (AIStreamEvent) -> Void) async throws -> Void) -> AsyncThrowingStream<AIStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await work { event in continuation.yield(event) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: AIHTTP.translate(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func normalizedBase(_ endpoint: String, fallback: String) -> String {
        var e = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        if e.isEmpty { e = fallback }
        while e.hasSuffix("/") { e.removeLast() }
        return e
    }
}

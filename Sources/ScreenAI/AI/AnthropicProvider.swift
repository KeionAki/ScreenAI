import Foundation

/// Anthropic Messages API（/v1/messages），图片以 base64 内容块发送。
struct AnthropicProvider: AIProvider {
    let config: ProviderConfig
    var kind: AIProviderKind { .anthropic }
    static let apiVersion = "2023-06-01"

    init(config: ProviderConfig) { self.config = config }

    private var base: String {
        AIHTTP.normalizedBase(config.endpoint, fallback: AIProviderKind.anthropic.defaultEndpoint)
    }

    private var headers: [String: String] {
        ["x-api-key": config.apiKey, "anthropic-version": AnthropicProvider.apiVersion]
    }

    private func url(_ path: String) throws -> URL {
        guard let u = URL(string: base + path) else { throw AIError.invalidEndpoint }
        return u
    }

    private func mapError(_ status: Int, _ raw: String, model: String) -> AIError {
        let msg = AIHTTP.extractMessage(raw)
        if let obj = JSON.parse(raw), let err = obj["error"] as? [String: Any], let type = err["type"] as? String {
            switch type {
            case "authentication_error", "permission_error": return .invalidAPIKey
            case "not_found_error": return .modelNotFound(model)
            case "rate_limit_error": return .rateLimited(retryAfter: nil)
            case "request_too_large": return .imageTooLarge
            default: break
            }
        }
        return AIHTTP.mapStatus(status, message: msg, model: model)
    }

    private func body(model: String, content: [[String: Any]], maxTokens: Int, stream: Bool) -> [String: Any] {
        [
            "model": model,
            "max_tokens": maxTokens,
            "stream": stream,
            "messages": [["role": "user", "content": content] as [String: Any]],
        ]
    }

    func analyze(_ request: AIRequest) -> AsyncThrowingStream<AIStreamEvent, Error> {
        AIHTTP.streamTask { emit in
            guard !config.apiKey.isEmpty else { throw AIError.missingAPIKey }
            guard !request.model.isEmpty else { throw AIError.missingModel }
            let content: [[String: Any]] = [
                ["type": "image", "source": ["type": "base64", "media_type": request.mimeType, "data": request.imageBase64]],
                ["type": "text", "text": request.prompt],
            ]
            let req = try AIHTTP.request(url: try url("/v1/messages"), headers: headers,
                                         body: body(model: request.model, content: content, maxTokens: request.maxTokens, stream: request.stream),
                                         timeout: request.timeout)
            if request.stream {
                var stopReason: String?
                try await AIHTTP.sse(req, mapError: { mapError($0, $1, model: request.model) }, onNonStream: { data in
                    guard let obj = JSON.parse(data) else { throw AIError.badResponse(String(data: data.prefix(300), encoding: .utf8) ?? "") }
                    emit(.text(try AnthropicProvider.extractText(obj)))
                    let sr = obj["stop_reason"] as? String
                    emit(.finished(reason: sr == "max_tokens" ? "length" : sr))
                }) { ev in
                    guard let obj = JSON.parse(ev.data) else { return }
                    let type = (obj["type"] as? String) ?? ev.event ?? ""
                    switch type {
                    case "content_block_delta":
                        if let delta = obj["delta"] as? [String: Any], delta["type"] as? String == "text_delta",
                           let text = delta["text"] as? String, !text.isEmpty {
                            emit(.text(text))
                        }
                        if let delta = obj["delta"] as? [String: Any], delta["type"] as? String == "thinking_delta",
                           let t = delta["thinking"] as? String, !t.isEmpty {
                            emit(.reasoning(t))
                        }
                    case "message_delta":
                        if let delta = obj["delta"] as? [String: Any], let sr = delta["stop_reason"] as? String {
                            stopReason = sr
                        }
                    case "error":
                        let err = obj["error"] as? [String: Any]
                        let message = (err?["message"] as? String) ?? "stream error"
                        let etype = (err?["type"] as? String) ?? ""
                        if etype == "overloaded_error" { throw AIError.rateLimited(retryAfter: nil) }
                        throw AIError.server(status: 200, message: message)
                    default:
                        break
                    }
                }
                if stopReason == "refusal" { throw AIError.refused("请求被安全策略拒绝") }
                emit(.finished(reason: stopReason == "max_tokens" ? "length" : stopReason))
            } else {
                let obj = try await AIHTTP.json(req, mapError: { mapError($0, $1, model: request.model) })
                emit(.text(try AnthropicProvider.extractText(obj)))
                let sr = obj["stop_reason"] as? String
                emit(.finished(reason: sr == "max_tokens" ? "length" : sr))
            }
        }
    }

    static func extractText(_ obj: [String: Any]) throws -> String {
        if obj["stop_reason"] as? String == "refusal" {
            let details = obj["stop_details"] as? [String: Any]
            throw AIError.refused((details?["explanation"] as? String) ?? "请求被安全策略拒绝")
        }
        guard let content = obj["content"] as? [[String: Any]] else { throw AIError.badResponse("缺少 content") }
        return content.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
    }

    func testConnection(model: String, timeout: TimeInterval, thinking: ThinkingMode) async throws -> AITestResult {
        guard !config.apiKey.isEmpty else { throw AIError.missingAPIKey }
        guard !model.isEmpty else { throw AIError.missingModel }
        let content: [[String: Any]] = [["type": "text", "text": "请只回复 OK"]]
        let req = try AIHTTP.request(url: try url("/v1/messages"), headers: headers,
                                     body: body(model: model, content: content, maxTokens: 256, stream: false), timeout: timeout)
        let obj = try await AIHTTP.json(req, mapError: { mapError($0, $1, model: model) })
        return AITestResult(text: try AnthropicProvider.extractText(obj), reasoningChars: 0)
    }

    func listModels(timeout: TimeInterval) async throws -> [String] {
        guard !config.apiKey.isEmpty else { throw AIError.missingAPIKey }
        let req = try AIHTTP.request(url: try url("/v1/models?limit=100"), method: "GET", headers: headers, body: nil, timeout: timeout)
        let obj = try await AIHTTP.json(req, mapError: { mapError($0, $1, model: "") })
        let data = obj["data"] as? [[String: Any]] ?? []
        return data.compactMap { $0["id"] as? String }
    }
}

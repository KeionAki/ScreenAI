import Foundation

/// OpenAI 与 OpenAI 兼容端点（自定义，如 DeepSeek）。
struct OpenAIProvider: AIProvider {
    let config: ProviderConfig
    var kind: AIProviderKind { config.kind }

    init(config: ProviderConfig) { self.config = config }

    private var base: String {
        AIHTTP.normalizedBase(config.endpoint, fallback: AIProviderKind.openai.defaultEndpoint)
    }

    private func chatURL() throws -> URL {
        var b = base
        if !b.hasSuffix("/chat/completions") {
            b += "/chat/completions"
        }
        guard let url = URL(string: b), url.scheme != nil else { throw AIError.invalidEndpoint }
        return url
    }

    private func modelsURL() throws -> URL {
        var b = base
        if b.hasSuffix("/chat/completions") { b = String(b.dropLast("/chat/completions".count)) }
        guard let url = URL(string: b + "/models") else { throw AIError.invalidEndpoint }
        return url
    }

    private var headers: [String: String] {
        ["Authorization": "Bearer \(config.apiKey)"]
    }

    /// 思考模式参数：OpenAI 官方用 reasoning_effort；兼容端点（DeepSeek 等）用 thinking + reasoning_effort
    static func thinkingParameters(_ mode: ThinkingMode, kind: AIProviderKind) -> [String: Any] {
        var p: [String: Any] = [:]
        switch (kind, mode) {
        case (_, .default):
            break
        case (.openai, .disabled): p["reasoning_effort"] = "minimal"
        case (.openai, .low): p["reasoning_effort"] = "low"
        case (.openai, .high), (.openai, .max): p["reasoning_effort"] = "high"
        case (_, .disabled): p["thinking"] = ["type": "disabled"]
        case (_, .low): p["thinking"] = ["type": "enabled"]; p["reasoning_effort"] = "low"
        case (_, .high): p["thinking"] = ["type": "enabled"]; p["reasoning_effort"] = "high"
        case (_, .max): p["thinking"] = ["type": "enabled"]; p["reasoning_effort"] = "max"
        }
        return p
    }

    private func body(model: String, content: [[String: Any]], maxTokens: Int, stream: Bool, thinking: ThinkingMode) -> [String: Any] {
        var b: [String: Any] = [
            "model": model,
            "messages": [["role": "user", "content": content] as [String: Any]],
            "stream": stream,
        ]
        if config.kind == .openai {
            b["max_completion_tokens"] = maxTokens
        } else {
            b["max_tokens"] = maxTokens
        }
        for (k, v) in OpenAIProvider.thinkingParameters(thinking, kind: config.kind) { b[k] = v }
        return b
    }

    private func mapError(_ status: Int, _ raw: String, model: String) -> AIError {
        let msg = AIHTTP.extractMessage(raw)
        if status == 400, let obj = JSON.parse(raw), let err = obj["error"] as? [String: Any],
           let code = err["code"] as? String, code == "model_not_found" {
            return .modelNotFound(model)
        }
        return AIHTTP.mapStatus(status, message: msg, model: model)
    }

    /// 解析一个流式 chunk（choices[0].delta），返回事件列表。
    static func events(fromChunk obj: [String: Any]) throws -> [AIStreamEvent] {
        if let err = obj["error"] as? [String: Any] {
            throw AIError.server(status: 200, message: (err["message"] as? String) ?? "unknown error")
        }
        guard let choices = obj["choices"] as? [[String: Any]], let first = choices.first else { return [] }
        var out: [AIStreamEvent] = []
        if let delta = first["delta"] as? [String: Any] {
            if let r = delta["reasoning_content"] as? String, !r.isEmpty { out.append(.reasoning(r)) }
            if let t = delta["content"] as? String, !t.isEmpty { out.append(.text(t)) }
        }
        if let reason = first["finish_reason"] as? String, !reason.isEmpty { out.append(.finished(reason: reason)) }
        return out
    }

    /// 解析非流式响应：返回正文、思考内容与结束原因
    static func parseCompletion(_ obj: [String: Any]) throws -> (text: String, reasoning: String, finishReason: String?) {
        guard let choices = obj["choices"] as? [[String: Any]], let first = choices.first,
              let message = first["message"] as? [String: Any] else {
            throw AIError.badResponse("缺少 choices")
        }
        var text = ""
        if let s = message["content"] as? String { text = s }
        else if let parts = message["content"] as? [[String: Any]] { text = parts.compactMap { $0["text"] as? String }.joined() }
        if text.isEmpty, let refusal = message["refusal"] as? String, !refusal.isEmpty { throw AIError.refused(refusal) }
        let reasoning = (message["reasoning_content"] as? String) ?? (message["reasoning"] as? String) ?? ""
        return (text, reasoning, first["finish_reason"] as? String)
    }

    func analyze(_ request: AIRequest) -> AsyncThrowingStream<AIStreamEvent, Error> {
        AIHTTP.streamTask { emit in
            guard !config.apiKey.isEmpty || config.kind == .custom else { throw AIError.missingAPIKey }
            guard !request.model.isEmpty else { throw AIError.missingModel }
            var imageURL: [String: Any] = ["url": "data:\(request.mimeType);base64,\(request.imageBase64)"]
            if let d = request.imageDetail { imageURL["detail"] = d }
            let content: [[String: Any]] = [
                ["type": "text", "text": request.prompt],
                ["type": "image_url", "image_url": imageURL],
            ]
            let req = try AIHTTP.request(url: try chatURL(), headers: headers,
                                         body: body(model: request.model, content: content, maxTokens: request.maxTokens, stream: request.stream, thinking: request.thinking),
                                         timeout: request.timeout)
            if request.stream {
                try await AIHTTP.sse(req, mapError: { mapError($0, $1, model: request.model) }, onNonStream: { data in
                    guard let obj = JSON.parse(data) else {
                        throw AIError.badResponse(String(data: data.prefix(300), encoding: .utf8) ?? "")
                    }
                    if let err = obj["error"] as? [String: Any] {
                        throw AIError.server(status: 200, message: (err["message"] as? String) ?? "unknown error")
                    }
                    let parsed = try OpenAIProvider.parseCompletion(obj)
                    if !parsed.reasoning.isEmpty { emit(.reasoning(parsed.reasoning)) }
                    if !parsed.text.isEmpty { emit(.text(parsed.text)) }
                    emit(.finished(reason: parsed.finishReason))
                }) { ev in
                    let d = ev.data.trimmingCharacters(in: .whitespaces)
                    if d == "[DONE]" { return }
                    guard let obj = JSON.parse(d) else { return }
                    for e in try OpenAIProvider.events(fromChunk: obj) { emit(e) }
                }
            } else {
                let obj = try await AIHTTP.json(req, mapError: { mapError($0, $1, model: request.model) })
                let parsed = try OpenAIProvider.parseCompletion(obj)
                if !parsed.reasoning.isEmpty { emit(.reasoning(parsed.reasoning)) }
                if !parsed.text.isEmpty { emit(.text(parsed.text)) }
                emit(.finished(reason: parsed.finishReason))
            }
        }
    }

    func testConnection(model: String, timeout: TimeInterval, thinking: ThinkingMode) async throws -> AITestResult {
        guard !model.isEmpty else { throw AIError.missingModel }
        let content: [[String: Any]] = [["type": "text", "text": "请只回复 OK"]]
        let req = try AIHTTP.request(url: try chatURL(), headers: headers,
                                     body: body(model: model, content: content, maxTokens: 1024, stream: false, thinking: thinking), timeout: timeout)
        let obj = try await AIHTTP.json(req, mapError: { mapError($0, $1, model: model) })
        let parsed = try OpenAIProvider.parseCompletion(obj)
        return AITestResult(text: parsed.text, reasoningChars: parsed.reasoning.count)
    }

    func listModels(timeout: TimeInterval) async throws -> [String] {
        let req = try AIHTTP.request(url: try modelsURL(), method: "GET", headers: headers, body: nil, timeout: timeout)
        let obj = try await AIHTTP.json(req, mapError: { mapError($0, $1, model: "") })
        let data = obj["data"] as? [[String: Any]] ?? []
        return data.compactMap { $0["id"] as? String }.sorted()
    }
}

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

    /// 按厂商组装请求体：不同厂商支持的字段与取值不同，不支持的一律不发送（Kimi 传采样参数会直接报错）。
    static func requestBody(kind: AIProviderKind, model: String, content: [[String: Any]], stream: Bool, params: ProviderParams, maxTokensOverride: Int? = nil) -> [String: Any] {
        var b: [String: Any] = [
            "model": model,
            "messages": [["role": "user", "content": content] as [String: Any]],
            "stream": stream,
        ]
        let maxTokens = maxTokensOverride ?? params.maxTokens
        switch kind {
        case .openai, .kimi:
            b["max_completion_tokens"] = maxTokens
        case .custom:
            b[params.maxTokensField == "max_completion_tokens" ? "max_completion_tokens" : "max_tokens"] = maxTokens
        default:
            b["max_tokens"] = maxTokens
        }
        // 采样参数：Kimi 为固定值，传入即报错
        if kind != .kimi {
            if let t = params.temperature { b["temperature"] = t }
            if let tp = params.topP { b["top_p"] = tp }
        }
        let effort = params.reasoningEffort
        let thinking = params.thinking
        switch kind {
        case .openai:
            let map = ["none": "minimal", "minimal": "minimal", "low": "low", "medium": "medium", "high": "high", "max": "high"]
            if thinking == "disabled" { b["reasoning_effort"] = "minimal" }
            else if let e = map[effort] { b["reasoning_effort"] = e }
        case .deepseek:
            if thinking == "enabled" || thinking == "disabled" { b["thinking"] = ["type": thinking] }
            let map = ["none": "none", "minimal": "low", "low": "low", "medium": "high", "high": "high", "max": "max"]
            if let e = map[effort] { b["reasoning_effort"] = e }
        case .kimi:
            let m = model.lowercased()
            if m.hasPrefix("kimi-k3") {
                let map = ["none": "low", "minimal": "low", "low": "low", "medium": "high", "high": "high", "max": "max"]
                if let e = map[effort] { b["reasoning_effort"] = e }
            } else if m.contains("k2.7") {
                if params.thinkingKeep { b["thinking"] = ["type": "enabled", "keep": "all"] }
            } else {
                var t: [String: Any] = [:]
                if thinking == "enabled" || thinking == "disabled" { t["type"] = thinking }
                if params.thinkingKeep && thinking != "disabled" { t["type"] = t["type"] ?? "enabled"; t["keep"] = "all" }
                if !t.isEmpty { b["thinking"] = t }
            }
        case .custom:
            if thinking == "enabled" || thinking == "disabled" { b["thinking"] = ["type": thinking] }
            if effort != "default" { b["reasoning_effort"] = effort }
            if let extra = params.extraObject { for (k, v) in extra { b[k] = v } }
        default:
            break
        }
        return b
    }

    /// 图片块：Kimi 不支持 detail；OpenAI 没有 original
    static func imagePart(kind: AIProviderKind, mimeType: String, base64: String, params: ProviderParams) -> [String: Any] {
        var imageURL: [String: Any] = ["url": "data:\(mimeType);base64,\(base64)"]
        var detail = params.imageDetail
        if kind == .openai && detail == "original" { detail = "high" }
        if kind != .kimi && detail != "auto" && !detail.isEmpty { imageURL["detail"] = detail }
        return ["type": "image_url", "image_url": imageURL]
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
            if config.kind == .custom && !request.params.extraJSONIsValid { throw AIError.badResponse("额外参数不是合法的 JSON 对象") }
            let content: [[String: Any]] = [
                OpenAIProvider.imagePart(kind: config.kind, mimeType: request.mimeType, base64: request.imageBase64, params: request.params),
                ["type": "text", "text": request.prompt],
            ]
            let req = try AIHTTP.request(url: try chatURL(), headers: headers,
                                         body: OpenAIProvider.requestBody(kind: config.kind, model: request.model, content: content, stream: request.stream, params: request.params),
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

    func testConnection(model: String, timeout: TimeInterval, params: ProviderParams) async throws -> AITestResult {
        guard !model.isEmpty else { throw AIError.missingModel }
        let content: [[String: Any]] = [["type": "text", "text": "请只回复 OK"]]
        let req = try AIHTTP.request(url: try chatURL(), headers: headers,
                                     body: OpenAIProvider.requestBody(kind: config.kind, model: model, content: content, stream: false, params: params, maxTokensOverride: min(params.maxTokens, 4096)),
                                     timeout: timeout)
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

import Foundation

/// Google Gemini（generativelanguage.googleapis.com），使用 x-goog-api-key 头。
struct GeminiProvider: AIProvider {
    let config: ProviderConfig
    var kind: AIProviderKind { .gemini }

    init(config: ProviderConfig) { self.config = config }

    private var base: String {
        AIHTTP.normalizedBase(config.endpoint, fallback: AIProviderKind.gemini.defaultEndpoint)
    }

    private var headers: [String: String] { ["x-goog-api-key": config.apiKey] }

    private func url(model: String, method: String, stream: Bool) throws -> URL {
        let m = model.hasPrefix("models/") ? String(model.dropFirst(7)) : model
        var s = "\(base)/v1beta/models/\(m):\(method)"
        if stream { s += "?alt=sse" }
        guard let u = URL(string: s) else { throw AIError.invalidEndpoint }
        return u
    }

    private func mapError(_ status: Int, _ raw: String, model: String) -> AIError {
        let msg = AIHTTP.extractMessage(raw)
        if let obj = JSON.parse(raw), let err = obj["error"] as? [String: Any], let st = err["status"] as? String {
            switch st {
            case "UNAUTHENTICATED", "PERMISSION_DENIED": return .invalidAPIKey
            case "NOT_FOUND": return .modelNotFound(model)
            case "RESOURCE_EXHAUSTED": return .rateLimited(retryAfter: nil)
            default: break
            }
        }
        if status == 400 && msg.lowercased().contains("api key") { return .invalidAPIKey }
        return AIHTTP.mapStatus(status, message: msg, model: model)
    }

    private func body(parts: [[String: Any]], maxTokens: Int) -> [String: Any] {
        [
            "contents": [["role": "user", "parts": parts] as [String: Any]],
            "generationConfig": ["maxOutputTokens": maxTokens],
        ]
    }

    static func extractText(_ obj: [String: Any]) throws -> String {
        if let feedback = obj["promptFeedback"] as? [String: Any], let reason = feedback["blockReason"] as? String {
            throw AIError.refused(reason)
        }
        guard let candidates = obj["candidates"] as? [[String: Any]], let first = candidates.first else {
            throw AIError.badResponse("缺少 candidates")
        }
        let content = first["content"] as? [String: Any]
        let parts = content?["parts"] as? [[String: Any]] ?? []
        return parts.compactMap { $0["text"] as? String }.joined()
    }

    func analyze(_ request: AIRequest) -> AsyncThrowingStream<AIStreamEvent, Error> {
        AIHTTP.streamTask { emit in
            guard !config.apiKey.isEmpty else { throw AIError.missingAPIKey }
            guard !request.model.isEmpty else { throw AIError.missingModel }
            let parts: [[String: Any]] = [
                ["inline_data": ["mime_type": request.mimeType, "data": request.imageBase64]],
                ["text": request.prompt],
            ]
            let method = request.stream ? "streamGenerateContent" : "generateContent"
            let req = try AIHTTP.request(url: try url(model: request.model, method: method, stream: request.stream), headers: headers,
                                         body: body(parts: parts, maxTokens: request.maxTokens), timeout: request.timeout)
            if request.stream {
                try await AIHTTP.sse(req, mapError: { mapError($0, $1, model: request.model) }, onNonStream: { data in
                    guard let obj = JSON.parse(data) else { throw AIError.badResponse(String(data: data.prefix(300), encoding: .utf8) ?? "") }
                    emit(.text(try GeminiProvider.extractText(obj)))
                    if let c = (obj["candidates"] as? [[String: Any]])?.first, let fr = c["finishReason"] as? String {
                        emit(.finished(reason: fr == "MAX_TOKENS" ? "length" : fr.lowercased()))
                    }
                }) { ev in
                    guard let obj = JSON.parse(ev.data) else { return }
                    if let err = obj["error"] as? [String: Any] {
                        throw AIError.server(status: (err["code"] as? Int) ?? 200, message: (err["message"] as? String) ?? "stream error")
                    }
                    let text = (try? GeminiProvider.extractText(obj)) ?? ""
                    if !text.isEmpty { emit(.text(text)) }
                    if let c = (obj["candidates"] as? [[String: Any]])?.first, let fr = c["finishReason"] as? String {
                        emit(.finished(reason: fr == "MAX_TOKENS" ? "length" : fr.lowercased()))
                    }
                }
            } else {
                let obj = try await AIHTTP.json(req, mapError: { mapError($0, $1, model: request.model) })
                emit(.text(try GeminiProvider.extractText(obj)))
                if let c = (obj["candidates"] as? [[String: Any]])?.first, let fr = c["finishReason"] as? String {
                    emit(.finished(reason: fr == "MAX_TOKENS" ? "length" : fr.lowercased()))
                }
            }
        }
    }

    func testConnection(model: String, timeout: TimeInterval, thinking: ThinkingMode) async throws -> AITestResult {
        guard !config.apiKey.isEmpty else { throw AIError.missingAPIKey }
        guard !model.isEmpty else { throw AIError.missingModel }
        let req = try AIHTTP.request(url: try url(model: model, method: "generateContent", stream: false), headers: headers,
                                     body: body(parts: [["text": "请只回复 OK"]], maxTokens: 256), timeout: timeout)
        let obj = try await AIHTTP.json(req, mapError: { mapError($0, $1, model: model) })
        return AITestResult(text: try GeminiProvider.extractText(obj), reasoningChars: 0)
    }

    func listModels(timeout: TimeInterval) async throws -> [String] {
        guard !config.apiKey.isEmpty else { throw AIError.missingAPIKey }
        guard let u = URL(string: "\(base)/v1beta/models?pageSize=200") else { throw AIError.invalidEndpoint }
        let req = try AIHTTP.request(url: u, method: "GET", headers: headers, body: nil, timeout: timeout)
        let obj = try await AIHTTP.json(req, mapError: { mapError($0, $1, model: "") })
        let models = obj["models"] as? [[String: Any]] ?? []
        return models.compactMap { m -> String? in
            guard let name = m["name"] as? String else { return nil }
            let methods = m["supportedGenerationMethods"] as? [String] ?? []
            guard methods.isEmpty || methods.contains("generateContent") else { return nil }
            return name.hasPrefix("models/") ? String(name.dropFirst(7)) : name
        }.sorted()
    }
}

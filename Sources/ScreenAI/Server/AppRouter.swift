import Foundation

/// HTTP 路由：PWA 静态资源与 /api/*。运行在服务器线程。
final class AppRouter {
    static let version = "1.1.0"
    let pairing: PairingManager
    let history: HistoryStore
    let hub: WebSocketHub
    /// 在主线程同步调用，返回状态字典
    var statusProvider: () -> [String: Any] = { [:] }
    /// 证书管理（提供根证书下载与描述文件）
    var certificates: CertificateManager?

    init(pairing: PairingManager, history: HistoryStore, hub: WebSocketHub) {
        self.pairing = pairing
        self.history = history
        self.hub = hub
    }

    func handler() -> LocalServer.HTTPHandler {
        return { [weak self] request, ip, done in
            guard let self = self else { done(.notFound()); return }
            DispatchQueue.global(qos: .userInitiated).async {
                done(self.route(request, ip: ip))
            }
        }
    }

    func route(_ req: HTTPRequest, ip: String) -> HTTPResponse {
        if req.method == "OPTIONS" {
            return HTTPResponse(status: 204, headers: [("Access-Control-Allow-Methods", "GET, POST, OPTIONS"), ("Access-Control-Allow-Headers", "Authorization, Content-Type")])
        }
        switch (req.method, req.path) {
        case ("GET", "/"), ("GET", "/index.html"):
            return staticFile("index.html")
        case ("GET", "/app.js"), ("GET", "/style.css"), ("GET", "/manifest.json"):
            return staticFile(String(req.path.dropFirst()))
        case ("GET", "/sw.js"):
            guard let data = WebAssets.data("sw.js"), var text = String(data: data, encoding: .utf8) else { return .notFound() }
            text = text.replacingOccurrences(of: "__VERSION__", with: AppRouter.version + "-" + (certificates?.caFingerprint?.prefix(8).description ?? "0"))
            var r = HTTPResponse.file(Data(text.utf8), contentType: "application/javascript; charset=utf-8")
            r.headers.append(("Service-Worker-Allowed", "/"))
            return r
        case ("GET", "/screenai-ca.mobileconfig"), ("GET", "/ca.mobileconfig"):
            guard let data = certificates?.mobileConfig() else { return .notFound() }
            return .download(data, filename: "screenai-ca.mobileconfig", contentType: "application/x-apple-aspen-config")
        case ("GET", "/ca.crt"), ("GET", "/ca.der"):
            guard let data = certificates?.caCertificateDER else { return .notFound() }
            return .download(data, filename: "screenai-ca.crt", contentType: "application/x-x509-ca-cert")
        case ("GET", "/ca.pem"):
            guard let data = certificates?.caCertificatePEM else { return .notFound() }
            return .download(data, filename: "screenai-ca.pem", contentType: "application/x-pem-file")
        case ("GET", "/icon.png"):
            return .file(WebAssets.icon(size: 192), contentType: "image/png")
        case ("GET", "/icon-512.png"):
            return .file(WebAssets.icon(size: 512), contentType: "image/png")
        case ("GET", "/apple-touch-icon.png"), ("GET", "/apple-touch-icon-precomposed.png"), ("GET", "/apple-touch-icon-180x180.png"):
            return .file(WebAssets.icon(size: 180), contentType: "image/png")
        case ("GET", "/favicon.ico"):
            return .file(WebAssets.icon(size: 64), contentType: "image/png")
        case ("GET", "/api/status"):
            return status()
        case ("POST", "/api/auth"):
            return auth(req, ip: ip)
        case ("GET", "/api/history/dates"):
            guard authorized(req) else { return .unauthorized() }
            return .json(["dates": history.dates()])
        case ("GET", "/api/history"):
            guard authorized(req) else { return .unauthorized() }
            return historyRecords(req)
        case ("GET", "/api/history/export"):
            guard authorized(req) else { return .unauthorized() }
            return historyExport(req)
        default:
            return .notFound()
        }
    }

    // MARK: Handlers

    private func staticFile(_ name: String) -> HTTPResponse {
        guard let data = WebAssets.data(name) else { return .notFound() }
        let ext = (name as NSString).pathExtension
        return .file(data, contentType: HTTPResponse.contentType(forExtension: ext))
    }

    private func status() -> HTTPResponse {
        var s: [String: Any] = [
            "version": AppRouter.version,
            "cert_fingerprint": certificates?.caFingerprint ?? "",
            "connected_clients": hub.authenticatedCount,
            "paired": pairing.currentSession != nil,
            "code_active": pairing.code != nil,
        ]
        let extra = Thread.isMainThread ? statusProvider() : DispatchQueue.main.sync { statusProvider() }
        for (k, v) in extra { s[k] = v }
        return .json(s)
    }

    private func auth(_ req: HTTPRequest, ip: String) -> HTTPResponse {
        let code = (req.jsonBody?["code"] as? String) ?? (req.jsonBody?["code"] as? Int).map(String.init) ?? ""
        guard !code.isEmpty else { return .badRequest("missing code") }
        switch pairing.verify(code: code, from: ip) {
        case .success(let session):
            return .json(["success": true, "token": session.token, "expires_at": session.expiresAt.millis] as [String: Any])
        case .failure(let err):
            let status = err == .rateLimited ? 429 : 401
            return .json(["success": false, "error": err.message] as [String: Any], status: status)
        }
    }

    private func authorized(_ req: HTTPRequest) -> Bool {
        if let t = req.bearerToken, pairing.isValid(token: t) { return true }
        if let t = req.query["token"], pairing.isValid(token: t) { return true }
        return false
    }

    private func historyRecords(_ req: HTTPRequest) -> HTTPResponse {
        let limit = min(max(Int(req.query["limit"] ?? "") ?? 200, 1), 2000)
        let q = req.query["q"] ?? ""
        var records: [HistoryRecord]
        if let date = req.query["date"], !date.isEmpty {
            guard DayKey.isValid(date) else { return .badRequest("invalid date") }
            records = history.search(query: q, dates: [date], limit: limit)
        } else {
            records = history.search(query: q, dates: nil, limit: limit)
        }
        return .json(["records": records.map { $0.jsonObject }, "count": records.count] as [String: Any])
    }

    private func historyExport(_ req: HTTPRequest) -> HTTPResponse {
        let all = history.dates()
        var dates = all
        if let from = req.query["from"], DayKey.isValid(from) { dates = dates.filter { $0 >= from } }
        if let to = req.query["to"], DayKey.isValid(to) { dates = dates.filter { $0 <= to } }
        let csv = "\u{FEFF}" + history.exportCSV(dates: dates)
        let name = "screenai-history-\(dates.last ?? "")-\(dates.first ?? "").csv"
        return .download(Data(csv.utf8), filename: name, contentType: "text/csv; charset=utf-8")
    }
}

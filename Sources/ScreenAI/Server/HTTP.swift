import Foundation

struct HTTPRequest {
    var method: String
    var target: String
    var path: String
    var query: [String: String]
    var headers: [String: String]   // 键为小写
    var body: Data

    func header(_ name: String) -> String? { headers[name.lowercased()] }

    var wantsClose: Bool {
        (header("connection") ?? "").lowercased().contains("close")
    }

    var isWebSocketUpgrade: Bool {
        (header("upgrade") ?? "").lowercased() == "websocket" &&
            (header("connection") ?? "").lowercased().contains("upgrade")
    }

    var bearerToken: String? {
        guard let auth = header("authorization") else { return nil }
        let parts = auth.split(separator: " ", maxSplits: 1)
        guard parts.count == 2, parts[0].lowercased() == "bearer" else { return nil }
        return String(parts[1]).trimmingCharacters(in: .whitespaces)
    }

    var jsonBody: [String: Any]? { JSON.parse(body) }
}

enum HTTPParseError: Error { case malformed, tooLarge }

enum HTTPParser {
    static let maxHeaderBytes = 32 * 1024
    static let maxBodyBytes = 2 * 1024 * 1024

    /// 尝试从缓冲区解析一个完整请求；不完整返回 nil。
    static func parse(_ buffer: Data) throws -> (HTTPRequest, Int)? {
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            if buffer.count > maxHeaderBytes { throw HTTPParseError.tooLarge }
            return nil
        }
        let headerData = buffer.subdata(in: 0..<headerEnd.lowerBound)
        guard let headerText = String(data: headerData, encoding: .utf8) else { throw HTTPParseError.malformed }
        var lines = headerText.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { throw HTTPParseError.malformed }
        let requestLine = lines.removeFirst()
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2 else { throw HTTPParseError.malformed }
        let method = String(parts[0]).uppercased()
        let target = String(parts[1])
        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let idx = line.firstIndex(of: ":") else { continue }
            let name = line[..<idx].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: idx)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        guard contentLength <= maxBodyBytes else { throw HTTPParseError.tooLarge }
        let bodyStart = headerEnd.upperBound
        guard buffer.count - bodyStart >= contentLength else { return nil }
        let body = buffer.subdata(in: bodyStart..<(bodyStart + contentLength))

        var path = target
        var query: [String: String] = [:]
        if let q = target.firstIndex(of: "?") {
            path = String(target[..<q])
            let qs = target[target.index(after: q)...]
            for pair in qs.split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1)
                let k = String(kv[0]).removingPercentEncoding ?? String(kv[0])
                let v = kv.count > 1 ? (String(kv[1]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String(kv[1])) : ""
                query[k] = v
            }
        }
        path = path.removingPercentEncoding ?? path
        let req = HTTPRequest(method: method, target: target, path: path, query: query, headers: headers, body: body)
        return (req, bodyStart + contentLength)
    }
}

struct HTTPResponse {
    var status: Int
    var headers: [(String, String)]
    var body: Data

    static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 101: return "Switching Protocols"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 413: return "Payload Too Large"
        case 429: return "Too Many Requests"
        case 500: return "Internal Server Error"
        default: return "Status"
        }
    }

    init(status: Int, headers: [(String, String)] = [], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    static func text(_ s: String, status: Int = 200, contentType: String = "text/plain; charset=utf-8") -> HTTPResponse {
        HTTPResponse(status: status, headers: [("Content-Type", contentType)], body: Data(s.utf8))
    }

    static func json(_ obj: Any, status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status, headers: [("Content-Type", "application/json; charset=utf-8")], body: JSON.data(obj))
    }

    static func file(_ data: Data, contentType: String) -> HTTPResponse {
        HTTPResponse(status: 200, headers: [("Content-Type", contentType), ("Cache-Control", "no-cache")], body: data)
    }

    static func download(_ data: Data, filename: String, contentType: String) -> HTTPResponse {
        HTTPResponse(status: 200, headers: [("Content-Type", contentType), ("Content-Disposition", "attachment; filename=\"\(filename)\"")], body: data)
    }

    static func notFound() -> HTTPResponse { .text("Not Found", status: 404) }
    static func unauthorized() -> HTTPResponse { .json(["error": "unauthorized"], status: 401) }
    static func badRequest(_ m: String = "Bad Request") -> HTTPResponse { .json(["error": m], status: 400) }

    func serialized(close: Bool) -> Data {
        var head = "HTTP/1.1 \(status) \(HTTPResponse.reason(status))\r\n"
        var hasType = false
        for (k, v) in headers {
            if k.lowercased() == "content-type" { hasType = true }
            head += "\(k): \(v)\r\n"
        }
        if !hasType && !body.isEmpty { head += "Content-Type: application/octet-stream\r\n" }
        head += "Content-Length: \(body.count)\r\n"
        head += "Server: ScreenAI\r\n"
        head += "Access-Control-Allow-Origin: *\r\n"
        head += "Connection: \(close ? "close" : "keep-alive")\r\n\r\n"
        var data = Data(head.utf8)
        data.append(body)
        return data
    }

    static func contentType(forExtension ext: String) -> String {
        switch ext.lowercased() {
        case "html", "htm": return "text/html; charset=utf-8"
        case "js": return "application/javascript; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "json", "webmanifest": return "application/json; charset=utf-8"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "svg": return "image/svg+xml"
        case "ico": return "image/x-icon"
        case "csv": return "text/csv; charset=utf-8"
        case "txt": return "text/plain; charset=utf-8"
        default: return "application/octet-stream"
        }
    }
}

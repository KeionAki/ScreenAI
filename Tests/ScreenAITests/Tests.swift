import Foundation
import Security
import CoreGraphics

/// 让主队列上的 @Published 镜像更新得以执行
func pumpMainQueue() {
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
}

func testCSV() {
    T.run("CSV escape/parse roundtrip") {
        let fields = ["a", "b,c", "say \"hi\"", "line1\nline2", "", "end"]
        let line = CSV.line(fields)
        T.check(line.hasSuffix("\r\n"), "line ends with CRLF")
        let rows = CSV.parse(line)
        T.equal(rows.count, 1, "one row")
        T.equal(rows[0], fields, "fields roundtrip")
        let multi = CSV.line(["1", "x"]) + CSV.line(["2", "y\r\nz"]) + "3,w"
        let r2 = CSV.parse(multi)
        T.equal(r2.count, 3, "three rows incl. unterminated last")
        T.equal(r2[1][1], "y\r\nz", "embedded CRLF preserved")
        T.equal(r2[2], ["3", "w"], "last row")
    }
}

func testSSE() {
    T.run("SSE parser") {
        var p = SSEParser()
        T.check(p.feed(line: ": comment") == nil, "comment ignored")
        T.check(p.feed(line: "event: content_block_delta") == nil, "event line buffered")
        T.check(p.feed(line: "data: {\"a\":1}") == nil, "data line buffered")
        let ev = p.feed(line: "")
        T.equal(ev?.event, "content_block_delta", "event name")
        T.equal(ev?.data, "{\"a\":1}", "data")
        _ = p.feed(line: "data: one")
        _ = p.feed(line: "data: two")
        let ev2 = p.feed(line: "\r")
        T.equal(ev2?.data, "one\ntwo", "multi-line data joined")
        T.check(p.feed(line: "") == nil, "empty without data yields nothing")
        _ = p.feed(line: "data:[DONE]")
        T.equal(p.flush()?.data, "[DONE]", "flush returns trailing event")
    }
}

func testHTTP() {
    T.run("HTTP parser") {
        let partial = Data("GET /api/history?date=2026-09-05&q=%E4%BD%A0 HTTP/1.1\r\nHost: x\r\n".utf8)
        T.check((try? HTTPParser.parse(partial)) == nil || (try! HTTPParser.parse(partial)) == nil, "incomplete returns nil")
        let full = Data("GET /api/history?date=2026-09-05&q=%E4%BD%A0+%E5%A5%BD HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer abc\r\nConnection: close\r\n\r\nEXTRA".utf8)
        let (req, consumed) = try HTTPParser.parse(full)!
        T.equal(req.method, "GET", "method")
        T.equal(req.path, "/api/history", "path")
        T.equal(req.query["date"], "2026-09-05", "query date")
        T.equal(req.query["q"], "你 好", "query decoded with +")
        T.equal(req.bearerToken, "abc", "bearer")
        T.check(req.wantsClose, "connection close")
        T.equal(consumed, full.count - 5, "consumed excludes EXTRA")
        let post = Data("POST /api/auth HTTP/1.1\r\nContent-Type: application/json\r\nContent-Length: 17\r\n\r\n{\"code\":\"123456\"}".utf8)
        let (preq, _) = try HTTPParser.parse(post)!
        T.equal(preq.jsonBody?["code"] as? String, "123456", "json body")
        let ws = Data("GET /ws HTTP/1.1\r\nUpgrade: websocket\r\nConnection: keep-alive, Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n".utf8)
        let (wreq, _) = try HTTPParser.parse(ws)!
        T.check(wreq.isWebSocketUpgrade, "websocket upgrade detected")
        let resp = HTTPResponse.json(["ok": true]).serialized(close: false)
        let text = String(data: resp, encoding: .utf8)!
        T.check(text.hasPrefix("HTTP/1.1 200 OK\r\n"), "status line")
        T.check(text.contains("Content-Length: 11\r\n"), "content length")
        T.check(text.hasSuffix("\r\n\r\n{\"ok\":true}"), "body")
    }
}

func testWebSocket() {
    T.run("WebSocket codec") {
        T.equal(WebSocketCodec.acceptKey(for: "dGhlIHNhbXBsZSBub25jZQ=="), "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", "RFC 6455 accept key")
        // 构造客户端带掩码帧
        func masked(_ payload: [UInt8], opcode: UInt8 = 0x1) -> Data {
            var d = Data([0x80 | opcode])
            let n = payload.count
            if n < 126 { d.append(UInt8(0x80 | n)) }
            else if n <= 0xFFFF { d.append(0x80 | 126); d.append(UInt8(n >> 8)); d.append(UInt8(n & 0xFF)) }
            else { d.append(0x80 | 127); for i in (0..<8).reversed() { d.append(UInt8((UInt64(n) >> (UInt64(i) * 8)) & 0xFF)) } }
            let key: [UInt8] = [0x37, 0xfa, 0x21, 0x3d]
            d.append(contentsOf: key)
            d.append(contentsOf: payload.enumerated().map { $0.element ^ key[$0.offset & 3] })
            return d
        }
        let hello = masked(Array("Hello".utf8))
        T.equal(hello, Data([0x81, 0x85, 0x37, 0xfa, 0x21, 0x3d, 0x7f, 0x9f, 0x4d, 0x51, 0x58]), "RFC example frame bytes")
        let (frame, used) = try WebSocketCodec.decode(hello)!
        T.equal(String(data: frame.payload, encoding: .utf8), "Hello", "decoded payload")
        T.equal(used, hello.count, "consumed")
        T.check(try WebSocketCodec.decode(hello.prefix(7)) == nil, "partial frame nil")
        let big = masked([UInt8](repeating: 0xAB, count: 70000))
        let (bf, _) = try WebSocketCodec.decode(big)!
        T.equal(bf.payload.count, 70000, "64-bit length frame")
        let mid = masked([UInt8](repeating: 1, count: 300))
        T.equal(try WebSocketCodec.decode(mid)!.0.payload.count, 300, "16-bit length frame")
        let unmasked = Data([0x81, 0x05]) + Data("Hello".utf8)
        var threw = false
        do { _ = try WebSocketCodec.decode(unmasked) } catch { threw = true }
        T.check(threw, "unmasked client frame rejected")
        let out = WebSocketCodec.text("Hi")
        T.equal(out, Data([0x81, 0x02, 0x48, 0x69]), "server text frame")
        let close = WebSocketCodec.close(code: 1000, reason: "bye")
        T.equal(close[0], 0x88, "close opcode")
        T.equal(close[1], 5, "close length")
    }
}

func testNetwork() {
    T.run("private address detection") {
        for a in ["192.168.1.5", "10.0.0.1", "172.16.0.1", "172.31.255.255", "127.0.0.1", "::1", "fe80::1%en0", "::ffff:192.168.0.9", "fd12::1", "169.254.1.1"] {
            T.check(NetworkInfo.isPrivate(address: a), "private: \(a)")
        }
        for a in ["8.8.8.8", "172.32.0.1", "11.0.0.1", "2001:db8::1", "::ffff:8.8.8.8", "not-an-ip", "300.1.1.1"] {
            T.check(!NetworkInfo.isPrivate(address: a), "public: \(a)")
        }
    }
}

func testPairing() {
    T.run("pairing flow") {
        let pm = PairingManager()
        T.check(pm.verify(code: "123456", from: "192.168.1.2").isFailure(.noActiveCode), "no code yet")
        pm.generateCode()
        pumpMainQueue()
        let code = pm.code ?? ""
        T.equal(code.count, 6, "6-digit code")
        T.check(code.allSatisfy { $0.isNumber }, "numeric code")
        let wrong = code == "000000" ? "111111" : "000000"
        for _ in 0..<4 { T.check(pm.verify(code: wrong, from: "192.168.1.2").isFailure(.mismatch), "mismatch") }
        T.check(pm.verify(code: wrong, from: "192.168.1.2").isFailure(.tooManyAttempts), "5th wrong attempt invalidates")
        T.check(pm.verify(code: code, from: "192.168.1.2").isFailure(.noActiveCode), "code gone after too many attempts")
        pm.generateCode()
        pumpMainQueue()
        let code2 = pm.code ?? ""
        var token = ""
        switch pm.verify(code: code2, from: "192.168.1.3") {
        case .success(let s):
            token = s.token
            T.equal(s.clientAddress, "192.168.1.3", "client address")
            T.check(s.expiresAt.timeIntervalSinceNow > 86000, "24h token")
        case .failure(let e):
            T.check(false, "expected success, got \(e)")
        }
        T.equal(token.count, 64, "hex token")
        T.check(pm.isValid(token: token), "token valid")
        T.check(!pm.isValid(token: "nope"), "wrong token invalid")
        T.check(pm.verify(code: code2, from: "192.168.1.3").isFailure(.noActiveCode), "code single-use")
        pm.revokeSession()
        T.check(!pm.isValid(token: token), "revoked")
        // 限速：同一 IP 一分钟 10 次
        pm.generateCode()
        var limited = false
        for _ in 0..<12 { if pm.verify(code: "999999", from: "10.0.0.7").isFailure(.rateLimited) { limited = true } }
        T.check(limited, "ip rate limit kicks in")
    }
}

extension Result where Success == PairingSession, Failure == PairingError {
    func isFailure(_ e: PairingError) -> Bool {
        if case .failure(let f) = self { return f == e }
        return false
    }
}

func testMessagesAndHotkey() {
    T.run("server message json") {
        let m = ServerMessage.analysisResult(id: "abc", timestamp: Date(timeIntervalSince1970: 1.5), result: "答案：B", source: "全屏", model: "m", latencyMs: 1234)
        let obj = JSON.parse(m.json)!
        T.equal(obj["type"] as? String, "analysis_result", "type")
        T.equal(obj["timestamp"] as? Int, 1500, "millis")
        T.equal(obj["result"] as? String, "答案：B", "result")
        T.equal(obj["latency_ms"] as? Int, 1234, "latency")
        T.equal(obj["status"] as? String, "success", "status")
        let e = JSON.parse(ServerMessage.error(id: "1", timestamp: Date(), message: "x", source: nil).json)!
        T.check(e["capture_source"] == nil, "no source key when nil")
        T.equal(e["status"] as? String, "error", "error status")
    }
    T.run("hotkey display") {
        T.equal(Hotkey.default.displayString, "⇧⌘A", "default hotkey")
        let hk = Hotkey(keyCode: 0x7A, carbonModifiers: 4096 | 2048)
        T.equal(hk.displayString, "⌃⌥F1", "ctrl+opt+F1")
        let data = try JSONEncoder().encode(hk)
        T.equal(try JSONDecoder().decode(Hotkey.self, from: data), hk, "codable roundtrip")
        T.equal(Hotkey.defaultSingle.displayString, "F5", "single key display")
        T.check(Hotkey.defaultSingle.isSingleKey && !Hotkey.default.isSingleKey, "isSingleKey")
        T.check(Hotkey.defaultSingle.singleKeyWarning == nil, "F5 no warning")
        let letter = Hotkey(keyCode: 0, carbonModifiers: 0)
        T.check(letter.singleKeyWarning != nil, "single letter warns")
        T.check(Hotkey.forbiddenSingleKeys.contains(49), "space forbidden as single key")
    }
}

func testHistory() {
    T.run("history store") {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("screenai-test-\(UUID().uuidString)")
        let h = HistoryStore(directory: dir)
        let hash = h.registerPrompt("提示词A")
        T.equal(hash.count, 12, "prompt hash length")
        let t1 = Date(timeIntervalSince1970: 1_800_000_000)
        let r1 = HistoryRecord(id: "1", timestamp: t1, captureSource: "全屏", promptHash: hash, provider: "openai", model: "m", result: "答案,含\"引号\"\n第二行", status: "success", latencyMs: 12)
        let r2 = HistoryRecord(id: "2", timestamp: t1.addingTimeInterval(60), captureSource: "窗口", promptHash: hash, provider: "openai", model: "m", result: "", status: "error", errorMessage: "超时", latencyMs: 0)
        h.append(r1); h.append(r2)
        let dates = h.dates()
        T.equal(dates.count, 1, "one day file")
        let recs = h.records(date: dates[0])
        T.equal(recs.count, 2, "two records")
        T.equal(recs.first, r1, "record roundtrip with quotes/newline")
        T.equal(recs.last?.errorMessage, "超时", "error message")
        T.equal(h.search(query: "答案").count, 1, "search hit")
        T.equal(h.search(query: "窗口").first?.id, "2", "search by source")
        let csv = h.exportCSV(dates: dates)
        T.check(csv.hasPrefix("id,timestamp,capture_source"), "export header")
        T.equal(CSV.parse(csv).count, 3, "export rows")
        T.equal(h.prompt(forHash: hash), "提示词A", "prompt lookup")
        try h.clearAll()
        T.equal(h.dates().count, 0, "cleared")
        try? FileManager.default.removeItem(at: dir)
    }
}

func testImageEncoder() {
    T.run("image encoder") {
        let space = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: 4000, height: 2000, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        ctx.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 4000, height: 2000))
        let img = ctx.makeImage()!
        let enc = ImageEncoder.encode(img, maxLongEdge: 1600, quality: 0.85)!
        T.equal(enc.width, 1600, "scaled width")
        T.equal(enc.height, 800, "scaled height")
        T.check(enc.byteCount > 500 && enc.byteCount < 200_000, "jpeg size reasonable: \(enc.byteCount)")
        T.check(enc.base64.hasPrefix("/9j/"), "jpeg base64 magic")
        let same = ImageEncoder.downscale(img, maxLongEdge: 5000)
        T.equal(same.width, 4000, "no upscaling")
        T.check(!WebAssets.icon(size: 64).isEmpty, "icon png generated")
        T.check(WebAssets.data("index.html") != nil, "web assets found")
    }
}

func testRouter() {
    T.run("router") {
        let pairing = PairingManager()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("screenai-router-\(UUID().uuidString)")
        let history = HistoryStore(directory: dir)
        let hub = WebSocketHub()
        let router = AppRouter(pairing: pairing, history: history, hub: hub)
        func get(_ path: String, token: String? = nil) -> HTTPResponse {
            var headers: [String: String] = [:]
            if let t = token { headers["authorization"] = "Bearer \(t)" }
            var p = path; var q: [String: String] = [:]
            if let i = path.firstIndex(of: "?") { p = String(path[..<i]); for kv in path[path.index(after: i)...].split(separator: "&") { let a = kv.split(separator: "=", maxSplits: 1); q[String(a[0])] = a.count > 1 ? String(a[1]) : "" } }
            return router.route(HTTPRequest(method: "GET", target: path, path: p, query: q, headers: headers, body: Data()), ip: "192.168.1.9")
        }
        T.equal(get("/").status, 200, "index served")
        T.check(String(data: get("/").body, encoding: .utf8)!.contains("<title>ScreenAI</title>"), "index content")
        T.equal(get("/app.js").status, 200, "app.js served")
        T.equal(get("/manifest.json").status, 200, "manifest served")
        T.equal(get("/icon.png").status, 200, "icon served")
        T.equal(get("/nope").status, 404, "404")
        T.equal(get("/api/history/dates").status, 401, "auth required")
        T.equal(get("/api/history/dates", token: "bad").status, 401, "bad token")
        pairing.generateCode()
        pumpMainQueue()
        let body = Data("{\"code\":\"\(pairing.code!)\"}".utf8)
        let auth = router.route(HTTPRequest(method: "POST", target: "/api/auth", path: "/api/auth", query: [:], headers: ["content-type": "application/json"], body: body), ip: "192.168.1.9")
        T.equal(auth.status, 200, "auth ok")
        let tok = (JSON.parse(auth.body)?["token"] as? String) ?? ""
        T.equal(tok.count, 64, "token returned")
        T.equal(get("/api/history/dates", token: tok).status, 200, "authorized")
        T.equal(get("/api/history?limit=5", token: tok).status, 200, "history ok")
        T.equal(get("/api/history?date=bad", token: tok).status, 400, "bad date")
        T.equal(get("/api/history/export", token: tok).status, 200, "export ok")
        let status = JSON.parse(get("/api/status").body)!
        T.equal(status["paired"] as? Bool, true, "status paired")
        let badAuth = router.route(HTTPRequest(method: "POST", target: "/api/auth", path: "/api/auth", query: [:], headers: [:], body: Data("{\"code\":\"000000\"}".utf8)), ip: "192.168.1.9")
        T.equal(badAuth.status, 401, "wrong code 401")
        try? FileManager.default.removeItem(at: dir)
    }
}

func testCertificates() {
    T.run("certificate manager") {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("screenai-tls-\(UUID().uuidString)")
        let cm = CertificateManager(directory: dir)
        T.check(cm.needsRefresh(hostnames: ["localhost"], ips: ["127.0.0.1"]), "fresh manager needs certs")
        let hosts = ["localhost", "test-mac.local"]
        let ips = ["127.0.0.1", "192.168.1.2"]
        let identity = try cm.ensureIdentity(hostnames: hosts, ips: ips)
        T.check(cm.hasCA, "CA files exist")
        T.check(FileManager.default.fileExists(atPath: dir.appendingPathComponent("server.p12").path), "p12 exists")
        T.equal(cm.caFingerprint?.count, 95, "fingerprint format")
        let info = cm.serverInfo
        T.check(info?.sans.contains("IP:192.168.1.2") == true, "SAN has ip")
        T.check(info?.sans.contains("DNS:test-mac.local") == true, "SAN has host")
        T.check(!cm.needsRefresh(hostnames: hosts, ips: ips), "no refresh when SANs covered")
        T.check(cm.needsRefresh(hostnames: hosts, ips: ips + ["10.0.0.5"]), "refresh when new ip")
        // 身份中的证书应与 server.crt 一致
        var certRef: SecCertificate?
        SecIdentityCopyCertificate(identity, &certRef)
        T.check(certRef != nil, "identity has certificate")
        if let c = certRef {
            let summary = SecCertificateCopySubjectSummary(c) as String? ?? ""
            T.check(summary.contains("ScreenAI"), "certificate subject: \(summary)")
        }
        var keyRef: SecKey?
        T.equal(SecIdentityCopyPrivateKey(identity, &keyRef), errSecSuccess, "identity has private key")
        // openssl 验证链
        let verify = Process()
        verify.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        verify.arguments = ["verify", "-CAfile", dir.appendingPathComponent("ca.crt.pem").path, dir.appendingPathComponent("server.crt.pem").path]
        let pipe = Pipe(); verify.standardOutput = pipe; verify.standardError = pipe
        try verify.run(); let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""; verify.waitUntilExit()
        T.check(out.contains(": OK"), "chain verifies: \(out.trimmingCharacters(in: .whitespacesAndNewlines))")
        // SAN 文本
        let text = Process()
        text.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        text.arguments = ["x509", "-in", dir.appendingPathComponent("server.crt.pem").path, "-noout", "-text"]
        let p2 = Pipe(); text.standardOutput = p2
        try text.run(); let t = String(data: p2.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""; text.waitUntilExit()
        T.check(t.contains("IP Address:192.168.1.2"), "x509 SAN ip")
        T.check(t.contains("DNS:test-mac.local"), "x509 SAN dns")
        T.check(t.contains("TLS Web Server Authentication"), "EKU serverAuth")
        T.check(t.contains("CA:FALSE"), "server not CA")
        // mobileconfig
        let mc = cm.mobileConfig()!
        let plist = try PropertyListSerialization.propertyList(from: mc, options: [], format: nil) as! [String: Any]
        T.equal(plist["PayloadType"] as? String, "Configuration", "profile type")
        let inner = (plist["PayloadContent"] as! [[String: Any]])[0]
        T.equal(inner["PayloadType"] as? String, "com.apple.security.root", "root cert payload")
        T.equal(inner["PayloadContent"] as? Data, cm.caCertificateDER, "payload has DER")
        T.equal(cm.mobileConfig(), mc, "profile deterministic")
        // 重新签发后证书变化，根不变
        let fp1 = cm.caFingerprint
        let id2 = try cm.regenerateServer(hostnames: hosts, ips: ips + ["10.0.0.5"])
        var c2: SecCertificate?; SecIdentityCopyCertificate(id2, &c2)
        T.check(c2 != nil && certRef != nil && SecCertificateCopyData(c2!) as Data != SecCertificateCopyData(certRef!) as Data, "server cert reissued")
        T.equal(cm.caFingerprint, fp1, "CA unchanged after reissue")
        T.check(cm.serverInfo?.sans.contains("IP:10.0.0.5") == true, "new SAN present")
        try? FileManager.default.removeItem(at: dir)
    }
}

func testRouterCertRoutes() {
    T.run("router certificate routes") {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("screenai-tls2-\(UUID().uuidString)")
        let cm = CertificateManager(directory: dir)
        _ = try cm.ensureIdentity(hostnames: ["localhost"], ips: ["127.0.0.1"])
        let router = AppRouter(pairing: PairingManager(), history: HistoryStore(directory: dir.appendingPathComponent("h")), hub: WebSocketHub())
        func get(_ path: String) -> HTTPResponse {
            router.route(HTTPRequest(method: "GET", target: path, path: path, query: [:], headers: [:], body: Data()), ip: "192.168.1.9")
        }
        T.equal(get("/screenai-ca.mobileconfig").status, 404, "no certs → 404")
        router.certificates = cm
        let mc = get("/screenai-ca.mobileconfig")
        T.equal(mc.status, 200, "mobileconfig 200")
        T.check(mc.headers.contains { $0.0 == "Content-Type" && $0.1 == "application/x-apple-aspen-config" }, "mobileconfig content type")
        T.equal(get("/ca.crt").body, cm.caCertificateDER, "ca.crt is DER")
        let sw = get("/sw.js")
        T.equal(sw.status, 200, "sw.js 200")
        let swText = String(data: sw.body, encoding: .utf8) ?? ""
        T.check(!swText.contains("__VERSION__") && swText.contains(AppRouter.version), "sw version injected")
        T.check(sw.headers.contains { $0.0 == "Service-Worker-Allowed" }, "sw header")
        let status = JSON.parse(get("/api/status").body)!
        T.equal((status["cert_fingerprint"] as? String)?.count, 95, "status fingerprint")
        try? FileManager.default.removeItem(at: dir)
    }
}

func testOpenAIParsing() {
    T.run("openai stream/completion parsing") {
        let chunk = JSON.parse(#"{"choices":[{"delta":{"reasoning_content":"先看题","content":""},"finish_reason":null}]}"#)!
        let ev = try OpenAIProvider.events(fromChunk: chunk)
        T.equal(ev.count, 1, "reasoning only")
        if case .reasoning(let r) = ev[0] { T.equal(r, "先看题", "reasoning text") } else { T.check(false, "expected reasoning") }
        let chunk2 = JSON.parse(#"{"choices":[{"delta":{"content":"答案 B"},"finish_reason":"length"}]}"#)!
        let ev2 = try OpenAIProvider.events(fromChunk: chunk2)
        T.equal(ev2.count, 2, "text + finish")
        if case .text(let t) = ev2[0] { T.equal(t, "答案 B", "text delta") } else { T.check(false, "expected text") }
        if case .finished(let reason) = ev2[1] { T.equal(reason, "length", "finish reason") } else { T.check(false, "expected finished") }
        var threw = false
        do { _ = try OpenAIProvider.events(fromChunk: JSON.parse(#"{"error":{"message":"boom"}}"#)!) } catch { threw = true }
        T.check(threw, "error chunk throws")
        let completion = JSON.parse(#"{"choices":[{"message":{"role":"assistant","content":"","reasoning_content":"思考思考"},"finish_reason":"length"}]}"#)!
        let parsed = try OpenAIProvider.parseCompletion(completion)
        T.equal(parsed.text, "", "empty content")
        T.equal(parsed.reasoning, "思考思考", "reasoning content")
        T.equal(parsed.finishReason, "length", "completion finish reason")
        let msg = JSON.parse(ServerMessage.analysisThinking(id: "x", chars: 42).json)!
        T.equal(msg["type"] as? String, "analysis_thinking", "thinking message type")
        T.equal(msg["chars"] as? Int, 42, "thinking chars")
    }
}

func testSSELineSplitting() {
    T.run("sse byte line splitting keeps blank lines") {
        let raw = "data: {\"a\":1}\n\ndata: {\"b\":2}\r\n\r\nevent: x\ndata: y\n\ndata: [DONE]\n"
        let stream = AsyncStream<UInt8> { c in
            for b in raw.utf8 { c.yield(b) }
            c.finish()
        }
        let sem = DispatchSemaphore(value: 0)
        final class Box { var lines: [String] = []; var events: [SSEEvent] = [] }
        let box = Box()
        Task.detached {
            var parser = SSEParser()
            try? await AIHTTP.forEachLine(stream) { line in
                box.lines.append(line)
                if let ev = parser.feed(line: line) { box.events.append(ev) }
            }
            if let ev = parser.flush() { box.events.append(ev) }
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 5)
        let lines = box.lines, events = box.events
        T.equal(lines, ["data: {\"a\":1}", "", "data: {\"b\":2}", "", "event: x", "data: y", "", "data: [DONE]"], "lines incl. blanks, CRLF stripped")
        T.equal(events.count, 4, "four SSE events")
        T.equal(events.first?.data, "{\"a\":1}", "first event data")
        T.equal(events[2].event, "x", "event name")
        T.equal(events.last?.data, "[DONE]", "done event")
        // 模拟 DeepSeek 真实片段：思考 → 正文 → stop
        let chunks = [
            #"{"choices":[{"delta":{"content":null,"reasoning_content":"用户"},"finish_reason":null}]}"#,
            #"{"choices":[{"delta":{"content":"B","reasoning_content":null},"finish_reason":null}]}"#,
            #"{"choices":[{"delta":{"content":"","reasoning_content":null},"finish_reason":"stop"}]}"#,
        ]
        var text = "", reasoning = 0, finish: String? = nil
        for c in chunks {
            for e in try OpenAIProvider.events(fromChunk: JSON.parse(c)!) {
                switch e {
                case .text(let t): text += t
                case .reasoning(let r): reasoning += r.count
                case .finished(let f): finish = f
                }
            }
        }
        T.equal(text, "B", "deepseek content parsed")
        T.equal(reasoning, 2, "reasoning counted")
        T.equal(finish, "stop", "finish stop")
    }
}


func testVendorRequestBodies() {
    T.run("vendor request bodies") {
        var p = ProviderParams()
        p.maxTokens = 4096
        p.temperature = 0.7
        p.topP = 0.9
        p.thinking = "disabled"
        p.reasoningEffort = "max"
        p.imageDetail = "original"
        let content: [[String: Any]] = [["type": "text", "text": "hi"]]

        // Kimi：不发送采样参数，用 max_completion_tokens；k2.6 thinking.type
        let kimi = OpenAIProvider.requestBody(kind: .kimi, model: "kimi-k2.6", content: content, stream: true, params: p)
        T.check(kimi["temperature"] == nil && kimi["top_p"] == nil, "kimi never sends sampling params")
        T.equal(kimi["max_completion_tokens"] as? Int, 4096, "kimi max_completion_tokens")
        T.check(kimi["max_tokens"] == nil, "kimi no max_tokens")
        T.equal((kimi["thinking"] as? [String: Any])?["type"] as? String, "disabled", "kimi k2.6 thinking disabled")
        T.check(kimi["reasoning_effort"] == nil, "kimi k2.6 no reasoning_effort")
        // K3：reasoning_effort，不发 thinking
        let k3 = OpenAIProvider.requestBody(kind: .kimi, model: "kimi-k3", content: content, stream: false, params: p)
        T.equal(k3["reasoning_effort"] as? String, "max", "k3 effort")
        T.check(k3["thinking"] == nil, "k3 no thinking param")
        // K2.7-code：只有 keep 时发送固定值
        var pk = p; pk.thinkingKeep = true
        let k27 = OpenAIProvider.requestBody(kind: .kimi, model: "kimi-k2.7-code", content: content, stream: false, params: pk)
        T.equal((k27["thinking"] as? [String: Any])?["keep"] as? String, "all", "k2.7 keep all")
        T.equal((k27["thinking"] as? [String: Any])?["type"] as? String, "enabled", "k2.7 type enabled")
        // Kimi 图片不带 detail
        let kimiImg = OpenAIProvider.imagePart(kind: .kimi, mimeType: "image/jpeg", base64: "AAA", params: p)
        T.check(((kimiImg["image_url"] as? [String: Any])?["detail"]) == nil, "kimi image no detail")

        // DeepSeek：max_tokens、thinking.type、reasoning_effort、采样、detail original
        let ds = OpenAIProvider.requestBody(kind: .deepseek, model: "deepseek-flash", content: content, stream: true, params: p)
        T.equal(ds["max_tokens"] as? Int, 4096, "deepseek max_tokens")
        T.equal((ds["thinking"] as? [String: Any])?["type"] as? String, "disabled", "deepseek thinking")
        T.equal(ds["reasoning_effort"] as? String, "max", "deepseek effort")
        T.equal(ds["temperature"] as? Double, 0.7, "deepseek temperature sent")
        T.equal(ds["top_p"] as? Double, 0.9, "deepseek top_p sent")
        let dsImg = OpenAIProvider.imagePart(kind: .deepseek, mimeType: "image/jpeg", base64: "AAA", params: p)
        T.equal((dsImg["image_url"] as? [String: Any])?["detail"] as? String, "original", "deepseek detail original")
        var pn = ProviderParams(); pn.reasoningEffort = "none"
        T.equal(OpenAIProvider.requestBody(kind: .deepseek, model: "deepseek-flash", content: content, stream: false, params: pn)["reasoning_effort"] as? String, "none", "deepseek effort none")

        // OpenAI：max_completion_tokens，effort 映射，detail original→high，无 thinking
        let oa = OpenAIProvider.requestBody(kind: .openai, model: "gpt-5", content: content, stream: false, params: p)
        T.equal(oa["max_completion_tokens"] as? Int, 4096, "openai max_completion_tokens")
        T.equal(oa["reasoning_effort"] as? String, "minimal", "openai thinking disabled → minimal")
        T.check(oa["thinking"] == nil, "openai no thinking object")
        let oaImg = OpenAIProvider.imagePart(kind: .openai, mimeType: "image/jpeg", base64: "AAA", params: p)
        T.equal((oaImg["image_url"] as? [String: Any])?["detail"] as? String, "high", "openai original→high")

        // 默认参数：什么都不额外发送
        let d = ProviderParams.defaults(for: .deepseek)
        let dsDefault = OpenAIProvider.requestBody(kind: .deepseek, model: "deepseek-flash", content: content, stream: true, params: d)
        T.check(dsDefault["thinking"] == nil && dsDefault["reasoning_effort"] == nil && dsDefault["temperature"] == nil, "deepseek defaults send nothing extra")
        T.equal(ProviderParams.defaults(for: .kimi).maxTokens, 16000, "kimi default max tokens")

        // 自定义：字段名、额外 JSON 合并
        var pc = ProviderParams(); pc.maxTokensField = "max_completion_tokens"; pc.extraJSON = "{\"stop\": [\"###\"], \"foo\": 1}"; pc.thinking = "enabled"; pc.reasoningEffort = "low"
        T.check(pc.extraJSONIsValid, "extra json valid")
        let cu = OpenAIProvider.requestBody(kind: .custom, model: "m", content: content, stream: false, params: pc)
        T.equal(cu["max_completion_tokens"] as? Int, 8192, "custom field name")
        T.equal(cu["foo"] as? Int, 1, "extra json merged")
        T.equal((cu["stop"] as? [String])?.first, "###", "extra stop merged")
        T.equal(cu["reasoning_effort"] as? String, "low", "custom effort raw")
        pc.extraJSON = "[1,2]"; T.check(!pc.extraJSONIsValid, "array is not a valid extra object")
        pc.extraJSON = "not json"; T.check(!pc.extraJSONIsValid, "garbage invalid")

        // Anthropic / Gemini
        var pa = ProviderParams(); pa.thinking = "adaptive"; pa.reasoningEffort = "medium"
        let an = AnthropicProvider.requestBody(model: "claude-opus-5", content: content, stream: false, params: pa)
        T.equal((an["thinking"] as? [String: Any])?["type"] as? String, "adaptive", "anthropic adaptive")
        T.equal((an["output_config"] as? [String: Any])?["effort"] as? String, "medium", "anthropic effort")
        T.check(an["temperature"] == nil, "anthropic no temperature by default")
        var pg = ProviderParams(); pg.reasoningEffort = "high"; pg.temperature = 0.5
        let g3 = GeminiProvider.requestBody(model: "gemini-3-pro-preview", parts: [["text": "hi"]], params: pg)
        let gen3 = g3["generationConfig"] as? [String: Any]
        T.equal((gen3?["thinkingConfig"] as? [String: Any])?["thinkingLevel"] as? String, "high", "gemini 3 thinkingLevel")
        T.equal(gen3?["temperature"] as? Double, 0.5, "gemini temperature")
        let g25 = GeminiProvider.requestBody(model: "gemini-2.5-flash", parts: [["text": "hi"]], params: pg)
        T.equal(((g25["generationConfig"] as? [String: Any])?["thinkingConfig"] as? [String: Any])?["thinkingBudget"] as? Int, 24576, "gemini 2.5 budget")
        pg.thinking = "disabled"
        let g25off = GeminiProvider.requestBody(model: "gemini-2.5-flash", parts: [["text": "hi"]], params: pg)
        T.equal(((g25off["generationConfig"] as? [String: Any])?["thinkingConfig"] as? [String: Any])?["thinkingBudget"] as? Int, 0, "gemini disabled → budget 0")

        // ProviderParams 兼容解码（缺字段）
        let decoded = try JSONDecoder().decode(ProviderParams.self, from: Data("{\"maxTokens\": 123}".utf8))
        T.equal(decoded.maxTokens, 123, "partial decode maxTokens")
        T.equal(decoded.thinking, "default", "partial decode default thinking")
        T.check(decoded.temperature == nil, "partial decode nil temperature")
    }
}


func testChangeDetector() {
    T.run("change detector") {
        func solid(_ v: CGFloat) -> CGImage {
            let ctx = CGContext(data: nil, width: 200, height: 100, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
            ctx.setFillColor(CGColor(red: v, green: v, blue: v, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
            return ctx.makeImage()!
        }
        let a = ChangeDetector.signature(solid(0.5))
        let b = ChangeDetector.signature(solid(0.5))
        let c = ChangeDetector.signature(solid(0.9))
        T.equal(a.count, 32 * 32, "signature size")
        T.check(ChangeDetector.difference(a, b) < 0.001, "identical images ~0 diff")
        T.check(ChangeDetector.difference(a, c) > 0.2, "different images large diff")
        T.check(ChangeDetector.isUnchanged(a, b), "unchanged detected")
        T.check(!ChangeDetector.isUnchanged(a, c), "changed detected")
        T.check(!ChangeDetector.isUnchanged(nil, b), "no previous → treated as changed")
    }
}

func testCodeExtractor() {
    T.run("code extractor") {
        let plain = "2. B\n5. AC\n7. 光合作用"
        T.check(!CodeExtractor.containsCodeBlock(plain), "plain answer has no fence")
        T.check(CodeExtractor.extract(plain) == nil, "no code block in plain answer")

        let fenced = "```python\ndef f(x):\n    return x + 1\n```"
        T.check(CodeExtractor.containsCodeBlock(fenced), "fence detected")
        T.equal(CodeExtractor.extract(fenced), "def f(x):\n    return x + 1", "code extracted without fence or language")

        let noLang = "```\nprint(1)\n```"
        T.equal(CodeExtractor.extract(noLang), "print(1)", "fence without language")

        let withText = "这是答案：\n```cpp\nint main(){return 0;}\n```\n以上。"
        T.equal(CodeExtractor.extract(withText), "int main(){return 0;}", "code extracted from surrounding text")

        let unterminated = "```python\nx = 1\ny = 2"
        T.equal(CodeExtractor.extract(unterminated), "x = 1\ny = 2", "streaming unterminated block")

        T.equal(CodeExtractor.codeToType(plain), plain, "codeToType falls back to raw text")
        T.equal(CodeExtractor.codeToType(fenced), "def f(x):\n    return x + 1", "codeToType prefers code block")
        T.check(CodeExtractor.codeToType("   \n  ") == nil, "blank text yields nil")

        let tabs = "if x:\n\treturn 1\r\nelse:\r\n\treturn 2"
        let norm = CodeExtractor.normalize(tabs, tabWidth: 4)
        T.check(!norm.contains("\t"), "tabs expanded")
        T.check(!norm.contains("\r"), "CRLF normalized")
        T.equal(norm, "if x:\n    return 1\nelse:\n    return 2", "normalized code")
    }
}

func testHotkeyActions() {
    T.run("hotkey actions and defaults") {
        T.equal(HotkeyAction.capture.rawValue, 1, "capture id")
        T.equal(HotkeyAction.startTyping.rawValue, 2, "start typing id")
        T.equal(HotkeyAction.stopTyping.rawValue, 3, "stop id")
        T.equal(HotkeyAction.allCases.count, 3, "three actions")
        T.equal(Hotkey.defaultType.displayString, "⇧⌘D", "type hotkey default")
        T.equal(Hotkey.defaultStop.displayString, "⇧⌘.", "stop hotkey default")
        T.equal(Hotkey.defaultTypeSingle.displayString, "F6", "type single default")
        T.equal(Hotkey.defaultStopSingle.displayString, "F8", "stop single default")
        // 三个默认快捷键互不相同
        let all = [Hotkey.default, .defaultType, .defaultStop]
        T.equal(Set(all.map { $0.displayString }).count, 3, "combo defaults distinct")
        let singles = [Hotkey.defaultSingle, .defaultTypeSingle, .defaultStopSingle]
        T.equal(Set(singles.map { $0.displayString }).count, 3, "single defaults distinct")
    }
}

func testPromptTemplate() {
    T.run("default prompt covers scenes") {
        let p = SettingsStore.defaultPrompt
        for keyword in ["题号. 答案", "跳过", "```", "编程题", "未检测到完整题目"] {
            T.check(p.contains(keyword), "prompt mentions \(keyword)")
        }
        T.check(p != SettingsStore.legacyPrompt, "new prompt differs from legacy")
    }
}

func testCaptionByQuestionType() {
    T.run("caption distinguishes question types") {
        // 选择题/填空题：字幕原样显示「题号. 答案」
        let choice = CaptionModel()
        let cid = "choice-1"
        choice.apply(.started(id: cid, source: "全屏"), maxCount: 5)
        T.check(!choice.entries[0].isCode, "choice: not code at start")
        for delta in ["2. B", "\n5. AC", "\n7. 光合作用"] {
            choice.apply(.partial(id: cid, delta: delta), maxCount: 5)
        }
        T.check(!choice.entries[0].isCode, "choice: still not code while streaming")
        choice.apply(.completed(id: cid, text: "2. B\n5. AC\n7. 光合作用", source: "全屏", model: "m", latencyMs: 100), maxCount: 5)
        T.check(!choice.entries[0].isCode, "choice: not code when finished")
        T.equal(choice.entries[0].text, "2. B\n5. AC\n7. 光合作用", "choice: caption shows answers verbatim")
        T.equal(choice.entries[0].kind, CaptionEntry.Kind.success, "choice: success")

        // 编程题：出现代码围栏后字幕不再显示正文，完成后显示「已完成」
        let code = CaptionModel()
        let kid = "code-1"
        code.apply(.started(id: kid, source: "全屏"), maxCount: 5)
        T.check(!code.entries[0].isCode, "coding: unknown before any output")
        code.apply(.partial(id: kid, delta: "```python\n"), maxCount: 5)
        T.check(code.entries[0].isCode, "coding: fence switches caption to code mode")
        code.apply(.partial(id: kid, delta: "import sys\n"), maxCount: 5)
        T.check(code.entries[0].isCode, "coding: stays in code mode")
        code.apply(.completed(id: kid, text: "```python\nimport sys\nprint(1)\n```", source: "全屏", model: "m", latencyMs: 100), maxCount: 5)
        T.check(code.entries[0].isCode, "coding: code mode at completion")
        T.equal(code.entries[0].kind, CaptionEntry.Kind.success, "coding: success")
        T.equal(code.entries[0].note, "", "coding: no note → caption renders 已完成")
        T.equal(CodeExtractor.extract(code.entries[0].text), "import sys\nprint(1)", "coding: extractable code")

        // 手动开始键入后，进度写入 note；结束后清空回到「已完成」
        code.setNote("键入中 40%", for: kid)
        T.equal(code.entries[0].note, "键入中 40%", "typing progress note set")
        code.setNote("", for: kid)
        T.equal(code.entries[0].note, "", "note cleared → 已完成")

        // 错误仍照常显示
        let err = CaptionModel()
        err.apply(.started(id: "e", source: "全屏"), maxCount: 5)
        err.apply(.failed(id: "e", message: "API Key 无效", source: "全屏"), maxCount: 5)
        T.equal(err.entries[0].kind, CaptionEntry.Kind.error, "error kind kept")
        T.equal(err.entries[0].text, "API Key 无效", "error text shown even in code mode")
    }
}

/// 简化的编辑器模型：验证键入步骤在各种编辑器行为下能否还原原文。
/// suggestOnEnter 模拟 VSCode / Monaco 的「按回车接受补全」：补全浮层打开时回车不会换行。
struct EditorSimulator {
    var lines: [String] = [""]
    var line = 0
    var col = 0
    var anchor: (line: Int, col: Int)?
    var autoIndent: Bool
    var smartHome: Bool
    var suggestOnEnter: Bool = false
    var suggestionOpen = false
    var deletedEmptySelection = false
    var swallowedNewlines = 0

    var text: String { lines.joined(separator: "\n") }

    private mutating func dropSelection() {
        guard let a = anchor else { return }
        let lo = min(a.col, col), hi = max(a.col, col)
        var l = lines[line]
        let start = l.index(l.startIndex, offsetBy: lo)
        let end = l.index(l.startIndex, offsetBy: hi)
        l.removeSubrange(start..<end)
        lines[line] = l
        col = lo
        anchor = nil
    }

    mutating func apply(_ step: TypingStep) {
        switch step {
        case .char(let c):
            dropSelection()
            var l = lines[line]
            l.insert(c, at: l.index(l.startIndex, offsetBy: col))
            lines[line] = l
            col += 1
            // 输入标识符字符时弹出补全浮层
            if suggestOnEnter, c.isLetter || c == "_" { suggestionOpen = true }
            else if !(c.isLetter || c.isNumber || c == "_") { suggestionOpen = false }
        case .marker:
            apply(.char(TextTyper.markerCharacter))
        case .escape:
            suggestionOpen = false
        case .cursorNudge:
            // 左移再右移：净位移为零
            if col > 0 { col -= 1 }
            else if line > 0 { line -= 1; col = lines[line].count }
            if col < lines[line].count { col += 1 }
            else if line < lines.count - 1 { line += 1; col = 0 }
            suggestionOpen = false
            anchor = nil
        case .newline:
            if suggestOnEnter && suggestionOpen {
                // 回车被补全浮层吃掉：只关闭浮层，不换行
                suggestionOpen = false
                swallowedNewlines += 1
                return
            }
            dropSelection()
            let l = lines[line]
            let cut = l.index(l.startIndex, offsetBy: col)
            let head = String(l[l.startIndex..<cut])
            let tail = String(l[cut...])
            var indent = ""
            if autoIndent {
                indent = String(head.prefix(while: { $0 == " " }))
                let trimmed = head.trimmingCharacters(in: .whitespaces)
                if trimmed.hasSuffix(":") || trimmed.hasSuffix("{") { indent += "    " }
            }
            lines[line] = head
            lines.insert(indent + tail, at: line + 1)
            line += 1
            col = indent.count
            anchor = nil
        case .selectToLineStart:
            _ = smartHome
            anchor = (line, col)
            col = 0
        case .deleteSelection:
            if anchor == nil || anchor!.col == col { deletedEmptySelection = true }
            dropSelection()
        }
    }

    static func run(_ steps: [TypingStep], autoIndent: Bool, smartHome: Bool, suggestOnEnter: Bool = false) -> EditorSimulator {
        var sim = EditorSimulator(autoIndent: autoIndent, smartHome: smartHome, suggestOnEnter: suggestOnEnter)
        for s in steps { sim.apply(s) }
        return sim
    }
}

let sampleCode = """
import sys

def main():
    records = {}
    order = []
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        name = line.split(' ')[0]
        records[name] = records.get(name, 0) + 1

    for k, v in list(records.items())[-8:]:
        print(k, v)

main()
"""

func testTypingPlanRoundTrip() {
    T.run("typing plan reproduces code in simulated editors") {
        let code = sampleCode
        let planOn = TextTyper.plan(code: code, clearAutoIndent: true)
        let a = EditorSimulator.run(planOn, autoIndent: true, smartHome: true)
        T.equal(a.text, code, "VSCode 风格编辑器：清缩进后完全还原")
        T.check(!a.deletedEmptySelection, "没有出现空选区退格")

        let b = EditorSimulator.run(planOn, autoIndent: false, smartHome: false)
        T.equal(b.text, code, "普通文本编辑器：同一计划同样还原")

        let planOff = TextTyper.plan(code: code, clearAutoIndent: false)
        T.equal(EditorSimulator.run(planOff, autoIndent: false, smartHome: false).text, code, "不清缩进 + 无自动缩进：还原")
        T.check(EditorSimulator.run(planOff, autoIndent: true, smartHome: true).text != code, "不清缩进 + 自动缩进：确实会错")

        let tricky = "a = 1\n\n\n    b = 2\n\nif x:\n    pass\n"
        let p2 = TextTyper.plan(code: tricky, clearAutoIndent: true)
        let r2 = EditorSimulator.run(p2, autoIndent: true, smartHome: true)
        T.equal(r2.text, tricky, "空行与缩进混排也能还原")
        T.check(!r2.deletedEmptySelection, "空行不会误删换行")

        T.equal(TextTyper.visibleCount(TextTyper.plan(code: "ab\ncd", clearAutoIndent: true)), 5, "visible count = 字符数 + 换行数")
    }
}

func testSuggestionSwallowsEnter() {
    T.run("回车被补全吃掉会整行消失，Esc 可修复") {
        let code = sampleCode
        let lineCount = code.components(separatedBy: "\n").count

        // 复现：不按 Esc，补全浮层把回车吃掉
        let broken = TextTyper.plan(code: code, clearAutoIndent: true, dismiss: .none)
        let bad = EditorSimulator.run(broken, autoIndent: true, smartHome: true, suggestOnEnter: true)
        T.check(bad.swallowedNewlines > 0, "确实有回车被补全吃掉：\(bad.swallowedNewlines) 次")
        T.check(bad.text != code, "结果与原文不一致（复现用户报告的问题）")
        T.check(bad.text.components(separatedBy: "\n").count < lineCount, "整行丢失：\(bad.text.components(separatedBy: "\n").count) 行 < 原 \(lineCount) 行")
        // 丢失的正是「刚打完的那一整行」：import sys 被下一行内容替换
        T.check(!bad.text.hasPrefix("import sys\n"), "首行 import sys 被后续内容顶替")

        // 修复：换行前按 Esc 关闭浮层
        let fixed = TextTyper.plan(code: code, clearAutoIndent: true, dismiss: .cursorNudge)
        let good = EditorSimulator.run(fixed, autoIndent: true, smartHome: true, suggestOnEnter: true)
        T.equal(good.swallowedNewlines, 0, "没有回车被吃掉")
        T.equal(good.text, code, "移动光标关闭浮层后完全还原")

        // Esc 方式同样能修复，但会退出浏览器全屏，故不作默认
        let esc = TextTyper.plan(code: code, clearAutoIndent: true, dismiss: .escape)
        let escRun = EditorSimulator.run(esc, autoIndent: true, smartHome: true, suggestOnEnter: true)
        T.equal(escRun.text, code, "Esc 方式也能还原")
        T.check(esc.contains(.escape) && !esc.contains(.cursorNudge), "Esc 模式只用 Esc")
        T.check(!TextTyper.plan(code: code, clearAutoIndent: true, dismiss: .cursorNudge).contains(.escape),
                "默认模式完全不发送 Esc，不会退出浏览器全屏")

        // 计划开头不得有关闭浮层的动作：此时光标可能在文稿最开头，右移会让插入点偏移
        let first = TextTyper.plan(code: code, clearAutoIndent: true, dismiss: .cursorNudge).first
        if case .char = first { } else { T.check(false, "计划应以字符开始，实际是 \(String(describing: first))") }

        // 同时在不弹补全的编辑器里也不受影响
        T.equal(EditorSimulator.run(fixed, autoIndent: true, smartHome: true).text, code, "无补全编辑器同样还原")
        T.equal(EditorSimulator.run(fixed, autoIndent: false, smartHome: false).text, code, "无自动缩进编辑器同样还原")

        // 最安全配置：关闭自动缩进 + 不清缩进 → 键入不含任何删除动作
        let additive = TextTyper.plan(code: code, clearAutoIndent: false, dismiss: .cursorNudge)
        T.check(!additive.contains(.deleteSelection) && !additive.contains(.selectToLineStart) && !additive.contains(.marker),
                "不清缩进时计划里没有任何删除或选择动作")
        T.equal(EditorSimulator.run(additive, autoIndent: false, smartHome: false, suggestOnEnter: true).text, code, "纯追加模式还原")
    }
}

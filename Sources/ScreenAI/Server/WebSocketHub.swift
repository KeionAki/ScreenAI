import Foundation

/// 单个 WebSocket 客户端
final class WSClient {
    let id = UUID()
    let remoteAddress: String
    let connectedAt = Date()
    private(set) var authenticated = false
    var lastPong = Date()
    var sendData: ((Data) -> Void)?
    var closeConnection: (() -> Void)?

    init(remoteAddress: String) { self.remoteAddress = remoteAddress }

    func markAuthenticated() { authenticated = true; lastPong = Date() }

    func send(text: String) { sendData?(WebSocketCodec.text(text)) }

    func close(code: UInt16 = 1000, reason: String = "") {
        sendData?(WebSocketCodec.close(code: code, reason: reason))
        closeConnection?()
    }
}

/// 管理所有 WebSocket 客户端：鉴权、心跳、广播。
final class WebSocketHub {
    static let heartbeatInterval: TimeInterval = 15
    static let heartbeatTimeout: TimeInterval = 45
    static let authTimeout: TimeInterval = 3

    private let queue = DispatchQueue(label: "com.li.screenai.wshub")
    private var clients: [UUID: WSClient] = [:]
    private var timer: DispatchSourceTimer?

    /// token → 是否有效
    var authenticate: ((String) -> Bool)?
    /// 认证客户端数量变化（在主线程回调）
    var onAuthenticatedCountChanged: ((Int) -> Void)?
    var onClientAuthenticated: ((WSClient) -> Void)?
    var authOKPayload: (() -> ServerMessage)?

    init() {}

    func start() {
        queue.async {
            self.timer?.cancel()
            let t = DispatchSource.makeTimerSource(queue: self.queue)
            t.schedule(deadline: .now() + WebSocketHub.heartbeatInterval, repeating: WebSocketHub.heartbeatInterval)
            t.setEventHandler { [weak self] in self?.tick() }
            t.resume()
            self.timer = t
        }
    }

    func stop() {
        queue.sync {
            timer?.cancel(); timer = nil
            for c in clients.values { c.close(code: 1001, reason: "server shutdown") }
            clients.removeAll()
        }
        notifyCount()
    }

    func add(_ client: WSClient) {
        queue.async {
            self.clients[client.id] = client
            self.queue.asyncAfter(deadline: .now() + WebSocketHub.authTimeout) { [weak self, weak client] in
                guard let self = self, let client = client, self.clients[client.id] != nil, !client.authenticated else { return }
                Log.server.info("WS 客户端未在限时内认证，断开: \(client.remoteAddress, privacy: .public)")
                client.send(text: ServerMessage.authFailed(reason: "auth timeout").json)
                client.close(code: 4001, reason: "auth timeout")
                self.clients[client.id] = nil
            }
        }
    }

    func remove(_ client: WSClient) {
        queue.async {
            let wasAuth = client.authenticated
            self.clients[client.id] = nil
            if wasAuth { self.notifyCount() }
        }
    }

    func handleText(_ client: WSClient, _ text: String) {
        queue.async {
            guard let obj = JSON.parse(text), let type = obj["type"] as? String else { return }
            switch type {
            case "auth":
                let token = (obj["token"] as? String) ?? ""
                if self.authenticate?(token) == true {
                    client.markAuthenticated()
                    client.send(text: (self.authOKPayload?() ?? ServerMessage.authOK(expiresAt: Date().addingTimeInterval(PairingManager.tokenLifetime))).json)
                    Log.server.info("WS 客户端认证成功: \(client.remoteAddress, privacy: .public)")
                    self.notifyCount()
                    DispatchQueue.main.async { self.onClientAuthenticated?(client) }
                } else {
                    client.send(text: ServerMessage.authFailed(reason: "invalid token").json)
                    client.close(code: 4003, reason: "invalid token")
                    self.clients[client.id] = nil
                }
            case "pong", "ping":
                client.lastPong = Date()
                if type == "ping" { client.send(text: "{\"type\":\"pong\"}") }
            default:
                break
            }
        }
    }

    func handlePongFrame(_ client: WSClient) {
        queue.async { client.lastPong = Date() }
    }

    func broadcast(_ message: ServerMessage) {
        let text = message.json
        queue.async {
            for c in self.clients.values where c.authenticated { c.send(text: text) }
        }
    }

    func disconnectAll(reason: String) {
        queue.async {
            for c in self.clients.values { c.close(code: 4000, reason: reason) }
            self.clients.removeAll()
            self.notifyCount()
        }
    }

    var authenticatedCount: Int {
        queue.sync { clients.values.filter { $0.authenticated }.count }
    }

    var authenticatedAddresses: [String] {
        queue.sync { clients.values.filter { $0.authenticated }.map { $0.remoteAddress } }
    }

    private func tick() {
        let now = Date()
        var changed = false
        for c in clients.values {
            if c.authenticated && now.timeIntervalSince(c.lastPong) > WebSocketHub.heartbeatTimeout {
                Log.server.info("WS 心跳超时，断开: \(c.remoteAddress, privacy: .public)")
                c.close(code: 4002, reason: "heartbeat timeout")
                clients[c.id] = nil
                changed = true
            } else if c.authenticated {
                c.send(text: ServerMessage.heartbeat.json)
            }
        }
        if changed { notifyCount() }
    }

    private func notifyCount() {
        let n = clients.values.filter { $0.authenticated }.count
        DispatchQueue.main.async { self.onAuthenticatedCountChanged?(n) }
    }
}

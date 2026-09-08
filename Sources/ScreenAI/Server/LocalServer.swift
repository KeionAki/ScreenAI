import Foundation
import Network
import Security

/// 基于 Network.framework 的轻量 HTTP + WebSocket 服务器（同一端口）。
final class LocalServer {
    typealias HTTPHandler = (HTTPRequest, String, @escaping (HTTPResponse) -> Void) -> Void

    let hub: WebSocketHub
    var port: UInt16
    /// 设置后以 HTTPS 监听；为 nil 时为明文 HTTP
    var identity: SecIdentity?
    var isTLS: Bool { identity != nil }
    private let queue = DispatchQueue(label: "com.li.screenai.server", attributes: .concurrent)
    private var listener: NWListener?
    private var connections: [UUID: ClientConnection] = [:]
    private let lock = NSLock()

    var httpHandler: HTTPHandler = { _, _, done in done(.notFound()) }
    var onStateChange: ((String) -> Void)?       // 主线程：状态描述
    var onFailure: ((String) -> Void)?           // 主线程：错误描述
    private(set) var isRunning = false

    init(port: UInt16, hub: WebSocketHub) {
        self.port = port
        self.hub = hub
    }

    func start() throws {
        stop()
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { throw NSError(domain: "ScreenAI", code: 1, userInfo: [NSLocalizedDescriptionKey: "端口无效"]) }
        let params: NWParameters
        if let identity = identity, let secIdentity = sec_identity_create(identity) {
            let tls = NWProtocolTLS.Options()
            sec_protocol_options_set_local_identity(tls.securityProtocolOptions, secIdentity)
            sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
            params = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        } else {
            params = NWParameters.tcp
        }
        params.allowLocalEndpointReuse = true
        let l = try NWListener(using: params, on: nwPort)
        l.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                self.isRunning = true
                Log.server.info("服务器已启动，端口 \(self.port)（\(self.isTLS ? "HTTPS" : "HTTP", privacy: .public)）")
                DispatchQueue.main.async { self.onStateChange?("running") }
            case .failed(let error):
                self.isRunning = false
                let msg: String
                if case .posix(let code) = error, code == .EADDRINUSE {
                    msg = "端口 \(self.port) 已被占用，请在设置中更换端口"
                } else {
                    msg = "服务器启动失败：\(error.localizedDescription)"
                }
                Log.server.error("\(msg, privacy: .public)")
                DispatchQueue.main.async { self.onFailure?(msg) }
            case .cancelled:
                self.isRunning = false
                DispatchQueue.main.async { self.onStateChange?("stopped") }
            default:
                break
            }
        }
        l.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        listener = l
        l.start(queue: queue)
        hub.start()
    }

    func stop() {
        listener?.cancel()
        listener = nil
        lock.lock(); let all = Array(connections.values); connections.removeAll(); lock.unlock()
        for c in all { c.close() }
        isRunning = false
    }

    private func accept(_ nw: NWConnection) {
        let address = LocalServer.remoteAddress(of: nw)
        guard NetworkInfo.isPrivate(address: address) else {
            Log.server.warning("拒绝非局域网来源: \(address, privacy: .public)")
            nw.cancel()
            return
        }
        let client = ClientConnection(connection: nw, remoteAddress: address, server: self)
        lock.lock(); connections[client.id] = client; lock.unlock()
        client.onClosed = { [weak self] in
            guard let self = self else { return }
            self.lock.lock(); self.connections[client.id] = nil; self.lock.unlock()
        }
        client.start(on: queue)
    }

    static func remoteAddress(of conn: NWConnection) -> String {
        if case let .hostPort(host, _) = conn.endpoint {
            switch host {
            case .ipv4(let a): return "\(a)"
            case .ipv6(let a): return "\(a)"
            case .name(let n, _): return n
            @unknown default: return "\(host)"
            }
        }
        return "unknown"
    }
}

/// 一个 TCP 连接：先按 HTTP 解析，升级后按 WebSocket 帧解析。
final class ClientConnection {
    let id = UUID()
    let connection: NWConnection
    let remoteAddress: String
    private weak var server: LocalServer?
    private var buffer = Data()
    private var isWebSocket = false
    private var wsClient: WSClient?
    private var fragments = Data()
    private var fragmentOpcode: WSOpcode?
    private var busy = false
    private var closed = false
    private let stateQueue = DispatchQueue(label: "com.li.screenai.conn")
    var onClosed: (() -> Void)?

    init(connection: NWConnection, remoteAddress: String, server: LocalServer) {
        self.connection = connection
        self.remoteAddress = remoteAddress
        self.server = server
    }

    func start(on queue: DispatchQueue) {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.handleClosed()
            default: break
            }
        }
        connection.start(queue: stateQueue)
        receive()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            if let data = data, !data.isEmpty {
                self.buffer.append(data)
                self.process()
            }
            if isComplete || error != nil {
                self.close()
                return
            }
            if !self.closed { self.receive() }
        }
    }

    private func process() {
        if isWebSocket { processFrames() } else { processHTTP() }
    }

    // MARK: HTTP

    private func processHTTP() {
        guard !busy else { return }
        do {
            guard let (request, consumed) = try HTTPParser.parse(buffer) else { return }
            buffer.removeSubrange(0..<consumed)
            if request.isWebSocketUpgrade {
                guard request.path == "/ws", let key = request.header("sec-websocket-key") else {
                    send(HTTPResponse.text("Bad WebSocket request", status: 400).serialized(close: true)) { self.close() }
                    return
                }
                isWebSocket = true
                let client = WSClient(remoteAddress: remoteAddress)
                client.sendData = { [weak self] data in self?.send(data, completion: nil) }
                client.closeConnection = { [weak self] in self?.close() }
                wsClient = client
                send(WebSocketCodec.handshakeResponse(clientKey: key)) { [weak self] in
                    guard let self = self else { return }
                    self.server?.hub.add(client)
                    self.stateQueue.async { self.processFrames() }
                }
                return
            }
            busy = true
            let close = request.wantsClose
            server?.httpHandler(request, remoteAddress) { [weak self] response in
                guard let self = self else { return }
                self.stateQueue.async {
                    self.send(response.serialized(close: close)) {
                        self.busy = false
                        if close { self.close() } else { self.processHTTP() }
                    }
                }
            }
        } catch {
            send(HTTPResponse.text("Bad Request", status: 400).serialized(close: true)) { self.close() }
        }
    }

    // MARK: WebSocket

    private func processFrames() {
        guard let client = wsClient else { return }
        while true {
            do {
                guard let (frame, consumed) = try WebSocketCodec.decode(buffer) else { return }
                buffer.removeSubrange(0..<consumed)
                switch frame.opcode {
                case .text, .binary:
                    if frame.fin {
                        if frame.opcode == .text, let s = String(data: frame.payload, encoding: .utf8) {
                            server?.hub.handleText(client, s)
                        }
                    } else {
                        fragmentOpcode = frame.opcode
                        fragments = frame.payload
                    }
                case .continuation:
                    fragments.append(frame.payload)
                    if frame.fin {
                        if fragmentOpcode == .text, let s = String(data: fragments, encoding: .utf8) {
                            server?.hub.handleText(client, s)
                        }
                        fragments = Data(); fragmentOpcode = nil
                    }
                case .ping:
                    send(WebSocketCodec.encode(opcode: .pong, payload: frame.payload), completion: nil)
                case .pong:
                    server?.hub.handlePongFrame(client)
                case .close:
                    send(WebSocketCodec.close(), completion: nil)
                    close()
                    return
                }
            } catch {
                Log.server.error("WS 帧错误: \(String(describing: error), privacy: .public)")
                close()
                return
            }
        }
    }

    // MARK: IO

    private func send(_ data: Data, completion: (() -> Void)?) {
        guard !closed else { return }
        connection.send(content: data, completion: .contentProcessed { _ in completion?() })
    }

    func close() {
        stateQueue.async {
            guard !self.closed else { return }
            self.closed = true
            self.connection.cancel()
            self.handleClosed()
        }
    }

    private func handleClosed() {
        if let c = wsClient {
            server?.hub.remove(c)
            wsClient = nil
        }
        closed = true
        onClosed?()
        onClosed = nil
    }
}

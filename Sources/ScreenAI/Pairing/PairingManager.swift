import Foundation
import Combine

enum PairingError: Error {
    case noActiveCode, expired, mismatch, tooManyAttempts, rateLimited

    var message: String {
        switch self {
        case .noActiveCode: return "电脑端未显示验证码，请先在菜单栏点击「显示验证码」"
        case .expired: return "验证码已过期，请查看电脑端新的验证码"
        case .mismatch: return "验证码错误"
        case .tooManyAttempts: return "错误次数过多，验证码已作废，请查看电脑端新的验证码"
        case .rateLimited: return "尝试过于频繁，请稍后再试"
        }
    }
}

struct PairingSession: Equatable {
    let token: String
    let expiresAt: Date
    let clientAddress: String
    let createdAt: Date
}

/// 验证码配对与会话 token 管理。核心状态受锁保护，可从服务器线程调用；@Published 镜像在主线程更新。
final class PairingManager: ObservableObject {
    static let codeLifetime: TimeInterval = 60
    static let tokenLifetime: TimeInterval = 24 * 3600
    static let maxAttempts = 5
    static let ipRateLimit = 10           // 每分钟每 IP 次数

    @Published private(set) var code: String?
    @Published private(set) var codeExpiresAt: Date?
    @Published private(set) var session: PairingSession?
    @Published private(set) var pairedEvent: Int = 0     // 每次配对成功 +1，用于窗口显示成功动画
    @Published private(set) var connectedClients: Int = 0

    private let lock = NSLock()
    private var sCode: String?
    private var sCodeExpiresAt: Date?
    private var sAttempts = 0
    private var sSession: PairingSession?
    private var sIpHits: [String: [Date]] = [:]

    // MARK: Code

    func generateCode() {
        lock.lock()
        sCode = String(format: "%06d", Int.random(in: 0...999_999))
        sCodeExpiresAt = Date().addingTimeInterval(PairingManager.codeLifetime)
        sAttempts = 0
        let c = sCode, e = sCodeExpiresAt
        lock.unlock()
        Log.pairing.info("生成验证码")
        publish { self.code = c; self.codeExpiresAt = e }
    }

    func invalidateCode() {
        lock.lock()
        sCode = nil; sCodeExpiresAt = nil; sAttempts = 0
        lock.unlock()
        publish { self.code = nil; self.codeExpiresAt = nil }
    }

    /// 若当前验证码已过期则生成新码（配对窗口定时调用）
    func refreshIfExpired() {
        lock.lock()
        let expired = sCode == nil || (sCodeExpiresAt.map { $0 <= Date() } ?? true)
        lock.unlock()
        if expired { generateCode() }
    }

    // MARK: Verify

    func verify(code input: String, from ip: String) -> Result<PairingSession, PairingError> {
        let now = Date()
        lock.lock()
        defer { lock.unlock() }

        var hits = sIpHits[ip, default: []].filter { now.timeIntervalSince($0) < 60 }
        if hits.count >= PairingManager.ipRateLimit {
            sIpHits[ip] = hits
            return .failure(.rateLimited)
        }
        hits.append(now)
        sIpHits[ip] = hits

        guard let code = sCode, let exp = sCodeExpiresAt else { return .failure(.noActiveCode) }
        if exp <= now {
            sCode = nil; sCodeExpiresAt = nil
            publish { self.code = nil; self.codeExpiresAt = nil }
            return .failure(.expired)
        }
        let cleaned = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned == code else {
            sAttempts += 1
            if sAttempts >= PairingManager.maxAttempts {
                sCode = nil; sCodeExpiresAt = nil; sAttempts = 0
                publish { self.code = nil; self.codeExpiresAt = nil }
                return .failure(.tooManyAttempts)
            }
            return .failure(.mismatch)
        }

        // 成功：验证码一次性作废，颁发新 token，撤销旧会话
        sCode = nil; sCodeExpiresAt = nil; sAttempts = 0
        let token = PairingManager.randomToken()
        let session = PairingSession(token: token, expiresAt: now.addingTimeInterval(PairingManager.tokenLifetime), clientAddress: ip, createdAt: now)
        sSession = session
        Log.pairing.info("配对成功，来自 \(ip, privacy: .public)")
        publish {
            self.code = nil; self.codeExpiresAt = nil
            self.session = session
            self.pairedEvent += 1
        }
        return .success(session)
    }

    func isValid(token: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let s = sSession, s.token == token else { return false }
        if s.expiresAt <= Date() {
            sSession = nil
            publish { self.session = nil }
            return false
        }
        return true
    }

    var currentSession: PairingSession? {
        lock.lock(); defer { lock.unlock() }
        return sSession
    }

    func revokeSession() {
        lock.lock(); sSession = nil; lock.unlock()
        publish { self.session = nil }
    }

    func setConnectedClients(_ n: Int) {
        publish { self.connectedClients = n }
    }

    // MARK: Helpers

    private static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess {
            bytes = (0..<32).map { _ in UInt8.random(in: 0...255) }
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private func publish(_ block: @escaping () -> Void) {
        if Thread.isMainThread { block() } else { DispatchQueue.main.async(execute: block) }
    }
}

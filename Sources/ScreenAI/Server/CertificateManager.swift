import Foundation
import Security
import CryptoKit

/// 本地根证书与服务器证书管理：用系统自带 openssl 生成，导入应用私有钥匙串后提供 SecIdentity 供 TLS 监听使用。
final class CertificateManager {
    struct ServerInfo: Codable, Equatable {
        var sans: [String]          // "DNS:xxx" / "IP:1.2.3.4"
        var notAfter: Date
        var issuedAt: Date
    }

    struct CAInfo: Codable {
        var commonName: String
        var createdAt: Date
        var notAfter: Date
    }

    enum CertError: LocalizedError {
        case opensslMissing
        case opensslFailed(String)
        case importFailed(OSStatus)
        case keychainFailed(OSStatus)
        case missingFiles

        var errorDescription: String? {
            switch self {
            case .opensslMissing: return "找不到 /usr/bin/openssl"
            case .opensslFailed(let s): return "openssl 执行失败：\(s.truncated(300))"
            case .importFailed(let st): return "导入服务器证书失败（OSStatus \(st)）"
            case .keychainFailed(let st): return "创建应用钥匙串失败（OSStatus \(st)）"
            case .missingFiles: return "证书文件缺失"
            }
        }
    }

    static let caDays = 3650
    static let serverDays = 800          // iOS 要求 TLS 服务器证书有效期 ≤ 825 天
    static let renewBeforeDays = 30
    static let maxIPs = 24

    let directory: URL
    private let opensslPath = "/usr/bin/openssl"
    private let p12Password = "screenai"
    private let keychainPassword = "screenai"
    private let lock = NSRecursiveLock()
    private var keychain: SecKeychain?
    private(set) var identity: SecIdentity?
    private(set) var lastError: String?

    init(directory: URL) {
        self.directory = directory
    }

    // MARK: Files

    private var caKeyURL: URL { directory.appendingPathComponent("ca.key.pem") }
    private var caCertURL: URL { directory.appendingPathComponent("ca.crt.pem") }
    private var caDERURL: URL { directory.appendingPathComponent("ca.der") }
    private var caInfoURL: URL { directory.appendingPathComponent("ca.json") }
    private var serverKeyURL: URL { directory.appendingPathComponent("server.key.pem") }
    private var serverCSRURL: URL { directory.appendingPathComponent("server.csr") }
    private var serverCertURL: URL { directory.appendingPathComponent("server.crt.pem") }
    private var serverP12URL: URL { directory.appendingPathComponent("server.p12") }
    private var serverInfoURL: URL { directory.appendingPathComponent("server.json") }
    private var keychainURL: URL { directory.appendingPathComponent("screenai-tls.keychain-db") }

    // MARK: Public info

    var caCertificateDER: Data? { try? Data(contentsOf: caDERURL) }
    var caCertificatePEM: Data? { try? Data(contentsOf: caCertURL) }
    var serverCertificatePEM: Data? { try? Data(contentsOf: serverCertURL) }

    var caFingerprint: String? {
        guard let der = caCertificateDER else { return nil }
        return SHA256.hash(data: der).map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    var caInfo: CAInfo? {
        guard let d = try? Data(contentsOf: caInfoURL) else { return nil }
        return try? JSONDecoder().decode(CAInfo.self, from: d)
    }

    var serverInfo: ServerInfo? {
        guard let d = try? Data(contentsOf: serverInfoURL) else { return nil }
        return try? JSONDecoder().decode(ServerInfo.self, from: d)
    }

    var hasCA: Bool {
        FileManager.default.fileExists(atPath: caKeyURL.path) && FileManager.default.fileExists(atPath: caCertURL.path) && FileManager.default.fileExists(atPath: caDERURL.path)
    }

    static func sans(hostnames: [String], ips: [String]) -> [String] {
        var set = Set<String>()
        for h in hostnames where !h.isEmpty { set.insert("DNS:\(h.lowercased())") }
        for ip in ips where !ip.isEmpty { set.insert("IP:\(ip)") }
        return set.sorted()
    }

    /// 服务器证书是否需要重新签发（缺失、临期或 SAN 不包含当前地址）
    func needsRefresh(hostnames: [String], ips: [String]) -> Bool {
        guard hasCA, FileManager.default.fileExists(atPath: serverP12URL.path), let info = serverInfo else { return true }
        if info.notAfter.timeIntervalSinceNow < Double(CertificateManager.renewBeforeDays) * 86400 { return true }
        let desired = Set(CertificateManager.sans(hostnames: hostnames, ips: ips))
        return !desired.isSubset(of: Set(info.sans))
    }

    // MARK: Main entry

    /// 确保根证书与服务器证书存在且覆盖当前地址，返回可用于 TLS 的身份。
    func ensureIdentity(hostnames: [String], ips: [String]) throws -> SecIdentity {
        lock.lock(); defer { lock.unlock() }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if !hasCA { try createCA() }
            if needsRefresh(hostnames: hostnames, ips: ips) {
                // 保留旧 SAN 并入新地址，减少换网时的反复签发
                var merged = Set(serverInfo?.sans ?? [])
                merged.formUnion(CertificateManager.sans(hostnames: hostnames, ips: ips))
                var list = merged.sorted()
                if list.filter({ $0.hasPrefix("IP:") }).count > CertificateManager.maxIPs {
                    list = CertificateManager.sans(hostnames: hostnames, ips: ips)
                }
                try issueServer(sans: list)
            }
            if identity == nil { identity = try loadIdentity() }
            lastError = nil
            return identity!
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            Log.server.error("证书准备失败: \(self.lastError ?? "", privacy: .public)")
            throw error
        }
    }

    /// 强制重新签发服务器证书（根证书不变，手机无需重装）
    func regenerateServer(hostnames: [String], ips: [String]) throws -> SecIdentity {
        lock.lock(); defer { lock.unlock() }
        if !hasCA { try createCA() }
        try issueServer(sans: CertificateManager.sans(hostnames: hostnames, ips: ips))
        identity = try loadIdentity()
        return identity!
    }

    /// 重建根证书（所有手机需重新安装）
    func resetAll(hostnames: [String], ips: [String]) throws -> SecIdentity {
        lock.lock(); defer { lock.unlock() }
        try createCA()
        try issueServer(sans: CertificateManager.sans(hostnames: hostnames, ips: ips))
        identity = try loadIdentity()
        return identity!
    }

    // MARK: openssl

    private var hostLabel: String {
        NetworkInfo.localHostname().map { String($0.prefix(40)) } ?? "Mac"
    }

    private func createCA() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cn = "ScreenAI Local CA (\(hostLabel))"
        let cnf = """
        [req]
        distinguished_name = dn
        x509_extensions = v3_ca
        prompt = no
        [dn]
        CN = \(cn)
        O = ScreenAI
        [v3_ca]
        basicConstraints = critical, CA:true
        keyUsage = critical, keyCertSign, cRLSign
        subjectKeyIdentifier = hash
        """
        let cnfURL = directory.appendingPathComponent("ca.cnf")
        try cnf.write(to: cnfURL, atomically: true, encoding: .utf8)
        try openssl(["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-sha256", "-days", String(CertificateManager.caDays),
                     "-keyout", caKeyURL.path, "-out", caCertURL.path, "-config", cnfURL.path])
        try openssl(["x509", "-in", caCertURL.path, "-outform", "DER", "-out", caDERURL.path])
        try setPermissions(caKeyURL)
        let info = CAInfo(commonName: cn, createdAt: Date(), notAfter: Date().addingTimeInterval(Double(CertificateManager.caDays) * 86400))
        try JSONEncoder().encode(info).write(to: caInfoURL, options: .atomic)
        for u in [serverKeyURL, serverCSRURL, serverCertURL, serverP12URL, serverInfoURL] { try? FileManager.default.removeItem(at: u) }
        identity = nil
        Log.server.info("已生成本地根证书")
    }

    private func issueServer(sans: [String]) throws {
        guard hasCA else { throw CertError.missingFiles }
        var alt: [String] = []
        var dnsIndex = 0, ipIndex = 0
        for s in sans {
            if s.hasPrefix("DNS:") { dnsIndex += 1; alt.append("DNS.\(dnsIndex) = \(s.dropFirst(4))") }
            else if s.hasPrefix("IP:") { ipIndex += 1; alt.append("IP.\(ipIndex) = \(s.dropFirst(3))") }
        }
        if alt.isEmpty { alt = ["DNS.1 = localhost", "IP.1 = 127.0.0.1"] }
        let cnf = """
        [req]
        distinguished_name = dn
        prompt = no
        [dn]
        CN = ScreenAI (\(hostLabel))
        O = ScreenAI
        [v3_server]
        basicConstraints = critical, CA:false
        keyUsage = critical, digitalSignature, keyEncipherment
        extendedKeyUsage = serverAuth
        subjectKeyIdentifier = hash
        authorityKeyIdentifier = keyid,issuer
        subjectAltName = @alt_names
        [alt_names]
        \(alt.joined(separator: "\n"))
        """
        let cnfURL = directory.appendingPathComponent("server.cnf")
        try cnf.write(to: cnfURL, atomically: true, encoding: .utf8)
        try openssl(["req", "-new", "-newkey", "rsa:2048", "-nodes", "-sha256",
                     "-keyout", serverKeyURL.path, "-out", serverCSRURL.path, "-config", cnfURL.path])
        try openssl(["x509", "-req", "-in", serverCSRURL.path, "-CA", caCertURL.path, "-CAkey", caKeyURL.path, "-CAcreateserial",
                     "-days", String(CertificateManager.serverDays), "-sha256",
                     "-extfile", cnfURL.path, "-extensions", "v3_server", "-out", serverCertURL.path])
        try openssl(["pkcs12", "-export", "-inkey", serverKeyURL.path, "-in", serverCertURL.path, "-certfile", caCertURL.path,
                     "-name", "ScreenAI Server", "-passout", "pass:\(p12Password)", "-out", serverP12URL.path])
        try setPermissions(serverKeyURL)
        try setPermissions(serverP12URL)
        let info = ServerInfo(sans: sans, notAfter: Date().addingTimeInterval(Double(CertificateManager.serverDays) * 86400), issuedAt: Date())
        try JSONEncoder().encode(info).write(to: serverInfoURL, options: .atomic)
        identity = nil
        Log.server.info("已签发服务器证书，SAN: \(sans.joined(separator: ", "), privacy: .public)")
    }

    @discardableResult
    private func openssl(_ args: [String]) throws -> String {
        guard FileManager.default.isExecutableFile(atPath: opensslPath) else { throw CertError.opensslMissing }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: opensslPath)
        p.arguments = args
        p.currentDirectoryURL = directory
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let o = String(data: outData, encoding: .utf8) ?? ""
        let e = String(data: errData, encoding: .utf8) ?? ""
        guard p.terminationStatus == 0 else { throw CertError.opensslFailed(e.isEmpty ? o : e) }
        return o
    }

    private func setPermissions(_ url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    // MARK: Keychain / identity

    /// 每次重新创建应用私有钥匙串并导入 p12，避免签名变化导致访问弹窗。
    private func loadIdentity() throws -> SecIdentity {
        guard let p12 = try? Data(contentsOf: serverP12URL) else { throw CertError.missingFiles }
        if let old = keychain { SecKeychainDelete(old); keychain = nil }
        try? FileManager.default.removeItem(at: keychainURL)

        var kc: SecKeychain?
        let pw = keychainPassword
        var status = pw.withCString { cstr in
            SecKeychainCreate(keychainURL.path, UInt32(strlen(cstr)), cstr, false, nil, &kc)
        }
        guard status == errSecSuccess, let keychain = kc else { throw CertError.keychainFailed(status) }
        self.keychain = keychain
        // 注意：不要调用 SecKeychainSetSettings，它会等待系统交互而阻塞主线程；新建钥匙串默认不自动锁定。
        status = pw.withCString { cstr in SecKeychainUnlock(keychain, UInt32(strlen(cstr)), cstr, true) }
        guard status == errSecSuccess else { throw CertError.keychainFailed(status) }

        let options: [String: Any] = [
            kSecImportExportPassphrase as String: p12Password,
            kSecImportExportKeychain as String: keychain,
        ]
        var items: CFArray?
        status = SecPKCS12Import(p12 as CFData, options as CFDictionary, &items)
        guard status == errSecSuccess, let array = items as? [[String: Any]], let first = array.first,
              let raw = first[kSecImportItemIdentity as String] else { throw CertError.importFailed(status) }
        let ref = raw as CFTypeRef
        guard CFGetTypeID(ref) == SecIdentityGetTypeID() else { throw CertError.importFailed(errSecInternalError) }
        let identity = ref as! SecIdentity
        Log.server.info("已加载服务器 TLS 身份")
        return identity
    }

    /// 保险起见定期解锁应用钥匙串（默认不会自动锁定）
    func unlockKeychain() {
        lock.lock(); defer { lock.unlock() }
        guard let kc = keychain else { return }
        _ = keychainPassword.withCString { cstr in SecKeychainUnlock(kc, UInt32(strlen(cstr)), cstr, true) }
    }

    // MARK: iOS 描述文件

    /// 生成包含根证书的 .mobileconfig（未签名），UUID 由证书指纹派生以保证幂等。
    func mobileConfig() -> Data? {
        guard let der = caCertificateDER else { return nil }
        let digest = Array(SHA256.hash(data: der))
        func uuid(_ offset: Int) -> String {
            var b = Array(digest[offset..<(offset + 16)])
            b[6] = (b[6] & 0x0F) | 0x40
            b[8] = (b[8] & 0x3F) | 0x80
            let t = (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15])
            return UUID(uuid: t).uuidString
        }
        let cn = caInfo?.commonName ?? "ScreenAI Local CA"
        let payload: [String: Any] = [
            "PayloadCertificateFileName": "screenai-ca.cer",
            "PayloadContent": der,
            "PayloadDescription": "ScreenAI 本地 HTTPS 根证书。安装后请在「设置 › 通用 › 关于本机 › 证书信任设置」中启用完全信任。",
            "PayloadDisplayName": cn,
            "PayloadIdentifier": "com.li.screenai.ca.\(uuid(0).lowercased()).cert",
            "PayloadType": "com.apple.security.root",
            "PayloadUUID": uuid(16),
            "PayloadVersion": 1,
        ]
        let root: [String: Any] = [
            "PayloadContent": [payload],
            "PayloadDescription": "为 ScreenAI 局域网 HTTPS 连接安装本地根证书。安装后请在「设置 › 通用 › 关于本机 › 证书信任设置」中打开完全信任。",
            "PayloadDisplayName": "ScreenAI 根证书",
            "PayloadIdentifier": "com.li.screenai.ca.\(uuid(0).lowercased())",
            "PayloadOrganization": "ScreenAI",
            "PayloadRemovalDisallowed": false,
            "PayloadType": "Configuration",
            "PayloadUUID": uuid(0),
            "PayloadVersion": 1,
        ]
        return try? PropertyListSerialization.data(fromPropertyList: root, format: .xml, options: 0)
    }
}

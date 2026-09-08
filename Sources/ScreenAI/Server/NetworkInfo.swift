import Foundation
import SystemConfiguration

enum NetworkInfo {
    /// 本机的 IPv4 局域网地址（en0 优先）
    static func lanIPv4Addresses() -> [String] {
        var result: [(String, String)] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let p = ptr {
            defer { ptr = p.pointee.ifa_next }
            guard let addr = p.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let flags = Int32(p.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0 else { continue }
            let name = String(cString: p.pointee.ifa_name)
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                let ip = String(cString: host)
                if isPrivate(address: ip) { result.append((name, ip)) }
            }
        }
        return result.sorted { a, b in
            if a.0 == "en0" && b.0 != "en0" { return true }
            if b.0 == "en0" && a.0 != "en0" { return false }
            return a.0 < b.0
        }.map { $0.1 }
    }

    /// Bonjour 本地主机名，如 "lidemacbook-air"
    static func localHostname() -> String? {
        guard let name = SCDynamicStoreCopyLocalHostName(nil) as String?, !name.isEmpty else { return nil }
        return name.lowercased()
    }

    /// 是否为私有/本机地址（IPv4 私网段、回环、链路本地；IPv6 ULA/链路本地/回环；IPv4 映射）
    static func isPrivate(address raw: String) -> Bool {
        var s = raw
        if let pct = s.firstIndex(of: "%") { s = String(s[..<pct]) }
        if s.hasPrefix("[") { s.removeFirst() }
        if s.hasSuffix("]") { s.removeLast() }
        let lower = s.lowercased()
        if lower.hasPrefix("::ffff:") {
            return isPrivate(address: String(lower.dropFirst(7)))
        }
        if lower == "::1" { return true }
        if lower.hasPrefix("fe80:") || lower.hasPrefix("fc") || lower.hasPrefix("fd") { return lower.contains(":") }
        let parts = lower.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ $0 >= 0 && $0 <= 255 }) else { return false }
        switch parts[0] {
        case 10, 127: return true
        case 172: return parts[1] >= 16 && parts[1] <= 31
        case 192: return parts[1] == 168
        case 169: return parts[1] == 254
        default: return false
        }
    }
}

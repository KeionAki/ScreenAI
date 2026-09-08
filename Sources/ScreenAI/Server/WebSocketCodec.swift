import Foundation
import CryptoKit

enum WSOpcode: UInt8 {
    case continuation = 0x0, text = 0x1, binary = 0x2, close = 0x8, ping = 0x9, pong = 0xA
}

struct WSFrame {
    var fin: Bool
    var opcode: WSOpcode
    var payload: Data
}

enum WSError: Error { case malformed, unmasked, tooLarge, unknownOpcode }

/// RFC 6455 帧编解码（服务器端：收到的帧必须带掩码，发送的帧不带掩码）。
enum WebSocketCodec {
    static let guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
    static let maxPayload = 4 * 1024 * 1024

    static func acceptKey(for clientKey: String) -> String {
        let digest = Insecure.SHA1.hash(data: Data((clientKey.trimmingCharacters(in: .whitespaces) + guid).utf8))
        return Data(digest).base64EncodedString()
    }

    static func handshakeResponse(clientKey: String) -> Data {
        let head = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(acceptKey(for: clientKey))\r\n\r\n"
        return Data(head.utf8)
    }

    /// 解析一帧；数据不足返回 nil。
    static func decode(_ buf: Data) throws -> (WSFrame, Int)? {
        guard buf.count >= 2 else { return nil }
        let b = [UInt8](buf.prefix(14))
        let fin = b[0] & 0x80 != 0
        let opRaw = b[0] & 0x0F
        guard let opcode = WSOpcode(rawValue: opRaw) else { throw WSError.unknownOpcode }
        let masked = b[1] & 0x80 != 0
        var length = Int(b[1] & 0x7F)
        var offset = 2
        if length == 126 {
            guard buf.count >= 4 else { return nil }
            length = Int(b[2]) << 8 | Int(b[3])
            offset = 4
        } else if length == 127 {
            guard buf.count >= 10 else { return nil }
            var l: UInt64 = 0
            for i in 2..<10 { l = l << 8 | UInt64(b[i]) }
            guard l <= UInt64(maxPayload) else { throw WSError.tooLarge }
            length = Int(l)
            offset = 10
        }
        guard length <= maxPayload else { throw WSError.tooLarge }
        guard masked else { throw WSError.unmasked }
        guard buf.count >= offset + 4 + length else { return nil }
        let maskKey = [UInt8](buf.subdata(in: offset..<(offset + 4)))
        offset += 4
        var payload = [UInt8](buf.subdata(in: offset..<(offset + length)))
        for i in 0..<payload.count { payload[i] ^= maskKey[i & 3] }
        return (WSFrame(fin: fin, opcode: opcode, payload: Data(payload)), offset + length)
    }

    static func encode(opcode: WSOpcode, payload: Data, fin: Bool = true) -> Data {
        var out = Data()
        out.append((fin ? 0x80 : 0x00) | opcode.rawValue)
        let n = payload.count
        if n < 126 {
            out.append(UInt8(n))
        } else if n <= 0xFFFF {
            out.append(126)
            out.append(UInt8(n >> 8 & 0xFF)); out.append(UInt8(n & 0xFF))
        } else {
            out.append(127)
            for i in (0..<8).reversed() { out.append(UInt8((UInt64(n) >> (UInt64(i) * 8)) & 0xFF)) }
        }
        out.append(payload)
        return out
    }

    static func text(_ s: String) -> Data { encode(opcode: .text, payload: Data(s.utf8)) }

    static func close(code: UInt16 = 1000, reason: String = "") -> Data {
        var p = Data([UInt8(code >> 8), UInt8(code & 0xFF)])
        p.append(Data(reason.utf8))
        return encode(opcode: .close, payload: p)
    }
}

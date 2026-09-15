import Foundation
import CoreGraphics

/// 画面变化检测：把截图缩成 32×32 灰度签名，比较平均差异。
enum ChangeDetector {
    static let side = 32
    /// 平均差异低于此比例视为“画面无变化”
    static let threshold = 0.015

    static func signature(_ image: CGImage) -> [UInt8] {
        let n = side * side
        var buf = [UInt8](repeating: 0, count: n)
        let space = CGColorSpaceCreateDeviceGray()
        buf.withUnsafeMutableBytes { ptr in
            guard let ctx = CGContext(data: ptr.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side,
                                      space: space, bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            ctx.interpolationQuality = .low
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        }
        return buf
    }

    /// 0 = 完全相同，1 = 完全不同
    static func difference(_ a: [UInt8], _ b: [UInt8]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 1 }
        var sum = 0
        for i in 0..<a.count { sum += abs(Int(a[i]) - Int(b[i])) }
        return Double(sum) / Double(a.count * 255)
    }

    static func isUnchanged(_ a: [UInt8]?, _ b: [UInt8]) -> Bool {
        guard let a = a else { return false }
        return difference(a, b) < threshold
    }
}

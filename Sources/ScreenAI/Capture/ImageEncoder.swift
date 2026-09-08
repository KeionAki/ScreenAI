import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

struct EncodedImage {
    let data: Data
    let width: Int
    let height: Int
    var base64: String { data.base64EncodedString() }
    var byteCount: Int { data.count }
}

enum ImageEncoder {
    /// 缩放到最长边不超过 maxLongEdge（像素）
    static func downscale(_ image: CGImage, maxLongEdge: Int) -> CGImage {
        let w = image.width, h = image.height
        let longest = max(w, h)
        guard maxLongEdge > 0, longest > maxLongEdge else { return image }
        let scale = Double(maxLongEdge) / Double(longest)
        let nw = max(1, Int((Double(w) * scale).rounded()))
        let nh = max(1, Int((Double(h) * scale).rounded()))
        let space = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = CGContext(data: nil, width: nw, height: nh, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: info) else {
            return image
        }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: nw, height: nh))
        return ctx.makeImage() ?? image
    }

    static func jpeg(_ image: CGImage, quality: CGFloat) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        let opts: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(dest, image, opts as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    static func png(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    static func encode(_ image: CGImage, maxLongEdge: Int, quality: CGFloat) -> EncodedImage? {
        let scaled = downscale(image, maxLongEdge: maxLongEdge)
        guard let data = jpeg(scaled, quality: quality) else { return nil }
        return EncodedImage(data: data, width: scaled.width, height: scaled.height)
    }
}

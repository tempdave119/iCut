import CoreGraphics

/// 长截图的拼接状态：保留已接收的行指纹与新增条带，最终一次性合成整图。
final class StitchAccumulator {
    enum AppendResult: Equatable {
        case appended(addedRows: Int)
        case unchanged(String)
    }

    private let maxHeight: Int
    /// 小于这个重叠行数就不认为两帧有共同内容
    private let minOverlap = 40

    private(set) var width = 0
    private(set) var height = 0
    private var strips: [CGImage] = []
    private var hashes: [UInt64] = []

    init(maxHeight: Int = 20000) {
        self.maxHeight = maxHeight
    }

    func append(_ image: CGImage) -> AppendResult {
        let incoming = RollingStitcher.rowHashes(of: image)
        guard !incoming.isEmpty else { return .unchanged("无法读取画面") }

        guard width > 0 else {
            width = image.width
            strips = [image]
            hashes = incoming
            height = incoming.count
            return .appended(addedRows: incoming.count)
        }

        guard image.width == width else { return .unchanged("画面尺寸变化") }

        guard let overlap = RollingStitcher.findOverlap(
            existing: hashes,
            incoming: incoming,
            minOverlap: minOverlap
        ) else {
            return .unchanged("未找到重叠区域")
        }

        let added = incoming.count - overlap
        guard added > 0 else { return .unchanged("画面未滚动") }
        guard height + added <= maxHeight else { return .unchanged("已达高度上限") }

        // overlap 按顶行计数，cropping 的 y 也从顶部算
        guard let strip = image.cropping(
            to: CGRect(x: 0, y: overlap, width: width, height: added)
        ) else {
            return .unchanged("裁切失败")
        }

        strips.append(strip)
        hashes.append(contentsOf: incoming[overlap...])
        height += added
        return .appended(addedRows: added)
    }

    /// 自顶向下合成；没有内容时返回 nil。
    func makeImage() -> CGImage? {
        guard width > 0, height > 0 else { return nil }
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        var y = CGFloat(height)
        for strip in strips {
            let stripHeight = CGFloat(strip.height)
            y -= stripHeight
            context.draw(strip, in: CGRect(x: 0, y: y, width: CGFloat(width), height: stripHeight))
        }
        return context.makeImage()
    }
}

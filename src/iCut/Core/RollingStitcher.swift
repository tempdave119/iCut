import CoreGraphics

/// 长截图的行指纹与重叠匹配纯逻辑：不依赖 UI，便于单测。
/// 思路：把每行降采样成一个 64 位指纹，相邻两帧在“上一帧末尾 == 本帧开头”的重叠行里找匹配。
enum RollingStitcher {
    /// 每行采样的列数：宽度很大时降采样，把单帧哈希控制在毫秒级
    private static let samplesPerRow = 96
    /// 允许的行差异比例（光标闪烁、抗锯齿会让个别行不同）
    private static let mismatchRatio = 0.01

    /// 逐行指纹（图像顶行在前）；读取失败返回空数组。
    static func rowHashes(of image: CGImage) -> [UInt64] {
        guard let buffer = normalizedBuffer(of: image) else { return [] }
        var hashes: [UInt64] = []
        hashes.reserveCapacity(buffer.height)
        let stride = max(1, buffer.width / samplesPerRow)

        for row in 0..<buffer.height {
            var hash: UInt64 = 0xcbf29ce484222325
            let rowStart = row * buffer.bytesPerRow
            var x = 0
            while x < buffer.width {
                let offset = rowStart + x * 4
                for channel in 0..<4 {
                    hash ^= UInt64(buffer.data[offset + channel])
                    hash = hash &* 0x100000001b3
                }
                x += stride
            }
            hashes.append(hash)
        }
        return hashes
    }

    /// 找最大重叠 h：existing 末尾 h 行 == incoming 开头 h 行；找不到返回 nil。
    /// 先做精确匹配，失败后再允许 1% 的行差异重试一次。
    static func findOverlap(existing: [UInt64], incoming: [UInt64], minOverlap: Int) -> Int? {
        let maxOverlap = min(existing.count, incoming.count)
        guard minOverlap > 0, maxOverlap >= minOverlap else { return nil }

        if let exact = largestMatch(existing: existing, incoming: incoming, minOverlap: minOverlap, tolerance: 0) {
            return exact
        }
        let tolerance = max(2, maxOverlap / 100)
        return largestMatch(existing: existing, incoming: incoming, minOverlap: minOverlap, tolerance: tolerance)
    }

    private static func largestMatch(
        existing: [UInt64],
        incoming: [UInt64],
        minOverlap: Int,
        tolerance: Int
    ) -> Int? {
        let maxOverlap = min(existing.count, incoming.count)
        guard maxOverlap >= minOverlap else { return nil }
        for overlap in stride(from: maxOverlap, through: minOverlap, by: -1) {
            if matches(existing: existing, incoming: incoming, overlap: overlap, tolerance: tolerance) {
                return overlap
            }
        }
        return nil
    }

    private static func matches(existing: [UInt64], incoming: [UInt64], overlap: Int, tolerance: Int) -> Bool {
        let start = existing.count - overlap
        var mismatches = 0
        for index in 0..<overlap {
            if existing[start + index] != incoming[index] {
                mismatches += 1
                if mismatches > tolerance { return false }
            }
        }
        return true
    }

    // MARK: - 像素读取

    private struct Buffer {
        let width: Int
        let height: Int
        let bytesPerRow: Int
        let data: [UInt8]
    }

    /// 统一转成 RGBA8 再取字节：抓屏与合成出来的图格式不完全一样，先归一化才能逐行比较。
    private static func normalizedBuffer(of image: CGImage) -> Buffer? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }

        let bytesPerRow = width * 4
        var data = [UInt8](repeating: 0, count: bytesPerRow * height)
        let drawn = data.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                return false
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? Buffer(width: width, height: height, bytesPerRow: bytesPerRow, data: data) : nil
    }
}

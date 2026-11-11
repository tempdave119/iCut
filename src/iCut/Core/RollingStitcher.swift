import CoreGraphics

/// 长截图的行指纹与重叠匹配纯逻辑：不依赖 UI，便于单测。
/// 思路：把每行降采样成一个 64 位指纹，在“上一帧末尾 == 本帧开头”的重叠行里找匹配。
/// 页面顶部常见粘性导航栏（每帧都一样、不随滚动移动），所以还支持跳过本帧开头若干行。
enum RollingStitcher {
    /// 一帧里最多允许多少行“固定不动”的头部（粘性导航）
    static let maxStickyRows = 240

    struct Overlap: Equatable {
        /// 本帧开头被跳过的固定行数（粘性头部）
        let skipRows: Int
        /// 与已拼接内容的重叠行数
        let overlapRows: Int
    }

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

    /// 找最大重叠：先全域精确匹配，不行再允许少量行差异（光标闪烁、抗锯齿）。
    /// 两阶段分开是为了避免“容忍档”把粘性头部的前几行也算进重叠，导致 skip 偏移。
    static func findOverlap(
        existing: [UInt64],
        incoming: [UInt64],
        minOverlap: Int
    ) -> Overlap? {
        guard minOverlap > 0 else { return nil }
        let maximumSkip = min(maxStickyRows, max(0, incoming.count - minOverlap))
        if let exact = search(existing: existing, incoming: incoming, minOverlap: minOverlap, maximumSkip: maximumSkip, tolerant: false) {
            return exact
        }
        return search(existing: existing, incoming: incoming, minOverlap: minOverlap, maximumSkip: maximumSkip, tolerant: true)
    }

    private static func search(
        existing: [UInt64],
        incoming: [UInt64],
        minOverlap: Int,
        maximumSkip: Int,
        tolerant: Bool
    ) -> Overlap? {
        for skip in 0...maximumSkip {
            if let overlap = match(
                existing: existing,
                incoming: incoming,
                skip: skip,
                minOverlap: minOverlap,
                tolerant: tolerant
            ) {
                return Overlap(skipRows: skip, overlapRows: overlap)
            }
        }
        return nil
    }

    /// 从最大重叠往下找：先用末行做锚点定位候选，再逐行核对，避免每帧 O(n²) 全扫
    private static func match(
        existing: [UInt64],
        incoming: [UInt64],
        skip: Int,
        minOverlap: Int,
        tolerant: Bool
    ) -> Int? {
        guard let anchor = existing.last else { return nil }
        let maxOverlap = min(existing.count, incoming.count - skip)
        guard maxOverlap >= minOverlap else { return nil }
        let tolerance = tolerant ? max(2, maxOverlap / 100) : 0

        for overlap in stride(from: maxOverlap, through: minOverlap, by: -1) {
            let anchorIndex = skip + overlap - 1
            guard incoming[anchorIndex] == anchor else { continue }
            if suffixMatches(existing: existing, incoming: incoming, skip: skip, overlap: overlap, tolerance: tolerance) {
                return overlap
            }
        }
        return nil
    }

    private static func suffixMatches(
        existing: [UInt64],
        incoming: [UInt64],
        skip: Int,
        overlap: Int,
        tolerance: Int
    ) -> Bool {
        let start = existing.count - overlap
        var mismatches = 0
        for index in 0..<overlap {
            if existing[start + index] != incoming[skip + index] {
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

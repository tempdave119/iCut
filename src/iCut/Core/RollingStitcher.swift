import CoreGraphics

/// 长截图的行指纹与重叠匹配：不依赖 UI，便于单测。
///
/// 早期版本用「整行精确哈希」，触控板平滑滚动会产生亚像素偏移，同一内容每帧重新栅格化后
/// 像素并不完全相同，哈希永远对不上（表现为怎么滚都拼不进去）。现在改成：
/// - 每行切成若干横向块，块内取平均亮度并量化成粗指纹；
/// - 行与行、块与块允许少量差异；
/// - 先做严格匹配（绝大多数页面都能命中），不行再走容忍匹配。
/// 另外页面顶部常见粘性导航（每帧都一样），匹配时允许跳过本帧开头若干行。
enum RollingStitcher {
    /// 一行切成多少块；块越少越抗噪，但行与行要能区分开，96 块 + 8 位均值在真实页面上足够
    private static let blocksPerRow = 96
    /// 块亮度差超过这个值算“不同”（容忍亚像素偏移带来的轻微抗锯齿差异）
    private static let blockDifferenceThreshold = 8
    /// 一帧里最多允许多少行“固定不动”的头部（粘性导航）
    static let maxStickyRows = 240

    typealias RowSignature = [UInt8]

    struct Overlap: Equatable {
        /// 本帧开头被跳过的固定行数（粘性头部）
        let skipRows: Int
        /// 与已拼接内容的重叠行数
        let overlapRows: Int
    }

    // MARK: - 指纹

    /// 逐行粗指纹（顶行在前）；读取失败返回空数组。
    static func rowSignatures(of image: CGImage) -> [RowSignature] {
        guard let buffer = normalizedBuffer(of: image) else { return [] }

        // 只采中间区域：避开右侧滚动条与窗口圆角（它们不随内容滚动）
        let inset = min(max(16, buffer.width / 20), buffer.width / 4)
        let startX = inset
        let endX = max(startX + 1, buffer.width - inset)
        let regionWidth = endX - startX
        let blockWidth = max(1, regionWidth / blocksPerRow)

        var signatures: [RowSignature] = []
        signatures.reserveCapacity(buffer.height)

        for row in 0..<buffer.height {
            let rowStart = row * buffer.bytesPerRow
            var signature = [UInt8](repeating: 0, count: blocksPerRow)
            // 不做亮度粗化：粗化会让相邻行指纹变得一模一样，重叠定位会错位
            for block in 0..<blocksPerRow {
                let blockStart = startX + block * blockWidth
                let blockEnd = min(endX, blockStart + blockWidth)
                guard blockEnd > blockStart else { continue }
                var sum = 0
                var count = 0
                var x = blockStart
                while x < blockEnd {
                    let offset = rowStart + x * 4
                    let luminance = (Int(buffer.data[offset]) * 77
                        + Int(buffer.data[offset + 1]) * 150
                        + Int(buffer.data[offset + 2]) * 29) >> 8
                    sum += luminance
                    count += 1
                    x += 1
                }
                signature[block] = UInt8(sum / max(1, count))
            }
            signatures.append(signature)
        }
        return signatures
    }

    // MARK: - 重叠匹配

    /// 找最大重叠：先严格匹配，失败再做块级容忍匹配。
    static func findOverlap(
        existing: [RowSignature],
        incoming: [RowSignature],
        minOverlap: Int,
        preferredSkip: Int = 0
    ) -> Overlap? {
        guard minOverlap > 0 else { return nil }
        let maximumSkip = min(maxStickyRows, max(0, incoming.count - minOverlap))

        var skips: [Int] = []
        if preferredSkip >= 0, preferredSkip <= maximumSkip {
            skips.append(preferredSkip)
        }
        for skip in 0...maximumSkip where skip != preferredSkip {
            skips.append(skip)
        }

        // 先严格后容忍：严格档全扫一遍，避免容忍档把粘性头部前几行算进重叠造成 skip 偏移
        if let strict = search(existing: existing, incoming: incoming, skips: skips, minOverlap: minOverlap, tolerant: false) {
            return strict
        }
        return search(existing: existing, incoming: incoming, skips: skips, minOverlap: minOverlap, tolerant: true)
    }

    private static func search(
        existing: [RowSignature],
        incoming: [RowSignature],
        skips: [Int],
        minOverlap: Int,
        tolerant: Bool
    ) -> Overlap? {
        for skip in skips {
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

    /// 从最大重叠往下找：先用少量采样行做预筛，命中后整段核对。
    /// 预筛不能只看末行：底边一行被浮层、光标或动画覆盖时，单行锚点会让整帧被丢弃。
    private static func match(
        existing: [RowSignature],
        incoming: [RowSignature],
        skip: Int,
        minOverlap: Int,
        tolerant: Bool
    ) -> Int? {
        let maxOverlap = min(existing.count, incoming.count - skip)
        guard maxOverlap >= minOverlap else { return nil }

        for overlap in stride(from: maxOverlap, through: minOverlap, by: -1) {
            guard anchorsMatch(
                existing: existing,
                incoming: incoming,
                skip: skip,
                overlap: overlap,
                tolerant: tolerant
            ) else { continue }
            if overlapMatches(
                existing: existing,
                incoming: incoming,
                skip: skip,
                overlap: overlap,
                tolerant: tolerant
            ) {
                return overlap
            }
        }
        return nil
    }

    /// 在重叠段内取三个采样行（中部、末行、1/4 处），任一命中即进入整段核对。
    /// 预筛只负责减少整段比对的次数，正确性由 `overlapMatches` 保证。
    private static func anchorsMatch(
        existing: [RowSignature],
        incoming: [RowSignature],
        skip: Int,
        overlap: Int,
        tolerant: Bool
    ) -> Bool {
        let start = existing.count - overlap
        let offsets = [overlap / 2, overlap - 1, overlap / 4]
        for offset in offsets {
            if rowMatches(existing[start + offset], incoming[skip + offset], tolerant: tolerant) {
                return true
            }
        }
        return false
    }

    private static func overlapMatches(
        existing: [RowSignature],
        incoming: [RowSignature],
        skip: Int,
        overlap: Int,
        tolerant: Bool
    ) -> Bool {
        let start = existing.count - overlap
        let allowedMismatchRows = tolerant ? max(2, overlap / 10) : 0
        var mismatches = 0
        for index in 0..<overlap {
            if !rowMatches(existing[start + index], incoming[skip + index], tolerant: tolerant) {
                mismatches += 1
                if mismatches > allowedMismatchRows { return false }
            }
        }
        return true
    }

    private static func rowMatches(_ lhs: RowSignature, _ rhs: RowSignature, tolerant: Bool) -> Bool {
        // 快路径：像素级相同（非平滑滚动时绝大多数帧走这里）
        if lhs == rhs { return true }
        guard tolerant, lhs.count == rhs.count else { return false }

        let allowedBlocks = max(2, lhs.count / 8)
        var badBlocks = 0
        for index in 0..<lhs.count {
            let difference = abs(Int(lhs[index]) - Int(rhs[index]))
            if difference > blockDifferenceThreshold {
                badBlocks += 1
                if badBlocks > allowedBlocks { return false }
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

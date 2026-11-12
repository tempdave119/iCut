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
    private var signatures: [RollingStitcher.RowSignature] = []
    /// 上一次成功的粘性头部行数，下次优先按它搜
    private var lastSkipRows = 0

    init(maxHeight: Int = 20000) {
        self.maxHeight = maxHeight
    }

    func append(_ image: CGImage) -> AppendResult {
        let incoming = RollingStitcher.rowSignatures(of: image)
        guard !incoming.isEmpty else { return .unchanged("无法读取画面") }

        guard width > 0 else {
            width = image.width
            strips = [image]
            signatures = incoming
            height = incoming.count
            return .appended(addedRows: incoming.count)
        }

        // 抓屏回图偶尔比首帧差 1~2px（窗口边缘、缩放取整）；严格相等会让会话永久卡在「画面尺寸变化」
        guard abs(image.width - width) <= 2 else { return .unchanged("画面尺寸变化") }
        // 已到上限就不必再花时间匹配，直接短路
        let remaining = maxHeight - height
        guard remaining > 0 else { return .unchanged("已达高度上限") }

        guard let match = RollingStitcher.findOverlap(
            existing: signatures,
            incoming: incoming,
            minOverlap: minOverlap,
            preferredSkip: lastSkipRows
        ) else {
            return .unchanged("未找到重叠区域")
        }

        // skipRows 是页面粘性头部（每帧都在、不随滚动移动），只保留一份，不重复拼进去
        let added = incoming.count - match.skipRows - match.overlapRows
        guard added > 0 else { return .unchanged("画面未滚动") }

        // 超出上限时裁到剩余容量，不整帧丢弃，否则长图永远差最后一段
        let take = min(added, remaining)
        let stripStart = match.skipRows + match.overlapRows
        guard let strip = detachedStrip(
            from: image,
            rect: CGRect(x: 0, y: stripStart, width: min(width, image.width), height: take)
        ) else {
            return .unchanged("裁切失败")
        }

        strips.append(strip)
        // 签名必须与高度同步：超出上限时只追加实际裁进来的行
        signatures.append(contentsOf: incoming[stripStart..<(stripStart + take)])
        lastSkipRows = match.skipRows
        height += take
        return .appended(addedRows: take)
    }

    /// 裁切后复制到独立位图：CGImage.cropping 与源帧共享数据，直接保存会拖住整帧，
    /// 慢速滚动到高度上限时可能累积大量整屏帧。
    private func detachedStrip(from image: CGImage, rect: CGRect) -> CGImage? {
        guard let cropped = image.cropping(to: rect) else { return nil }
        let width = cropped.width
        let height = cropped.height
        guard width > 0, height > 0 else { return nil }
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
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

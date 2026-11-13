import AppKit

/// 在 flipped 坐标系（原点左上）中绘制标注。视图预览与导出渲染共用这一套绘制，
/// 差异只在 offset/scale/mosaicSourceScale 三个变换参数上。
enum AnnotationPainter {
    static let baseLineWidth: CGFloat = 3
    static let baseFontSize: CGFloat = 16

    /// - Parameters:
    ///   - offset: 坐标平移（导出时传选区原点）
    ///   - scale: 坐标与线宽缩放（导出时传 backingScaleFactor）
    ///   - mosaicSource: 马赛克取样源图（冻结帧或裁切基准图）
    ///   - mosaicSourceScale: 视图坐标 → 源图像素的缩放
    static func draw(
        _ annotation: Annotation,
        offset: CGPoint,
        scale: CGFloat,
        mosaicSource: CGImage?,
        mosaicSourceScale: CGFloat
    ) {
        let points = annotation.points.map {
            CGPoint(x: ($0.x - offset.x) * scale, y: ($0.y - offset.y) * scale)
        }
        let lineWidth = baseLineWidth * scale
        let accent = annotation.color.nsColor

        switch annotation.kind {
        case .rectangle:
            guard points.count >= 2 else { return }
            let path = NSBezierPath(rect: normalized(points[0], points[1]))
            path.lineWidth = lineWidth
            accent.setStroke()
            path.stroke()

        case .ellipse:
            guard points.count >= 2 else { return }
            let path = NSBezierPath(ovalIn: normalized(points[0], points[1]))
            path.lineWidth = lineWidth
            accent.setStroke()
            path.stroke()

        case .line:
            guard points.count >= 2 else { return }
            let path = NSBezierPath()
            path.move(to: points[0])
            path.line(to: points[1])
            path.lineWidth = lineWidth
            path.lineCapStyle = .round
            accent.setStroke()
            path.stroke()

        case .arrow:
            guard points.count >= 2 else { return }
            drawArrow(from: points[0], to: points[1], lineWidth: lineWidth, color: accent)

        case .freehand:
            guard points.count >= 2 else { return }
            let path = NSBezierPath()
            path.move(to: points[0])
            for point in points.dropFirst() {
                path.line(to: point)
            }
            path.lineWidth = lineWidth
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            accent.setStroke()
            path.stroke()

        case .text:
            guard let text = annotation.text, !text.isEmpty, let origin = points.first else { return }
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: baseFontSize * scale, weight: .semibold),
                .foregroundColor: accent,
                .strokeColor: contrastColor(against: accent),
                .strokeWidth: -3.0
            ]
            text.draw(at: origin, withAttributes: attributes)

        case .mosaic:
            guard points.count >= 2 else { return }
            drawMosaic(
                in: normalized(points[0], points[1]),
                scale: scale,
                source: mosaicSource,
                sourceScale: mosaicSourceScale
            )

        case .number:
            guard let point = points.first, let number = annotation.number else { return }
            drawNumber(number, at: point, scale: scale, color: accent)
        }
    }

    // MARK: - 细节绘制

    /// 文字描边用对比色，避免深色字配深色背景糊成一片
    private static func contrastColor(against color: NSColor) -> NSColor {
        guard let rgb = color.usingColorSpace(.deviceRGB) else { return .white }
        let luminance = 0.299 * rgb.redComponent + 0.587 * rgb.greenComponent + 0.114 * rgb.blueComponent
        return luminance > 0.6 ? .black : .white
    }

    private static func normalized(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(
            x: min(a.x, b.x),
            y: min(a.y, b.y),
            width: abs(a.x - b.x),
            height: abs(a.y - b.y)
        )
    }

    private static func drawArrow(from start: CGPoint, to end: CGPoint, lineWidth: CGFloat, color: NSColor) {
        let path = NSBezierPath()
        path.move(to: start)
        path.line(to: end)
        path.lineWidth = lineWidth
        path.lineCapStyle = .round
        color.setStroke()
        path.stroke()

        let angle = atan2(end.y - start.y, end.x - start.x)
        let headLength = max(lineWidth * 4, 10)
        let headAngle: CGFloat = .pi / 7
        let left = CGPoint(
            x: end.x - headLength * cos(angle - headAngle),
            y: end.y - headLength * sin(angle - headAngle)
        )
        let right = CGPoint(
            x: end.x - headLength * cos(angle + headAngle),
            y: end.y - headLength * sin(angle + headAngle)
        )
        let head = NSBezierPath()
        head.move(to: end)
        head.line(to: left)
        head.line(to: right)
        head.close()
        color.setFill()
        head.fill()
    }

    private static func drawNumber(_ number: Int, at point: CGPoint, scale: CGFloat, color: NSColor) {
        let radius: CGFloat = 11 * scale
        let circle = CGRect(
            x: point.x - radius,
            y: point.y - radius,
            width: radius * 2,
            height: radius * 2
        )
        color.setFill()
        NSBezierPath(ovalIn: circle).fill()

        let text = "\(number)"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13 * scale, weight: .bold),
            .foregroundColor: contrastColor(against: color)
        ]
        let size = text.size(withAttributes: attributes)
        text.draw(
            at: CGPoint(x: point.x - size.width / 2, y: point.y - size.height / 2),
            withAttributes: attributes
        )
    }

    private static func drawMosaic(
        in rect: CGRect,
        scale: CGFloat,
        source: CGImage?,
        sourceScale: CGFloat
    ) {
        guard let source, rect.width >= 2, rect.height >= 2, scale > 0 else { return }

        // 取样源与绘制坐标共用同一原点（预览用整屏帧、导出用裁切图），只做缩放换算；
        // 叠加选区偏移会取到源图范围之外，导致导出时整块马赛克丢失
        let sourceRect = CGRect(
            x: rect.minX / scale * sourceScale,
            y: rect.minY / scale * sourceScale,
            width: rect.width / scale * sourceScale,
            height: rect.height / scale * sourceScale
        ).integral
        guard let cropped = source.cropping(to: sourceRect) else { return }

        // 缩小再放大实现像素化，块大小随缩放调整
        let block = max(2, Int(10 * scale))
        let smallWidth = max(1, Int(rect.width) / block)
        let smallHeight = max(1, Int(rect.height) / block)
        guard let smallContext = CGContext(
            data: nil,
            width: smallWidth,
            height: smallHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return
        }
        smallContext.interpolationQuality = .none
        smallContext.draw(cropped, in: CGRect(x: 0, y: 0, width: smallWidth, height: smallHeight))
        guard let smallImage = smallContext.makeImage() else { return }

        NSGraphicsContext.current?.imageInterpolation = .none
        NSImage(cgImage: smallImage, size: rect.size).draw(in: rect)
    }
}

import AppKit

enum AnnotationRenderer {
    /// 把标注渲染进裁切后的图像；无标注时直接返回原图。
    static func render(
        base: CGImage,
        annotations: [Annotation],
        selectionOrigin: CGPoint,
        scale: CGFloat
    ) -> CGImage {
        guard !annotations.isEmpty else { return base }

        guard let context = CGContext(
            data: nil,
            width: base.width,
            height: base.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return base
        }

        context.draw(base, in: CGRect(x: 0, y: 0, width: base.width, height: base.height))

        // CGContext 原点在左下，标注坐标是视图坐标（原点左上）。必须真正翻转 CTM：
        // 只把 NSGraphicsContext 标成 flipped 会让标注整体上下镜像、文字倒置
        context.saveGState()
        context.translateBy(x: 0, y: CGFloat(base.height))
        context.scaleBy(x: 1, y: -1)

        // 用 flipped 上下文复用视图那套绘制代码
        let graphicsContext = NSGraphicsContext(cgContext: context, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphicsContext
        for annotation in annotations {
            AnnotationPainter.draw(
                annotation,
                offset: selectionOrigin,
                scale: scale,
                mosaicSource: base,
                mosaicSourceScale: scale
            )
        }
        NSGraphicsContext.restoreGraphicsState()
        context.restoreGState()

        return context.makeImage() ?? base
    }
}

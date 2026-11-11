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

        return context.makeImage() ?? base
    }
}

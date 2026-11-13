import AppKit

/// AnnotationRenderer 的输出必须与视图预览同向：标注坐标原点在左上，
/// 文字与序号不能上下镜像，马赛克不能因选区偏移而丢失。
func runAnnotationRendererTests() {
    // 取样辅助自校验：基准图顶部蓝条必须落在 raster 的前几行
    let base = makeRenderTestBase(width: 120, height: 120)
    let baseRaster = renderTestRaster(base)
    expect(isBluePixel(renderTestPixel(baseRaster, width: 120, x: 10, y: 1)), "取样辅助：第 1 行应是顶部蓝条")
    expect(isWhitePixel(renderTestPixel(baseRaster, width: 120, x: 10, y: 118)), "取样辅助：末行应是底部白底")

    // 序号是实心圆：视图坐标 (60,20) 应落在图像上部，镜像时会跑到下部
    let marker = Annotation(kind: .number, points: [CGPoint(x: 60, y: 20)], number: 1, color: .green)
    let marked = AnnotationRenderer.render(base: base, annotations: [marker], selectionOrigin: .zero, scale: 1)
    let markedRaster = renderTestRaster(marked)
    expect(isGreenPixel(renderTestPixel(markedRaster, width: 120, x: 52, y: 20)), "序号标注应出现在视图坐标对应的上方位置")
    expect(!isGreenPixel(renderTestPixel(markedRaster, width: 120, x: 52, y: 100)), "序号标注不应上下镜像到图像下方")

    // 选区偏移：视图坐标 (120,20) - 选区原点 (100,0) = 裁切图内 (20,20)
    let croppedBase = makeRenderTestBase(width: 60, height: 60)
    let offsetMarker = Annotation(kind: .number, points: [CGPoint(x: 120, y: 20)], number: 1, color: .green)
    let offsetImage = AnnotationRenderer.render(
        base: croppedBase,
        annotations: [offsetMarker],
        selectionOrigin: CGPoint(x: 100, y: 0),
        scale: 1
    )
    let offsetRaster = renderTestRaster(offsetImage)
    expect(isGreenPixel(renderTestPixel(offsetRaster, width: 60, x: 12, y: 20)), "选区偏移应正确映射到裁切图坐标")

    // 文字不能上下翻转：L 的横笔在字形下半部，翻转后计数互换
    let textBase = makeRenderTestBase(width: 240, height: 200)
    let textAnnotation = Annotation(kind: .text, points: [CGPoint(x: 20, y: 20)], text: "L", color: .red)
    let textImage = AnnotationRenderer.render(base: textBase, annotations: [textAnnotation], selectionOrigin: .zero, scale: 3)
    let textHalves = renderTestRedHalves(renderTestRaster(textImage), width: textImage.width, height: textImage.height)
    expect(textHalves.upper > 0 && textHalves.lower > 0, "文字应渲染出红色像素")
    expect(textHalves.lower > textHalves.upper, "文字不能上下镜像：L 的横笔应位于字形下半部")

    // 马赛克：选区偏移非零时仍按裁切图坐标取样（旧实现取到源图外，整块不绘制）
    let stripedBase = makeRenderTestStripes(width: 60, height: 60)
    let mosaic = Annotation(kind: .mosaic, points: [CGPoint(x: 110, y: 10), CGPoint(x: 150, y: 40)], color: .black)
    let mosaicImage = AnnotationRenderer.render(
        base: stripedBase,
        annotations: [mosaic],
        selectionOrigin: CGPoint(x: 100, y: 0),
        scale: 1
    )
    let mosaicRaster = renderTestRaster(mosaicImage)
    let blockA = renderTestPixel(mosaicRaster, width: 60, x: 12, y: 15)
    let blockB = renderTestPixel(mosaicRaster, width: 60, x: 17, y: 15)
    expectEqual(blockA, blockB, "马赛克块内像素应一致")
    let outsideA = renderTestPixel(mosaicRaster, width: 60, x: 5, y: 15)
    let outsideB = renderTestPixel(mosaicRaster, width: 60, x: 6, y: 15)
    expect(outsideA != outsideB, "马赛克不应覆盖标注范围以外的像素")
}

// MARK: - 取样辅助

private struct RenderTestPixel: Equatable {
    let r: Int
    let g: Int
    let b: Int
}

/// 白底 + 顶部 4px 蓝条，用于确认取样行序与上下方向
private func makeRenderTestBase(width: Int, height: Int) -> CGImage {
    let context = makeRenderTestContext(width: width, height: height)
    context.setFillColor(NSColor.white.cgColor)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.setFillColor(NSColor.systemBlue.cgColor)
    context.fill(CGRect(x: 0, y: height - 4, width: width, height: 4))
    return context.makeImage()!
}

/// 白底 + 每 2px 一条 1px 黑竖纹，马赛克块内取同色、块外保留条纹
private func makeRenderTestStripes(width: Int, height: Int) -> CGImage {
    let context = makeRenderTestContext(width: width, height: height)
    context.setFillColor(NSColor.white.cgColor)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.setFillColor(NSColor.black.cgColor)
    for x in stride(from: 0, to: width, by: 2) {
        context.fill(CGRect(x: x, y: 0, width: 1, height: height))
    }
    return context.makeImage()!
}

private func makeRenderTestContext(width: Int, height: Int) -> CGContext {
    guard let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        fatalError("测试位图上下文创建失败")
    }
    return context
}

/// 把图像重绘到同尺寸 RGBA 位图，便于按「行 0 = 图像顶部」取像素
private func renderTestRaster(_ image: CGImage) -> [UInt8] {
    let width = image.width
    let height = image.height
    var data = [UInt8](repeating: 0, count: width * height * 4)
    data.withUnsafeMutableBytes { buffer in
        guard let context = CGContext(
            data: buffer.baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }
    return data
}

private func renderTestPixel(_ raster: [UInt8], width: Int, x: Int, y: Int) -> RenderTestPixel {
    let index = (y * width + x) * 4
    return RenderTestPixel(
        r: Int(raster[index]),
        g: Int(raster[index + 1]),
        b: Int(raster[index + 2])
    )
}

private func isBluePixel(_ pixel: RenderTestPixel) -> Bool {
    pixel.b > 150 && pixel.r < 100
}

private func isWhitePixel(_ pixel: RenderTestPixel) -> Bool {
    pixel.r > 245 && pixel.g > 245 && pixel.b > 245
}

private func isGreenPixel(_ pixel: RenderTestPixel) -> Bool {
    pixel.g > 120 && pixel.g > pixel.r + 40 && pixel.g > pixel.b + 40
}

/// 统计字形包围盒内上半部与下半部的红色像素数
private func renderTestRedHalves(_ raster: [UInt8], width: Int, height: Int) -> (upper: Int, lower: Int) {
    var minX = width
    var maxX = -1
    var minY = height
    var maxY = -1
    for y in 0..<height {
        for x in 0..<width {
            let pixel = renderTestPixel(raster, width: width, x: x, y: y)
            if isRedPixel(pixel) {
                minX = min(minX, x)
                maxX = max(maxX, x)
                minY = min(minY, y)
                maxY = max(maxY, y)
            }
        }
    }
    guard maxX >= minX else { return (0, 0) }

    let midY = (minY + maxY) / 2
    var upper = 0
    var lower = 0
    for y in minY...maxY {
        for x in minX...maxX where isRedPixel(renderTestPixel(raster, width: width, x: x, y: y)) {
            if y <= midY {
                upper += 1
            } else {
                lower += 1
            }
        }
    }
    return (upper, lower)
}

private func isRedPixel(_ pixel: RenderTestPixel) -> Bool {
    pixel.r > 150 && pixel.g < 120 && pixel.b < 120
}

import AppKit
import CoreGraphics
import ImageIO

// 应用图标源图生成器：绘制 1024x1024 的圆角方块 + 虚线选框 + 贴图纸片。
// 用法：swiftc -O scripts/make-icon.swift -o build/make-icon && ./build/make-icon assets/app-icon-1024.png
// 改配色或形状后重新生成源图，再用 iconutil 转出 resources/iCut.icns。

let size = 1024
let canvas = CGFloat(size)

guard let context = CGContext(
    data: nil,
    width: size,
    height: size,
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    fatalError("无法创建绘图上下文")
}

func cgColor(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: r, green: g, blue: b, alpha: a)
}

context.setFillColor(cgColor(1, 1, 1))
context.fill(CGRect(x: 0, y: 0, width: canvas, height: canvas))

// 圆角方块主体
let inset: CGFloat = 64
let body = CGRect(x: inset, y: inset, width: canvas - inset * 2, height: canvas - inset * 2)
let bodyPath = CGPath(roundedRect: body, cornerWidth: 224, cornerHeight: 224, transform: nil)

context.saveGState()
context.addPath(bodyPath)
context.clip()

if let gradient = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [cgColor(0.13, 0.14, 0.40), cgColor(0.44, 0.29, 0.88)] as CFArray,
    locations: [0, 1]
) {
    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: body.minX, y: body.maxY),
        end: CGPoint(x: body.maxX, y: body.minY),
        options: []
    )
}

// 中心微亮，让选框区域与背景有层次
if let innerGlow = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [cgColor(1, 1, 1, 0.10), cgColor(1, 1, 1, 0)] as CFArray,
    locations: [0, 1]
) {
    context.drawRadialGradient(
        innerGlow,
        startCenter: CGPoint(x: canvas * 0.5, y: canvas * 0.55),
        startRadius: 0,
        endCenter: CGPoint(x: canvas * 0.5, y: canvas * 0.55),
        endRadius: canvas * 0.5,
        options: []
    )
}
context.restoreGState()

// 选框：CoreGraphics 原点在左下，按视觉位置换算 y
let selectionVisualTop: CGFloat = 232
let selectionSide: CGFloat = 500
let selection = CGRect(
    x: 262,
    y: canvas - selectionVisualTop - selectionSide,
    width: selectionSide,
    height: selectionSide
)

context.saveGState()
context.setStrokeColor(cgColor(1, 1, 1, 0.96))
context.setLineWidth(15)
context.setLineDash(phase: 0, lengths: [36, 24])
context.stroke(selection)
context.restoreGState()

// 四角手柄
let handleSide: CGFloat = 46
for corner in [
    CGPoint(x: selection.minX, y: selection.minY),
    CGPoint(x: selection.maxX, y: selection.minY),
    CGPoint(x: selection.minX, y: selection.maxY),
    CGPoint(x: selection.maxX, y: selection.maxY)
] {
    let rect = CGRect(
        x: corner.x - handleSide / 2,
        y: corner.y - handleSide / 2,
        width: handleSide,
        height: handleSide
    )
    context.setFillColor(cgColor(1, 1, 1))
    context.addPath(CGPath(roundedRect: rect, cornerWidth: 11, cornerHeight: 11, transform: nil))
    context.fillPath()
}

// 右下角贴图纸片
let cardVisualTop: CGFloat = 566
let cardWidth: CGFloat = 236
let cardHeight: CGFloat = 190
let card = CGRect(
    x: 616,
    y: canvas - cardVisualTop - cardHeight,
    width: cardWidth,
    height: cardHeight
)

context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: -10), blur: 26, color: cgColor(0, 0, 0, 0.28))
context.setFillColor(cgColor(1, 1, 1))
context.addPath(CGPath(roundedRect: card, cornerWidth: 26, cornerHeight: 26, transform: nil))
context.fillPath()
context.restoreGState()

context.saveGState()
context.addPath(CGPath(roundedRect: card, cornerWidth: 26, cornerHeight: 26, transform: nil))
context.clip()
context.setFillColor(cgColor(0.30, 0.55, 1.0))
context.fill(CGRect(x: card.minX, y: card.maxY - 30, width: card.width, height: 30))
context.restoreGState()

// 卡片内的内容示意
context.setFillColor(cgColor(0.85, 0.86, 0.90))
context.fill(CGRect(x: card.minX + 28, y: card.midY + 6, width: card.width - 56, height: 14))
context.fill(CGRect(x: card.minX + 28, y: card.midY - 22, width: card.width - 100, height: 14))

guard let image = context.makeImage() else {
    fatalError("生成图像失败")
}

let outputPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "app-icon-1024.png"
guard let destination = CGImageDestinationCreateWithURL(
    URL(fileURLWithPath: outputPath) as CFURL,
    "public.png" as CFString,
    1,
    nil
) else {
    fatalError("无法写入 \(outputPath)")
}
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else {
    fatalError("写入 PNG 失败")
}
print("已生成 \(outputPath)")

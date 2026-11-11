import AppKit
import CoreGraphics
import ImageIO

// 图标生成器：产出应用图标源图与菜单栏模板图标。
// 用法：swiftc -O scripts/make-icon.swift -o build/make-icon && ./build/make-icon assets/app-icon-1024.png
// 随后用 iconutil 把 app-icon-1024.png 转成 resources/iCut.icns。

let size = 1024
let canvas = CGFloat(size)

func cgColor(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: r, green: g, blue: b, alpha: a)
}

func writePNG(_ context: CGContext, to path: String) {
    guard let image = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(
              URL(fileURLWithPath: path) as CFURL,
              "public.png" as CFString,
              1,
              nil
          ) else {
        fatalError("无法写入 \(path)")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        fatalError("写入 PNG 失败：\(path)")
    }
}

// MARK: - 应用图标

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

// 四周留 100px 透明边距，圆角块内容区 824x824，与系统应用图标的视觉重量一致
let inset: CGFloat = 100
let contentScale = (canvas - inset * 2) / canvas

context.saveGState()
context.translateBy(x: inset, y: inset)
context.scaleBy(x: contentScale, y: contentScale)

let body = CGRect(x: 0, y: 0, width: canvas, height: canvas)
// 缩放后圆角约 185，符合 macOS 图标比例
let bodyPath = CGPath(roundedRect: body, cornerWidth: 230, cornerHeight: 230, transform: nil)

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

// 选框
let selection = CGRect(x: 226, y: canvas - 192 - 571, width: 571, height: 571)

context.saveGState()
context.setStrokeColor(cgColor(1, 1, 1, 0.96))
context.setLineWidth(17)
context.setLineDash(phase: 0, lengths: [41, 27])
context.stroke(selection)
context.restoreGState()

// 四角手柄
let handleSide: CGFloat = 53
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
    context.addPath(CGPath(roundedRect: rect, cornerWidth: 13, cornerHeight: 13, transform: nil))
    context.fillPath()
}

// 右下角贴图纸片
let card = CGRect(x: 631, y: canvas - 574 - 217, width: 270, height: 217)

context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: -11), blur: 30, color: cgColor(0, 0, 0, 0.28))
context.setFillColor(cgColor(1, 1, 1))
context.addPath(CGPath(roundedRect: card, cornerWidth: 30, cornerHeight: 30, transform: nil))
context.fillPath()
context.restoreGState()

context.saveGState()
context.addPath(CGPath(roundedRect: card, cornerWidth: 30, cornerHeight: 30, transform: nil))
context.clip()
context.setFillColor(cgColor(0.30, 0.55, 1.0))
context.fill(CGRect(x: card.minX, y: card.maxY - 34, width: card.width, height: 34))
context.restoreGState()

context.setFillColor(cgColor(0.85, 0.86, 0.90))
context.fill(CGRect(x: card.minX + 32, y: card.midY + 7, width: card.width - 64, height: 16))
context.fill(CGRect(x: card.minX + 32, y: card.midY - 25, width: card.width - 114, height: 16))

context.restoreGState()

let outputPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "app-icon-1024.png"
writePNG(context, to: outputPath)
print("已生成 \(outputPath)")

// MARK: - 菜单栏模板图标

/// 菜单栏图标用纯黑 alpha 的模板图，系统会按深浅色菜单栏自动着色。
func writeMenuBarIcon(side: CGFloat, scale: CGFloat, path: String) {
    let pixels = Int(side * scale)
    guard let menuContext = CGContext(
        data: nil,
        width: pixels,
        height: pixels,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        fatalError("无法创建菜单栏图标上下文")
    }
    menuContext.scaleBy(x: scale, y: scale)

    let frame = CGRect(x: 3.2, y: 3.2, width: side - 6.4, height: side - 6.4)
    menuContext.setStrokeColor(cgColor(0, 0, 0))
    menuContext.setLineWidth(1.4)
    menuContext.stroke(frame)

    let dot: CGFloat = 2.8
    for corner in [
        CGPoint(x: frame.minX, y: frame.minY),
        CGPoint(x: frame.maxX, y: frame.minY),
        CGPoint(x: frame.minX, y: frame.maxY),
        CGPoint(x: frame.maxX, y: frame.maxY)
    ] {
        menuContext.setFillColor(cgColor(0, 0, 0))
        menuContext.fill(CGRect(x: corner.x - dot / 2, y: corner.y - dot / 2, width: dot, height: dot))
    }

    writePNG(menuContext, to: path)
    print("已生成 \(path)")
}

writeMenuBarIcon(side: 18, scale: 1, path: "resources/MenuBarIcon.png")
writeMenuBarIcon(side: 18, scale: 2, path: "resources/MenuBarIcon@2x.png")

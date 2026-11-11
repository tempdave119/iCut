import AppKit
import CoreGraphics

/// AutoSaver 的行为约定：开关关闭时不落盘、不建目录；开启后按模板写 PNG 并自动避让重名。
func runAutoSaverTests() {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("iCutTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    guard let image = makeTestImage() else {
        expect(false, "构造测试图像失败")
        return
    }

    var settings = AutoSaveSettings(enabled: false, directoryPath: directory.path, nameTemplate: "shot")
    expect(AutoSaver.saveIfEnabled(image: image, scale: 1, settings: settings) == nil, "关闭时不保存")
    expect(!FileManager.default.fileExists(atPath: directory.path), "关闭时不应创建目录")

    settings.enabled = true
    let first = AutoSaver.saveIfEnabled(image: image, scale: 1, settings: settings)
    expectEqual(first?.lastPathComponent, "shot.png", "首次保存按模板命名")

    let second = AutoSaver.saveIfEnabled(image: image, scale: 1, settings: settings)
    expectEqual(second?.lastPathComponent, "shot-2.png", "重名时追加序号，不覆盖旧文件")

    let third = AutoSaver.saveIfEnabled(image: image, scale: 1, settings: settings)
    expectEqual(third?.lastPathComponent, "shot-3.png", "继续追加序号")

    // 不可写目录只报错不崩溃：/dev/null 下无法建目录
    let unwritable = AutoSaveSettings(
        enabled: true,
        directoryPath: "/dev/null/iCutUnwritable",
        nameTemplate: "shot"
    )
    expect(AutoSaver.saveIfEnabled(image: image, scale: 1, settings: unwritable) == nil, "目录不可创建时返回 nil")
}

private func makeTestImage() -> CGImage? {
    guard let context = CGContext(
        data: nil,
        width: 4,
        height: 4,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        return nil
    }
    context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
    return context.makeImage()
}

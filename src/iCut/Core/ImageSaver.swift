import AppKit
import UniformTypeIdentifiers

enum ImageSaver {
    private static let lastDirectoryKey = "save.lastDirectory"

    /// 弹保存面板并写入 PNG；取消或失败返回 nil。
    /// 面板是模态的，调用前先把应用激活，否则面板会藏在别的窗口后面。
    @discardableResult
    static func savePNG(image: CGImage, scale: CGFloat, defaultName: String) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = defaultName
        panel.canCreateDirectories = true
        if let directory = lastDirectoryURL() {
            panel.directoryURL = directory
        }

        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return nil }

        guard let data = pngData(from: image, scale: scale) else {
            NSLog("iCut: PNG 编码失败")
            return nil
        }

        do {
            try data.write(to: url)
            UserDefaults.standard.set(url.deletingLastPathComponent().path, forKey: lastDirectoryKey)
            return url
        } catch {
            NSLog("iCut: 保存失败 \(error.localizedDescription)")
            return nil
        }
    }

    /// 默认文件名带时间戳，避免连续截图互相覆盖
    static func defaultFileName(date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return "iCut \(formatter.string(from: date)).png"
    }

    private static func lastDirectoryURL() -> URL? {
        guard let path = UserDefaults.standard.string(forKey: lastDirectoryKey) else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private static func pngData(from image: CGImage, scale: CGFloat) -> Data? {
        let rep = NSBitmapImageRep(cgImage: image)
        rep.size = NSSize(
            width: CGFloat(image.width) / scale,
            height: CGFloat(image.height) / scale
        )
        return rep.representation(using: .png, properties: [:])
    }
}

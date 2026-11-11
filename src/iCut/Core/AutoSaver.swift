import AppKit

/// 自动保存：只在设置开启时把确认后的图写到用户指定目录。
/// 任何失败都不能影响截图主流程（剪贴板已经写入），因此这里只记日志 + 首次失败弹一次提示。
enum AutoSaver {
    private static var didReportFailure = false

    @discardableResult
    static func saveIfEnabled(image: CGImage, scale: CGFloat, settings: AutoSaveSettings = .load()) -> URL? {
        guard settings.enabled else { return nil }

        let directory = settings.directoryURL
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            reportFailure(reason: "无法创建目录 \(directory.path)：\(error.localizedDescription)")
            return nil
        }

        guard let data = ImageSaver.pngData(from: image, scale: scale) else {
            reportFailure(reason: "PNG 编码失败")
            return nil
        }

        let url = uniqueURL(in: directory, template: settings.nameTemplate)
        do {
            try data.write(to: url)
            NSLog("iCut: 已自动保存到 \(url.path)")
            return url
        } catch {
            reportFailure(reason: "写入 \(url.path) 失败：\(error.localizedDescription)")
            return nil
        }
    }

    /// 同一秒内连续截图会撞名，追加 -2、-3 而不是覆盖上一张
    private static func uniqueURL(in directory: URL, template: String) -> URL {
        let base = FileNameTemplate.render(template: template)
        var candidate = directory.appendingPathComponent(base + ".png")
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(base)-\(index).png")
            index += 1
        }
        return candidate
    }

    private static func reportFailure(reason: String) {
        NSLog("iCut: 自动保存失败 — \(reason)")
        // 每进程只弹一次：目录坏掉时连续截图不应连续弹窗
        guard !didReportFailure else { return }
        didReportFailure = true
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "自动保存失败"
            alert.informativeText = "\(reason)\n\n截图已复制到剪贴板；可在「设置 → 自动保存」检查目录与命名模板。"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "好")
            alert.runModal()
        }
    }
}

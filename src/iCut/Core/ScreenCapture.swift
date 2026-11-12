import AppKit
import CoreGraphics

/// 单屏冻结帧。坐标为 AppKit 全局坐标（原点在主屏左下角），像素尺寸由 scale 决定。
struct DisplayFrame {
    let displayID: CGDirectDisplayID
    let screenFrame: CGRect
    /// Quartz 全局坐标（原点主屏左上），用于窗口命中测试
    let quartzFrame: CGRect
    let backingScaleFactor: CGFloat
    let image: CGImage
}

enum ScreenCapturePermission {
    /// 只查询、不触发系统弹窗
    static var isGranted: Bool { CGPreflightScreenCaptureAccess() }

    /// 首次调用会弹系统授权对话框，此时必然返回 false；用户勾选后需重启应用才生效
    @discardableResult
    static func request() -> Bool {
        // 菜单栏应用默认不在前台，不激活的话系统对话框可能不显示
        NSApp.activate(ignoringOtherApps: true)
        return CGRequestScreenCaptureAccess()
    }

    static func openSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        NSWorkspace.shared.open(url)
    }
}

/// 抓屏能力的抽象：macOS 13 用 CGWindowListCreateImage，macOS 14+ 可替换为 ScreenCaptureKit 实现。
protocol ScreenCapturing {
    /// 逐屏抓取冻结帧。任一屏失败即整体返回空数组，避免上层拿到残缺的屏幕集合。
    func captureAllScreens() -> [DisplayFrame]

    /// 抓取屏幕上的一块区域（Quartz 全局坐标，点）。
    func captureRegion(_ rectInQuartz: CGRect, belowWindow windowID: CGWindowID) -> CGImage?
}

/// macOS 13 的抓屏实现；F-28 在 macOS 14+ SDK 下换 ScreenCaptureKit 实现即可。
struct LegacyScreenCapturer: ScreenCapturing {
    /// 逐屏抓取冻结帧。任一屏失败即整体返回空数组，避免上层拿到残缺的屏幕集合。
    ///
    /// 不用一次抓全屏再裁切：多屏 scale 不一致时，整图会被统一渲染，各屏像素尺寸就对不上了。
    func captureAllScreens() -> [DisplayFrame] {
        let screens = NSScreen.screens
        guard let primary = screens.first else { return [] }
        let primaryHeight = primary.frame.height

        var frames: [DisplayFrame] = []
        for screen in screens {
            // 抓屏 API 只认 Quartz 全局坐标（原点在主屏左上），需从 AppKit 坐标翻转 y
            let quartzRect = ScreenGeometry.quartzRect(fromAppKit: screen.frame, primaryHeight: primaryHeight)
            guard let image = CGWindowListCreateImage(quartzRect, .optionOnScreenOnly, kCGNullWindowID, [.bestResolution]) else {
                NSLog("iCut: 抓取屏幕 \(screen.localizedName) 失败")
                return []
            }
            guard !isBlank(image) else {
                NSLog("iCut: 抓取屏幕 \(screen.localizedName) 得到空图/纯色画面")
                return []
            }
            let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
            frames.append(
                DisplayFrame(
                    displayID: displayID,
                    screenFrame: screen.frame,
                    quartzFrame: quartzRect,
                    backingScaleFactor: screen.backingScaleFactor,
                    image: image
                )
            )
        }
        return frames
    }

    /// 抓取屏幕上的一块区域（Quartz 全局坐标，点）；
    /// belowWindow 传长截图控制条的窗口号，可以把控制条排除在画面外。
    func captureRegion(_ rectInQuartz: CGRect, belowWindow windowID: CGWindowID = 0) -> CGImage? {
        if windowID != 0 {
            return CGWindowListCreateImage(rectInQuartz, .optionOnScreenBelowWindow, windowID, [.bestResolution])
        }
        return CGWindowListCreateImage(rectInQuartz, .optionOnScreenOnly, kCGNullWindowID, [.bestResolution])
    }

    /// 抓屏返回纯黑/纯白且几乎没有亮度差异时判定异常，避免权限异常时静默生成错误截图
    private func isBlank(_ image: CGImage) -> Bool {
        let size = 8
        guard let context = CGContext(
            data: nil,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: size * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
        guard let data = context.data else { return false }
        let bytes = data.bindMemory(to: UInt8.self, capacity: size * size * 4)
        var minLuminance = 255
        var maxLuminance = 0
        for index in 0..<(size * size) {
            let offset = index * 4
            let luminance = (Int(bytes[offset]) * 77
                + Int(bytes[offset + 1]) * 150
                + Int(bytes[offset + 2]) * 29) >> 8
            minLuminance = min(minLuminance, luminance)
            maxLuminance = max(maxLuminance, luminance)
        }
        return maxLuminance - minLuminance <= 2 && (maxLuminance <= 8 || minLuminance >= 247)
    }
}

/// 对上层的稳定入口；F-28 迁移时把 capturer 换成 ScreenCaptureKit 实现。
enum ScreenCapture {
    static var capturer: ScreenCapturing = LegacyScreenCapturer()

    static func captureAllScreens() -> [DisplayFrame] {
        capturer.captureAllScreens()
    }

    static func captureRegion(_ rectInQuartz: CGRect, belowWindow windowID: CGWindowID = 0) -> CGImage? {
        capturer.captureRegion(rectInQuartz, belowWindow: windowID)
    }
}

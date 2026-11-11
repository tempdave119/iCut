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

enum ScreenCapture {
    /// 逐屏抓取冻结帧。任一屏失败即整体返回空数组，避免上层拿到残缺的屏幕集合。
    ///
    /// 不用一次抓全屏再裁切：多屏 scale 不一致时，整图会被统一渲染，各屏像素尺寸就对不上了。
    static func captureAllScreens() -> [DisplayFrame] {
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
}

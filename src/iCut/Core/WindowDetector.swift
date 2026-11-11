import Foundation
import CoreGraphics

/// 光标下的顶层普通窗口（Quartz 全局坐标）
struct DetectedWindow {
    let windowID: CGWindowID
    let bounds: CGRect
    let ownerName: String
}

enum WindowDetector {
    /// 按 z-order 从上往下找第一个包含该点的普通窗口。
    /// 只取 layer == 0 的普通窗口，排除 Dock、菜单栏、悬浮面板等系统层。
    static func window(at quartzPoint: CGPoint, excludingPID pid: pid_t) -> DetectedWindow? {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return nil
        }

        for info in list {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t, ownerPID != pid else { continue }
            guard let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict) else { continue }
            // 过滤掉零尺寸与不可见窗口
            guard bounds.width >= 2, bounds.height >= 2 else { continue }

            if bounds.contains(quartzPoint) {
                let windowID = info[kCGWindowNumber as String] as? CGWindowID ?? 0
                let owner = info[kCGWindowOwnerName as String] as? String ?? ""
                return DetectedWindow(windowID: windowID, bounds: bounds, ownerName: owner)
            }
        }
        return nil
    }
}

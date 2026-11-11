import Foundation
import ServiceManagement

/// 开机自启：把主应用登记为系统登录项。
/// 用 macOS 13 的 SMAppService.mainApp，不需要额外 helper bundle，也不需要改系统文件。
enum LaunchAtLogin {
    enum State: Equatable {
        case enabled
        case disabled
        /// 已登记但用户在系统设置里没有允许，需要引导去「登录项」里打开
        case requiresApproval
    }

    static var status: State {
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        // 实测 macOS 13 上“从未登记过”也报 .notFound，与“当前形态不支持”无法区分，按未开启处理；
        // 真正不支持时 register() 会抛错，由调用方提示
        case .notRegistered, .notFound: return .disabled
        @unknown default: return .disabled
        }
    }

    /// 注册或注销登录项；失败时把原始错误抛给调用方提示，不静默吞掉。
    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    static func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

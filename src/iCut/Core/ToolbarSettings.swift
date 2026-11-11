import Foundation

/// 截图工具栏的位置策略
enum ToolbarPosition: String, CaseIterable {
    /// 贴选区下方，空间不足时自动翻到上方
    case followSelection
    /// 固定在屏幕底部居中
    case fixedBottom

    var displayName: String {
        switch self {
        case .followSelection: return "跟随选区"
        case .fixedBottom: return "固定底部"
        }
    }
}

enum ToolbarSettings {
    private static let key = "toolbar.position"

    static func load() -> ToolbarPosition {
        guard let raw = UserDefaults.standard.string(forKey: key),
              let position = ToolbarPosition(rawValue: raw) else {
            return .followSelection
        }
        return position
    }

    static func save(_ position: ToolbarPosition) {
        UserDefaults.standard.set(position.rawValue, forKey: key)
    }
}

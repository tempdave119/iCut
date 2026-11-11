import Foundation

/// 一次性迁移：bundle id 从 com.kevin.icut 改为 com.icut.app 后，
/// 把旧 domain 里的快捷键与工具栏配置搬过来，避免用户重设。
enum SettingsMigration {
    private static let legacyBundleID = "com.kevin.icut"
    private static let markerKey = "migration.fromComKevinIcut"
    private static let carriedKeys = [
        "hotkey.keyCode",
        "hotkey.modifiers",
        "hotkey.displayText",
        "toolbar.position",
        "save.lastDirectory"
    ]

    /// 必须在创建 AppDelegate 之前调用：HotKeyStore.load() 在对象初始化时就读取配置
    static func runIfNeeded() {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: markerKey) == nil else { return }
        defaults.set(true, forKey: markerKey)

        guard let legacy = UserDefaults(suiteName: legacyBundleID) else { return }
        for key in carriedKeys where defaults.object(forKey: key) == nil {
            if let value = legacy.object(forKey: key) {
                defaults.set(value, forKey: key)
            }
        }
    }
}

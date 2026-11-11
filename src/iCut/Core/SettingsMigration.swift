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
    private static let templateMarkerKey = "migration.autoSaveTemplateV2"
    private static let legacyAutoSaveTemplate = "iCut {date} {time}"

    /// 必须在创建 AppDelegate 之前调用：HotKeyStore.load() 在对象初始化时就读取配置
    static func runIfNeeded() {
        migrateBundleIdentityIfNeeded()
        migrateAutoSaveTemplateIfNeeded()
    }

    private static func migrateBundleIdentityIfNeeded() {
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

    /// 自动保存默认命名从 `iCut {date} {time}` 改为 `iCut-{timestamp}`；
    /// 只迁移“等于旧默认值”的配置，用户自己改过的模板保持原样。
    private static func migrateAutoSaveTemplateIfNeeded() {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: templateMarkerKey) == nil else { return }
        defaults.set(true, forKey: templateMarkerKey)

        let templateKey = "autosave.nameTemplate"
        guard let stored = defaults.string(forKey: templateKey),
              stored.trimmingCharacters(in: .whitespacesAndNewlines) == legacyAutoSaveTemplate else {
            return
        }
        defaults.set(FileNameTemplate.defaultTemplate, forKey: templateKey)
    }
}

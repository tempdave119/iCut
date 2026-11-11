import Foundation

/// SettingsMigration 的行为约定：旧默认命名模板迁到新默认，用户自定义的模板保持原样。
func runSettingsMigrationTests() {
    let defaults = UserDefaults.standard
    let templateKey = "autosave.nameTemplate"
    let markerKey = "migration.autoSaveTemplateV2"

    defaults.removeObject(forKey: markerKey)
    defaults.set("iCut {date} {time}", forKey: templateKey)
    SettingsMigration.runIfNeeded()
    expectEqual(
        defaults.string(forKey: templateKey),
        FileNameTemplate.defaultTemplate,
        "旧默认模板迁移为新默认"
    )

    defaults.removeObject(forKey: markerKey)
    defaults.set("my-shot-{seq}", forKey: templateKey)
    SettingsMigration.runIfNeeded()
    expectEqual(defaults.string(forKey: templateKey), "my-shot-{seq}", "自定义模板不被迁移覆盖")

    defaults.removeObject(forKey: templateKey)
    defaults.removeObject(forKey: markerKey)
}

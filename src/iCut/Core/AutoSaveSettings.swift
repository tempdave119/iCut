import Foundation

/// 自动保存配置：默认关闭；开启后每次「确认」截图都会按模板往指定目录落一份 PNG。
struct AutoSaveSettings {
    var enabled: Bool
    var directoryPath: String
    var nameTemplate: String

    private enum Keys {
        static let enabled = "autosave.enabled"
        static let directory = "autosave.directory"
        static let template = "autosave.nameTemplate"
    }

    static let `default` = AutoSaveSettings(
        enabled: false,
        directoryPath: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Pictures/iCut", isDirectory: true).path,
        nameTemplate: FileNameTemplate.defaultTemplate
    )

    var directoryURL: URL {
        URL(fileURLWithPath: directoryPath, isDirectory: true)
    }

    static func load() -> AutoSaveSettings {
        let defaults = UserDefaults.standard
        let fallback = AutoSaveSettings.default
        let directory = defaults.string(forKey: Keys.directory) ?? ""
        let template = defaults.string(forKey: Keys.template) ?? ""
        return AutoSaveSettings(
            enabled: defaults.bool(forKey: Keys.enabled),
            directoryPath: directory.isEmpty ? fallback.directoryPath : directory,
            nameTemplate: template.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? fallback.nameTemplate
                : template
        )
    }

    static func save(_ settings: AutoSaveSettings) {
        let defaults = UserDefaults.standard
        defaults.set(settings.enabled, forKey: Keys.enabled)
        defaults.set(settings.directoryPath, forKey: Keys.directory)
        defaults.set(settings.nameTemplate, forKey: Keys.template)
    }
}

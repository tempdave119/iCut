import Foundation

/// 剪贴板历史配置：默认关闭；关闭时完全不采集、不读钥匙串、不碰数据目录。
struct ClipboardSettings {
    var enabled: Bool
    var recordImages: Bool
    /// 非图片条目的上限；图片不设张数，只受容量预算约束。
    var maxEntries: Int
    var imageBudgetMB: Int
    /// 0 表示永久保留。
    var retentionDays: Int
    /// 复制后是否保持面板打开；面板内勾选与设置页共用同一项。
    var keepPanelOpen: Bool
    var hotKey: HotKeyConfig

    static let maxEntriesChoices = [100, 200, 500]
    static let imageBudgetChoices = [100, 200, 500]
    static let retentionChoices = [1, 7, 30, 0]

    private enum Keys {
        static let enabled = "clipboard.enabled"
        static let recordImages = "clipboard.recordImages"
        static let maxEntries = "clipboard.maxEntries"
        static let imageBudgetMB = "clipboard.imageBudgetMB"
        static let retentionDays = "clipboard.retentionDays"
        static let keepPanelOpen = "clipboard.keepPanelOpen"
    }

    static let `default` = ClipboardSettings(
        enabled: false,
        recordImages: true,
        maxEntries: 200,
        imageBudgetMB: 200,
        retentionDays: 7,
        keepPanelOpen: false,
        hotKey: .clipboardDefault
    )

    var imageBudgetBytes: Int { imageBudgetMB * 1024 * 1024 }

    /// nil 表示永久保留。
    var retentionInterval: TimeInterval? {
        retentionDays > 0 ? TimeInterval(retentionDays) * 86_400 : nil
    }

    static func load() -> ClipboardSettings {
        let defaults = UserDefaults.standard
        let fallback = ClipboardSettings.default
        let entries = defaults.object(forKey: Keys.maxEntries) as? Int ?? fallback.maxEntries
        let budget = defaults.object(forKey: Keys.imageBudgetMB) as? Int ?? fallback.imageBudgetMB
        let retention = defaults.object(forKey: Keys.retentionDays) as? Int ?? fallback.retentionDays
        // recordImages 默认 true，不能用 bool(forKey:) 判断「是否设置过」
        let images = defaults.object(forKey: Keys.recordImages) == nil
            ? fallback.recordImages
            : defaults.bool(forKey: Keys.recordImages)

        return ClipboardSettings(
            enabled: defaults.bool(forKey: Keys.enabled),
            recordImages: images,
            maxEntries: maxEntriesChoices.contains(entries) ? entries : fallback.maxEntries,
            imageBudgetMB: imageBudgetChoices.contains(budget) ? budget : fallback.imageBudgetMB,
            retentionDays: retentionChoices.contains(retention) ? retention : fallback.retentionDays,
            keepPanelOpen: defaults.bool(forKey: Keys.keepPanelOpen),
            hotKey: HotKeyStore.load(.clipboard)
        )
    }

    static func save(_ settings: ClipboardSettings) {
        let defaults = UserDefaults.standard
        defaults.set(settings.enabled, forKey: Keys.enabled)
        defaults.set(settings.recordImages, forKey: Keys.recordImages)
        defaults.set(settings.maxEntries, forKey: Keys.maxEntries)
        defaults.set(settings.imageBudgetMB, forKey: Keys.imageBudgetMB)
        defaults.set(settings.retentionDays, forKey: Keys.retentionDays)
        defaults.set(settings.keepPanelOpen, forKey: Keys.keepPanelOpen)
        // 热键由录制流程单独保存，这里不写回，避免用旧值覆盖新组合
    }
}

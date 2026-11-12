import AppKit

/// 剪贴板历史的编排层：配置、采集、面板与回填。
/// AppDelegate 只负责装配与菜单入口，具体流程都在这里。
final class ClipboardController {
    /// 钥匙串不可用时通知外部（弹一次说明），记录保持暂停，不降级为明文。
    var onEncryptionUnavailable: (() -> Void)?
    var onOpenSettings: (() -> Void)?

    private var settings: ClipboardSettings
    private var store: ClipboardStore?
    private let watcher = PasteboardWatcher()
    private let panel = ClipboardPanel()
    private var storageFullNotified = false

    init() {
        settings = ClipboardSettings.load()

        panel.onCopy = { [weak self] item, keepOpen in
            self?.copy(item, keepOpen: keepOpen) ?? false
        }
        panel.onDelete = { [weak self] item in self?.delete(item) }
        panel.onTogglePin = { [weak self] item in self?.togglePin(item) }
        panel.onClearAll = { [weak self] in self?.confirmClearAll() }
        panel.onKeepOpenChanged = { [weak self] enabled in
            guard let self else { return }
            self.settings.keepPanelOpen = enabled
            ClipboardSettings.save(self.settings)
        }
    }

    deinit {
        watcher.stop()
        store?.saveNow()
    }

    var isEnabled: Bool { settings.enabled }

    func startIfEnabled() {
        guard settings.enabled else { return }
        start()
    }

    /// 设置面板改动后调用：开关、图片开关、上限与保留期都从这里生效。
    func apply(_ newSettings: ClipboardSettings) {
        let wasEnabled = settings.enabled
        settings = newSettings

        if !newSettings.enabled {
            stop()
            return
        }
        start()
        panel.syncKeepOpen(settings.keepPanelOpen)
        if wasEnabled { refreshPanel() }
    }

    func show() {
        guard settings.enabled, let store else {
            presentNotEnabledAlert()
            return
        }
        panel.syncKeepOpen(settings.keepPanelOpen)
        panel.present(items: store.allItems(), storageFull: store.isStorageFull)
        panel.showPanel()
    }

    /// 设置面板「清空历史」入口：二次确认后清空并刷新面板。
    func clearWithConfirmation() {
        confirmClearAll()
    }

    /// 退出前把防抖窗口里的变更落盘。
    func persistNow() {
        store?.saveNow()
    }

    // MARK: - 生命周期

    private func start() {
        if store == nil {
            do {
                let store = try ClipboardStore()
                store.onSelfWrite = { [weak self] in
                    // 回填后把变化抑制掉，避免历史里多出一条自己写的重复内容
                    DispatchQueue.main.async { self?.watcher.noteSelfWrite() }
                }
                store.onStorageFull = { [weak self] in
                    DispatchQueue.main.async { self?.notifyStorageFull() }
                }
                self.store = store
            } catch {
                NSLog("iCut: 剪贴板历史加密不可用，记录已暂停 — \(error)")
                onEncryptionUnavailable?()
                return
            }
        }
        guard let store else { return }

        store.configure(
            retention: settings.retentionInterval,
            maxEntries: settings.maxEntries,
            imageBudgetBytes: settings.imageBudgetBytes
        )
        watcher.start(recordImages: settings.recordImages) { [weak self] snapshot in
            self?.store?.append(snapshot)
        }
        NSLog("iCut: 剪贴板历史已启动（图片=\(settings.recordImages ? "记录" : "关闭")）")
    }

    private func stop() {
        watcher.stop()
        store?.saveNow()
        store = nil
        panel.hidePanel()
        NSLog("iCut: 剪贴板历史已停止")
    }

    // MARK: - 面板动作

    private func copy(_ item: ClipboardStore.ClipItem, keepOpen: Bool) -> Bool {
        guard let store else { return false }
        guard store.writeBack(item) else {
            // 写回失败时面板不关闭，用户可以直接重试
            NSSound.beep()
            NSLog("iCut: 剪贴板历史回填失败")
            return false
        }
        if !keepOpen {
            panel.hidePanel()
        }
        return true
    }

    private func delete(_ item: ClipboardStore.ClipItem) {
        store?.delete(id: item.id)
        refreshPanel()
    }

    private func togglePin(_ item: ClipboardStore.ClipItem) {
        store?.setPinned(id: item.id, pinned: !item.isPinned)
        refreshPanel()
    }

    private func refreshPanel() {
        guard panel.isVisible, let store else { return }
        panel.present(items: store.allItems(), storageFull: store.isStorageFull)
    }

    private func confirmClearAll() {
        guard let store else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "清空剪贴板记录？"
        alert.informativeText = "所有记录与图片将被永久删除，无法恢复。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "清空")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let removed = store.count
        store.clearAll()
        refreshPanel()
        NSLog("iCut: 剪贴板历史已清空 \(removed) 条")
    }

    private func notifyStorageFull() {
        guard !storageFullNotified else { return }
        storageFullNotified = true
        NSLog("iCut: 剪贴板历史图片预算已被收藏占满，暂停记录新图片")
    }

    private func presentNotEnabledAlert() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "剪贴板未开启"
        alert.informativeText = "到「设置 → 剪贴板」打开后才会记录复制内容。"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "打开设置")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn {
            onOpenSettings?()
        }
    }
}

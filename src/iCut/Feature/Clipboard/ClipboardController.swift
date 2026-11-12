import AppKit
import ImageIO

/// 剪贴板历史的编排层：配置、采集、面板与回填。
/// AppDelegate 只负责装配与菜单入口，具体流程都在这里。
final class ClipboardController {
    /// 钥匙串不可用时通知外部（弹一次说明），记录保持暂停，不降级为明文。
    var onEncryptionUnavailable: (() -> Void)?
    /// 索引与备份都无法读取时通知外部提示“历史损坏”
    var onIndexCorrupted: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    /// 图片条目的跨模块联动：贴图 / 识别文字 / 保存，由 AppDelegate 注入。
    var onPinImage: ((CGImage, CGFloat, CGPoint) -> Void)?
    var onOCRImage: ((CGImage) -> Void)?
    var onSaveImage: ((CGImage, CGFloat) -> Void)?

    private var settings: ClipboardSettings
    private var store: ClipboardStore?
    private let watcher = PasteboardWatcher()
    private let panel = ClipboardPanel()
    private var storageFullNotified = false
    /// 截图写入剪贴板后记录预期 changeCount，下一帧命中同一计数才标记为截图。
    private let captureMarkLock = NSLock()
    private var captureMark = CaptureMark()

    init() {
        settings = ClipboardSettings.load()

        panel.onCopy = { [weak self] item, keepOpen in
            self?.copy(item, keepOpen: keepOpen) ?? false
        }
        panel.onDelete = { [weak self] item in self?.delete(item) }
        panel.onTogglePin = { [weak self] item in self?.togglePin(item) }
        panel.onClearAll = { [weak self] in self?.confirmClearAll() }
        panel.onClearUnpinned = { [weak self] in self?.confirmClearUnpinned() }
        panel.onPin = { [weak self] item in self?.pin(item) }
        panel.onOCR = { [weak self] item in self?.recognize(item) }
        panel.onSave = { [weak self] item in self?.save(item) }
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
        guard settings.enabled else {
            presentNotEnabledAlert()
            return
        }
        guard let store else {
            presentEncryptionUnavailableAlert()
            return
        }
        panel.syncKeepOpen(settings.keepPanelOpen)
        // 过期条目在展示前先清掉，避免列表里还挂着「已过期」
        store.pruneNow()
        panel.present(
            items: store.allItems(),
            storageFull: store.isStorageFull,
            retention: settings.retentionInterval
        )
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

    /// 钥匙串可用后重试：清掉缓存密钥并重新建 store。
    func retryEncryption() {
        guard settings.enabled, store == nil else { return }
        ClipboardCrypto.resetCache()
        start()
    }

    /// 重建密钥：先二次确认，成功后清空旧历史并重新启动采集。
    func rebuildKeyWithConfirmation() {
        guard settings.enabled else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "重建剪贴板历史密钥？"
        alert.informativeText = "会删除当前主密钥和全部历史（索引与图片），无法恢复。仅在钥匙串异常或历史损坏时使用。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "重建并清空")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        rebuildKey()
    }

    private func rebuildKey() {
        watcher.stop()
        store?.saveNow()
        store = nil
        guard ClipboardCrypto.regenerateKey() != nil else {
            onEncryptionUnavailable?()
            return
        }
        do {
            let store = try ClipboardStore()
            store.resetAllData()
            self.store = store
            start()
        } catch {
            NSLog("iCut: 重建剪贴板主密钥失败 — \(error)")
            onEncryptionUnavailable?()
        }
    }

    // MARK: - 生命周期

    private func start() {
        if store == nil {
            do {
                let store = try ClipboardStore()
                store.onSelfWrite = { [weak self] in
                    // 写剪贴板与记录预期计数必须同步，避免 0.3 秒轮询先看到变化
                    self?.watcher.noteSelfWrite()
                }
                store.onStorageFull = { [weak self] in
                    DispatchQueue.main.async { self?.notifyStorageFull() }
                }
                self.store = store
                if store.indexCorrupted { onIndexCorrupted?() }
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
        // 后台解析队列直接持有当前 store，避免与主线程 stop() 置 nil 竞争
        let storeRef = store
        watcher.start(recordImages: settings.recordImages) { [weak self] snapshot, changeCount in
            guard let self else { return }
            let isCapture = self.consumeCaptureMark(changeCount: changeCount)
            storeRef.append(snapshot, isFromCapture: isCapture)
            // 面板打开时后台采集也要出现在列表里，但不打断当前选中行
            DispatchQueue.main.async { [weak self] in self?.refreshPanel(selectFirst: false) }
        }
        NSLog("iCut: 剪贴板历史已启动（图片=\(settings.recordImages ? "记录" : "关闭")）")
    }

    private func stop() {
        watcher.stop()
        captureMarkLock.lock()
        captureMark.reset()
        captureMarkLock.unlock()
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

    /// 截图确认与长截图完成后调用：标记下一次采集为截图来源。
    func noteCaptureCopy() {
        // 历史关闭时 watcher 不运行，不留下标记，避免开启后误标第一条内容
        guard settings.enabled else { return }
        captureMarkLock.lock()
        captureMark.note(changeCount: watcher.currentChangeCount)
        captureMarkLock.unlock()
    }

    private func consumeCaptureMark(changeCount: Int) -> Bool {
        captureMarkLock.lock()
        defer { captureMarkLock.unlock() }
        return captureMark.consume(changeCount: changeCount)
    }

    private func pin(_ item: ClipboardStore.ClipItem) {
        imagePayload(item) { [weak self] payload in
            guard let self, let payload else { return }
            self.onPinImage?(payload.image, payload.scale, NSEvent.mouseLocation)
        }
    }

    private func recognize(_ item: ClipboardStore.ClipItem) {
        guard let onOCRImage else { return }
        // OCR 窗口出现时面板会失去 key，窗口关闭前不要自动收起
        beginExternalPanelHold()
        imagePayload(item) { [weak self] payload in
            guard let self else { return }
            guard let payload else {
                self.endExternalPanelHold()
                return
            }
            onOCRImage(payload.image)
        }
    }

    private func save(_ item: ClipboardStore.ClipItem) {
        // 保存面板会让面板失去 key，临时跳过自动收起，保存完成后恢复
        beginExternalPanelHold()
        imagePayload(item) { [weak self] payload in
            guard let self else { return }
            defer { self.endExternalPanelHold() }
            guard let payload else { return }
            self.onSaveImage?(payload.image, payload.scale)
        }
    }

    /// 保存面板、OCR 结果窗口等外部窗口出现时暂停面板自动收起
    func beginExternalPanelHold() {
        panel.setAlertPresented(true)
    }

    func endExternalPanelHold() {
        panel.setAlertPresented(false)
    }

    /// 解密与图片解码放后台，完成后回主线程；20MB 图片不再阻塞面板操作
    private func imagePayload(
        _ item: ClipboardStore.ClipItem,
        completion: @escaping ((image: CGImage, scale: CGFloat)?) -> Void
    ) {
        guard item.kind == .image, let store else {
            completion(nil)
            return
        }
        let scale = CGFloat(item.imageScale ?? 1)
        DispatchQueue.global(qos: .userInitiated).async {
            guard let data = store.imageData(for: item),
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            DispatchQueue.main.async { completion((image, scale)) }
        }
    }

    private func refreshPanel(selectFirst: Bool = true) {
        guard panel.isVisible, let store else { return }
        panel.present(
            items: store.allItems(),
            storageFull: store.isStorageFull,
            retention: settings.retentionInterval,
            selectFirst: selectFirst
        )
    }

    private func confirmClearAll() {
        guard let store else { return }
        let wasVisible = panel.isVisible
        panel.setAlertPresented(true)
        defer {
            panel.setAlertPresented(false)
            if wasVisible { panel.showPanel() }
        }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "清空剪贴板记录？"
        alert.informativeText = "所有记录与图片将被永久删除，无法恢复。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "清空")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let removed = store.count
        // 大量图片密文删除放后台，避免清空时主线程卡顿
        DispatchQueue.global(qos: .utility).async {
            store.clearAll()
            DispatchQueue.main.async {
                self.refreshPanel()
                NSLog("iCut: 剪贴板历史已清空 \(removed) 条")
            }
        }
    }

    /// 面板底部「清除」：只删未永久保留的记录，收藏原样保留。
    private func confirmClearUnpinned() {
        guard let store else { return }
        let wasVisible = panel.isVisible
        panel.setAlertPresented(true)
        defer {
            panel.setAlertPresented(false)
            if wasVisible { panel.showPanel() }
        }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "清除未永久保留的记录？"
        alert.informativeText = "未永久保留的文本、图片与文件记录将被删除，标记为永久保留的记录不会动。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "清除")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        // 大量图片密文删除放后台，避免清空时主线程卡顿
        DispatchQueue.global(qos: .utility).async {
            let removed = store.clearUnpinned()
            DispatchQueue.main.async {
                self.refreshPanel()
                NSLog("iCut: 剪贴板已清除未收藏记录 \(removed) 条")
            }
        }
    }

    private func notifyStorageFull() {
        guard !storageFullNotified else { return }
        storageFullNotified = true
        NSLog("iCut: 图片存储预算已满，暂停记录新图片")
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

    private func presentEncryptionUnavailableAlert() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "剪贴板历史加密不可用"
        alert.informativeText = "无法读取钥匙串中的主密钥，记录已暂停（不会降级为明文）。请退出并重新打开 iCut 重试。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "好")
        alert.runModal()
    }
}

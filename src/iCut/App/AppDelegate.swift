import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var captureMenuItem: NSMenuItem?
    private var shortcutMenuItem: NSMenuItem?
    private let hotKeyCenter = HotKeyCenter()
    private var shortcutWindow: ShortcutRecorderWindow?
    private var activeConfig = HotKeyStore.load()

    func applicationDidFinishLaunching(_ notification: Notification) {
        setUpStatusItem()
        registerActiveHotKey()
    }

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        // SF Symbols 在目标系统上缺失时回退为文字，保证入口始终可见
        item.button?.image = NSImage(systemSymbolName: "crop", accessibilityDescription: "iCut")
        item.button?.title = item.button?.image == nil ? "iCut" : ""

        let menu = NSMenu()
        let captureItem = NSMenuItem(title: "", action: #selector(startCapture), keyEquivalent: "")
        captureItem.target = self
        menu.addItem(captureItem)
        captureMenuItem = captureItem

        let shortcutItem = NSMenuItem(title: "", action: #selector(openShortcutSettings), keyEquivalent: "")
        shortcutItem.target = self
        menu.addItem(shortcutItem)
        shortcutMenuItem = shortcutItem

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出 iCut", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        item.menu = menu
        statusItem = item
        updateMenuTitles()
    }

    private func updateMenuTitles() {
        captureMenuItem?.title = "截图（\(activeConfig.displayText)）"
        shortcutMenuItem?.title = "设置快捷键…（当前 \(activeConfig.displayText)）"
    }

    private func registerActiveHotKey() {
        let handler: () -> Void = { [weak self] in self?.startCapture() }
        if hotKeyCenter.register(activeConfig, onTrigger: handler) {
            NSLog("iCut: 已注册全局快捷键 \(activeConfig.displayText)")
            return
        }

        // 保存的组合可能被别的应用占走，回落到默认组合，避免启动后完全唤不起
        let previous = activeConfig.displayText
        if activeConfig != .default, hotKeyCenter.register(.default, onTrigger: handler) {
            activeConfig = .default
            HotKeyStore.save(.default)
            updateMenuTitles()
            presentAlert(
                title: "原快捷键不可用",
                message: "\(previous) 已被其它应用占用，已临时改用 \(activeConfig.displayText)。可在菜单中重新设置。"
            )
            return
        }

        updateMenuTitles()
        presentAlert(
            title: "快捷键注册失败",
            message: "\(previous) 已被其它应用占用。请从菜单「设置快捷键…」换一个组合。"
        )
    }

    private func presentAlert(title: String, message: String) {
        // launch 阶段同步 runModal 会把启动流程堵住，菜单栏应用会表现为“点了没反应”
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = message
            alert.alertStyle = .warning
            alert.addButton(withTitle: "好")
            alert.runModal()
        }
    }

    @objc private func openShortcutSettings() {
        if let window = shortcutWindow {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        // 录制期间注销全局热键，否则按下旧组合会直接触发截图
        hotKeyCenter.unregister()

        let window = ShortcutRecorderWindow(current: activeConfig)
        var accepted = false

        window.onKeyDown = { [weak self, weak window] event in
            guard let self, let window else { return }
            let modifiers = HotKeyStore.carbonModifiers(from: event.modifierFlags)
            guard modifiers != 0 else {
                NSSound.beep()
                window.showMessage("必须包含至少一个修饰键（⌘ ⌥ ⌃ ⇧）")
                return
            }

            let config = HotKeyConfig(
                keyCode: UInt32(event.keyCode),
                carbonModifiers: modifiers,
                displayText: HotKeyStore.displayText(for: event)
            )
            let handler: () -> Void = { [weak self] in self?.startCapture() }

            // 先试注册再落盘：注册不上的组合不能写进 UserDefaults
            if self.hotKeyCenter.register(config, onTrigger: handler) {
                HotKeyStore.save(config)
                self.activeConfig = config
                self.updateMenuTitles()
                accepted = true
                NSLog("iCut: 快捷键已更新为 \(config.displayText)")
                window.close()
            } else {
                NSSound.beep()
                window.showMessage("\(config.displayText) 已被其它应用占用，请换一个组合")
            }
        }

        window.onClose = { [weak self] in
            guard let self else { return }
            // 取消或异常关闭时把原来的快捷键恢复回来
            if !accepted, !self.hotKeyCenter.isRegistered {
                self.registerActiveHotKey()
            }
            self.shortcutWindow = nil
        }

        shortcutWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    // 截图流程：权限 → 逐屏抓取 → （F-05 接入覆盖层）
    @objc private func startCapture() {
        guard ScreenCapturePermission.isGranted else {
            handleMissingPermission()
            return
        }

        let frames = ScreenCapture.captureAllScreens()
        guard !frames.isEmpty else {
            presentAlert(title: "截图失败", message: "未能抓取屏幕画面。请确认「屏幕录制」权限已勾选，并重启 iCut 后重试。")
            return
        }

        let detail = frames
            .map { "\(Int($0.screenFrame.width))x\(Int($0.screenFrame.height))pt@\($0.backingScaleFactor)x→\($0.image.width)x\($0.image.height)px" }
            .joined(separator: " | ")
        NSLog("iCut: 抓到 \(frames.count) 屏：\(detail)")
    }

    /// 首次交给系统弹窗；之后再触发就直接给出去设置的入口，避免重复弹框
    private func handleMissingPermission() {
        let requestedKey = "permission.screenCapture.requested"
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: requestedKey) {
            presentPermissionAlert()
            return
        }
        defaults.set(true, forKey: requestedKey)
        _ = ScreenCapturePermission.request()
    }

    private func presentPermissionAlert() {
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "需要「屏幕录制」权限"
            alert.informativeText = "请在系统设置 → 隐私与安全性 → 屏幕录制中勾选 iCut，然后重新启动应用。"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "打开系统设置")
            alert.addButton(withTitle: "稍后")
            if alert.runModal() == .alertFirstButtonReturn {
                ScreenCapturePermission.openSettings()
            }
        }
    }
}

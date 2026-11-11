import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var captureMenuItem: NSMenuItem?
    private var shortcutMenuItem: NSMenuItem?
    private let hotKeyCenter = HotKeyCenter()
    private var shortcutWindow: ShortcutRecorderWindow?
    private var activeConfig = HotKeyStore.load()
    private let selectionController = SelectionOverlayController()
    private let pinController = PinController()
    /// 每次启动最多向系统发起一次授权请求，避免反复触发系统弹框
    private var permissionRequestedThisLaunch = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        setUpStatusItem()
        registerActiveHotKey()
        NSLog("iCut: 屏幕录制权限 = \(ScreenCapturePermission.isGranted)")
    }

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        // 优先用自有模板图标，系统会按菜单栏深浅色自动着色；缺失时回退到 SF Symbol
        if let menuBarIcon = NSImage(named: "MenuBarIcon") {
            menuBarIcon.isTemplate = true
            item.button?.image = menuBarIcon
        } else if let symbol = NSImage(systemSymbolName: "crop", accessibilityDescription: "iCut") {
            item.button?.image = symbol
        } else {
            item.button?.title = "iCut"
        }

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

    // 截图流程：幂等检查 → 权限 → 抓屏 → 覆盖层框选
    @objc private func startCapture() {
        guard !selectionController.isActive else {
            NSLog("iCut: 已有截图会话进行中，忽略本次触发")
            return
        }
        guard ScreenCapturePermission.isGranted else {
            handleMissingPermission()
            return
        }
        // 从菜单触发时菜单还在屏幕上，延后一拍再抓，避免菜单被截进冻结帧
        DispatchQueue.main.async { [weak self] in
            self?.performCapture()
        }
    }

    private func performCapture() {
        guard !selectionController.isActive else { return }

        // 已有贴图不能进冻结帧，否则会把自己也截进去
        pinController.hideAllForCapture()

        let frames = ScreenCapture.captureAllScreens()
        guard !frames.isEmpty else {
            pinController.restoreAfterCapture()
            presentAlert(title: "截图失败", message: "未能抓取屏幕画面。请确认「屏幕录制」权限已勾选，并重启 iCut 后重试。")
            return
        }

        selectionController.begin(frames: frames) { [weak self] selection in
            guard let self else { return }
            self.pinController.restoreAfterCapture()

            guard let selection else {
                NSLog("iCut: 截图已取消")
                return
            }

            let copied = ClipboardService.copy(
                image: selection.image,
                scale: selection.frame.backingScaleFactor
            )
            self.pinController.pin(
                image: selection.image,
                scale: selection.frame.backingScaleFactor,
                origin: Self.pinOrigin(for: selection)
            )
            NSLog(
                "iCut: 选区 \(Int(selection.rectInScreen.width))x\(Int(selection.rectInScreen.height))pt → \(selection.image.width)x\(selection.image.height)px，剪贴板\(copied ? "已写入" : "写入失败")，贴图 \(self.pinController.count) 张"
            )
        }
    }

    /// 选区是屏内左上原点坐标，贴图窗口需要左下原点的全局坐标
    private static func pinOrigin(for selection: SelectionOverlayController.CaptureSelection) -> CGPoint {
        let screenFrame = selection.frame.screenFrame
        let height = CGFloat(selection.image.height) / selection.frame.backingScaleFactor
        return CGPoint(
            x: screenFrame.minX + selection.rectInScreen.minX,
            y: screenFrame.maxY - selection.rectInScreen.minY - height
        )
    }

    /// 首次触发只让系统登记（用户看到系统框），再次触发才弹自有引导，避免两个窗口叠在一起
    private func handleMissingPermission() {
        NSLog("iCut: 触发时权限检查未通过")
        if !permissionRequestedThisLaunch {
            permissionRequestedThisLaunch = true
            _ = ScreenCapturePermission.request()
            return
        }
        presentPermissionAlert()
    }

    private func presentPermissionAlert() {
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "需要「屏幕录制」权限"
            alert.informativeText = "请到「系统设置 → 隐私与安全性 → 屏幕录制」：\n1. 若 iCut 已在列表中，先取消勾选\n2. 再重新勾选\n3. 退出并重新打开 iCut\n\n开发版每次重新构建后签名会变化，系统会当成新应用，需要重新授权。"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "打开系统设置")
            alert.addButton(withTitle: "稍后")
            if alert.runModal() == .alertFirstButtonReturn {
                ScreenCapturePermission.openSettings()
            }
        }
    }
}

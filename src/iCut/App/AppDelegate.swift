import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setUpStatusItem()
    }

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        // SF Symbols 在目标系统上缺失时回退为文字，保证入口始终可见
        item.button?.image = NSImage(systemSymbolName: "crop", accessibilityDescription: "iCut")
        item.button?.title = item.button?.image == nil ? "iCut" : ""

        let menu = NSMenu()
        let captureItem = NSMenuItem(title: "截图", action: #selector(startCapture), keyEquivalent: "")
        captureItem.target = self
        menu.addItem(captureItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出 iCut", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        item.menu = menu
        statusItem = item
    }

    // 截图流程在 F-02 / F-05 接入，这里先保证菜单入口可达
    @objc private func startCapture() {
        NSLog("iCut: 截图流程尚未接入")
    }
}

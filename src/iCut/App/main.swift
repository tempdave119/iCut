import AppKit

// 必须在创建 AppDelegate 之前：它会在初始化时读取快捷键配置
SettingsMigration.runIfNeeded()

let application = NSApplication.shared
let appDelegate = AppDelegate()
application.delegate = appDelegate
// 纯菜单栏应用：不进入 Dock，也不抢占前台应用的焦点
application.setActivationPolicy(.accessory)
application.run()

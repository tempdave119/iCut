import AppKit

let application = NSApplication.shared
let appDelegate = AppDelegate()
application.delegate = appDelegate
// 纯菜单栏应用：不进入 Dock，也不抢占前台应用的焦点
application.setActivationPolicy(.accessory)
application.run()

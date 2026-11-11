import AppKit

// 必须在创建 AppDelegate 之前：它会在初始化时读取快捷键配置
SettingsMigration.runIfNeeded()

// 同一个 bundle id 已有进程在跑时直接退出：两套实例会重复注册全局热键，菜单栏也会出现两个图标
if let bundleID = Bundle.main.bundleIdentifier {
    let currentPID = ProcessInfo.processInfo.processIdentifier
    if let other = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        .first(where: { $0.processIdentifier != currentPID }) {
        NSLog("iCut: 已有实例在运行（PID \(other.processIdentifier)），本次启动退出")
        exit(0)
    }
}

let application = NSApplication.shared
let appDelegate = AppDelegate()
application.delegate = appDelegate
// 纯菜单栏应用：不进入 Dock，也不抢占前台应用的焦点
application.setActivationPolicy(.accessory)
application.run()

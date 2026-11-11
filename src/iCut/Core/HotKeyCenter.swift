import AppKit
import Carbon

/// Carbon 全局热键封装：同一个实例负责注销旧热键、注册新热键，供「设置快捷键」反复调用。
final class HotKeyCenter {
    private var eventHandler: EventHandlerRef?
    private var hotKeyRef: EventHotKeyRef?
    private var onTrigger: (() -> Void)?

    var isRegistered: Bool { hotKeyRef != nil }

    deinit {
        unregister()
        if let handler = eventHandler {
            RemoveEventHandler(handler)
        }
    }

    /// 注册成功返回 true；组合被其它应用占用时返回 false，且不保留任何热键。
    @discardableResult
    func register(_ config: HotKeyConfig, onTrigger: @escaping () -> Void) -> Bool {
        unregister()
        self.onTrigger = onTrigger
        installHandlerIfNeeded()

        let hotKeyID = EventHotKeyID(signature: OSType(0x6943_7574), id: 1) // 'iCut'
        let status = RegisterEventHotKey(
            config.keyCode,
            config.carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        guard status == noErr else {
            hotKeyRef = nil
            return false
        }
        return true
    }

    func unregister() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
    }

    private func installHandlerIfNeeded() {
        guard eventHandler == nil else { return }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        // C 回调不能捕获上下文，实例通过 userData 传回
        let userData = Unmanaged.passUnretained(self).toOpaque()
        _ = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData in
                guard let userData else { return OSStatus(eventNotHandledErr) }
                let center = Unmanaged<HotKeyCenter>.fromOpaque(userData).takeUnretainedValue()
                center.onTrigger?()
                return noErr
            },
            1,
            &eventType,
            userData,
            &eventHandler
        )
    }
}

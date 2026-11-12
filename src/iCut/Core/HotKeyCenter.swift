import AppKit
import Carbon

/// Carbon 全局热键封装：同一个实例负责注销旧热键、注册新热键，供「设置快捷键」反复调用。
final class HotKeyCenter {
    static let captureID: UInt32 = 1
    static let clipboardID: UInt32 = 2

    private var eventHandler: EventHandlerRef?
    private var registrations: [UInt32: (ref: EventHotKeyRef, handler: () -> Void)] = [:]

    var isRegistered: Bool { registrations[Self.captureID] != nil }

    deinit {
        unregisterAll()
        if let handler = eventHandler {
            RemoveEventHandler(handler)
        }
    }

    /// 截图热键的旧入口：固定占 captureID，保持既有调用不变。
    @discardableResult
    func register(_ config: HotKeyConfig, onTrigger: @escaping () -> Void) -> Bool {
        register(config, id: Self.captureID, onTrigger: onTrigger)
    }

    /// 注册成功返回 true；组合被其它应用占用时返回 false，且不保留该槽位的热键。
    @discardableResult
    func register(_ config: HotKeyConfig, id: UInt32, onTrigger: @escaping () -> Void) -> Bool {
        unregister(id: id)

        // 事件处理器装不上时，热键即使注册成功也永远不会回调，必须当作失败处理
        guard installHandlerIfNeeded() else { return false }

        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x6943_7574), id: id) // 'iCut'
        let status = RegisterEventHotKey(
            config.keyCode,
            config.carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        guard status == noErr, let ref else {
            NSLog("iCut: 注册快捷键 \(config.displayText) 失败，status=\(status)")
            return false
        }
        registrations[id] = (ref, onTrigger)
        return true
    }

    func unregister(id: UInt32) {
        if let entry = registrations.removeValue(forKey: id) {
            UnregisterEventHotKey(entry.ref)
        }
    }

    /// 只注销截图热键：录制新组合时不能顺手把历史面板热键也注销掉。
    func unregister() {
        unregister(id: Self.captureID)
    }

    func unregisterAll() {
        for id in Array(registrations.keys) {
            unregister(id: id)
        }
    }

    private func dispatch(id: UInt32) {
        registrations[id]?.handler()
    }

    private func installHandlerIfNeeded() -> Bool {
        if eventHandler != nil { return true }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        // C 回调不能捕获上下文，实例通过 userData 传回；同时要读出触发的槽位再分发
        let userData = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let userData, let event else { return OSStatus(eventNotHandledErr) }
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard status == noErr else { return OSStatus(eventNotHandledErr) }
                let center = Unmanaged<HotKeyCenter>.fromOpaque(userData).takeUnretainedValue()
                center.dispatch(id: hotKeyID.id)
                return noErr
            },
            1,
            &eventType,
            userData,
            &eventHandler
        )
        guard status == noErr else {
            NSLog("iCut: 安装热键事件处理器失败，status=\(status)")
            eventHandler = nil
            return false
        }
        return true
    }
}

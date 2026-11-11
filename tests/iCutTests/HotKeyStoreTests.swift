import AppKit
import Carbon

/// HotKeyStore 的修饰键映射约定：无法映射出修饰键时返回 0，调用方据此拒绝注册。
func runHotKeyStoreTests() {
    expectEqual(HotKeyStore.carbonModifiers(from: []), 0, "无修饰键应返回 0")

    expectEqual(HotKeyStore.carbonModifiers(from: .command), UInt32(cmdKey), "⌘ 映射")
    expectEqual(HotKeyStore.carbonModifiers(from: .option), UInt32(optionKey), "⌥ 映射")
    expectEqual(HotKeyStore.carbonModifiers(from: .control), UInt32(controlKey), "⌃ 映射")
    expectEqual(HotKeyStore.carbonModifiers(from: .shift), UInt32(shiftKey), "⇧ 映射")

    expectEqual(
        HotKeyStore.carbonModifiers(from: [.command, .shift]),
        UInt32(cmdKey | shiftKey),
        "⌘⇧ 组合映射"
    )

    // Caps Lock 属于设备无关标记，但不是可注册的修饰键，不能让它把裸键抬成合法组合
    expectEqual(HotKeyStore.carbonModifiers(from: .capsLock), 0, "Caps Lock 不算有效修饰键")
}

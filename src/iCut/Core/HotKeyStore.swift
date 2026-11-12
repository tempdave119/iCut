import AppKit
import Carbon

/// 一份全局快捷键配置。展示文本与其一起持久化，重启后无需从键码反推字符。
struct HotKeyConfig: Equatable {
    var keyCode: UInt32
    var carbonModifiers: UInt32
    var displayText: String

    static let `default` = HotKeyConfig(
        keyCode: UInt32(kVK_ANSI_2),
        carbonModifiers: UInt32(cmdKey | shiftKey),
        displayText: "⌘⇧2"
    )

    /// 剪贴板历史面板的默认组合；避开 ⇧⌘V（多处应用的「粘贴并匹配样式」）。
    static let clipboardDefault = HotKeyConfig(
        keyCode: UInt32(kVK_ANSI_V),
        carbonModifiers: UInt32(controlKey | optionKey),
        displayText: "⌃⌥V"
    )
}

/// 一个热键槽位：截图与剪贴板历史各占一个，互不影响。
enum HotKeySlot {
    case capture
    case clipboard

    /// capture 沿用旧键名，升级后不需要迁移。
    var keyPrefix: String {
        switch self {
        case .capture: return "hotkey"
        case .clipboard: return "hotkey.clipboard"
        }
    }

    var fallback: HotKeyConfig {
        switch self {
        case .capture: return .default
        case .clipboard: return .clipboardDefault
        }
    }
}

enum HotKeyStore {
    static func load(_ slot: HotKeySlot = .capture) -> HotKeyConfig {
        let defaults = UserDefaults.standard
        let keyCodeKey = "\(slot.keyPrefix).keyCode"
        let modifiersKey = "\(slot.keyPrefix).modifiers"
        let displayKey = "\(slot.keyPrefix).displayText"

        guard defaults.object(forKey: keyCodeKey) != nil,
              defaults.object(forKey: modifiersKey) != nil else {
            return slot.fallback
        }
        let keyCode = UInt32(truncatingIfNeeded: defaults.integer(forKey: keyCodeKey))
        let modifiers = UInt32(truncatingIfNeeded: defaults.integer(forKey: modifiersKey))
        let display = defaults.string(forKey: displayKey) ?? slot.fallback.displayText
        return HotKeyConfig(keyCode: keyCode, carbonModifiers: modifiers, displayText: display)
    }

    static func save(_ config: HotKeyConfig, for slot: HotKeySlot = .capture) {
        let defaults = UserDefaults.standard
        defaults.set(Int(config.keyCode), forKey: "\(slot.keyPrefix).keyCode")
        defaults.set(Int(config.carbonModifiers), forKey: "\(slot.keyPrefix).modifiers")
        defaults.set(config.displayText, forKey: "\(slot.keyPrefix).displayText")
    }

    /// 把 AppKit 修饰键映射为 Carbon 修饰键；返回 0 表示没有任何修饰键，调用方据此拒绝注册。
    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        let flags = flags.intersection(.deviceIndependentFlagsMask)
        var result: UInt32 = 0
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.control) { result |= UInt32(controlKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }

    static func displayText(for event: NSEvent) -> String {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var text = ""
        if flags.contains(.control) { text += "⌃" }
        if flags.contains(.option) { text += "⌥" }
        if flags.contains(.shift) { text += "⇧" }
        if flags.contains(.command) { text += "⌘" }
        return text + keyLabel(for: event)
    }

    private static func keyLabel(for event: NSEvent) -> String {
        switch Int(event.keyCode) {
        case kVK_Space: return "Space"
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Delete: return "⌫"
        case kVK_ForwardDelete: return "⌦"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_Home: return "↖"
        case kVK_End: return "↘"
        case kVK_PageUp: return "⇞"
        case kVK_PageDown: return "⇟"
        case kVK_F1: return "F1"
        case kVK_F2: return "F2"
        case kVK_F3: return "F3"
        case kVK_F4: return "F4"
        case kVK_F5: return "F5"
        case kVK_F6: return "F6"
        case kVK_F7: return "F7"
        case kVK_F8: return "F8"
        case kVK_F9: return "F9"
        case kVK_F10: return "F10"
        case kVK_F11: return "F11"
        case kVK_F12: return "F12"
        default:
            // 功能键与控制键之外的按键总能给出可打印字符，直接用它展示
            if let chars = event.charactersIgnoringModifiers, !chars.isEmpty {
                return chars.uppercased()
            }
            return "Key\(event.keyCode)"
        }
    }
}
